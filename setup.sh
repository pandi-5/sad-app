#!/usr/bin/env bash
# =============================================================================
# setup.sh  Despliegue único del laboratorio de archivos distribuidos.
#
#   sudo ./setup.sh servidor-a        Servidor primario
#   sudo ./setup.sh servidor-b        Servidor réplica con vigilante
#   sudo ./setup.sh cliente [1|2]     Cliente que monta la carpeta compartida
#
#   ./setup.sh status                 Estado de todos los nodos
#   ./setup.sh test                   Pruebas de punta a punta, desde cliente 1
#   ./setup.sh simulate-failure       Simula la caída del servidor A, en A
#   ./setup.sh failback               Devuelve el servicio a A tras una caída, en A
#   ./setup.sh demote                 Devuelve B a réplica, lo usa failback en B
#
# Es idempotente. Se puede ejecutar varias veces sin dañar nada.
# La configuración vive en /etc/sad-lab/lab.conf, ver deploy/lab.conf.example.
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR"
CONF_DIR=/etc/sad-lab
CONF=$CONF_DIR/lab.conf
DERIVED=$CONF_DIR/derived.conf
STATE_DIR=/var/lib/sad-lab
LIB_DIR=/usr/local/lib/sad-lab
LOG_FILE=/var/log/sad-lab.log

# ---------- salida con formato ----------
if [ -t 1 ]; then
  C_OK=$'\e[32m'; C_BAD=$'\e[31m'; C_WARN=$'\e[33m'; C_DIM=$'\e[2m'; C_BOLD=$'\e[1m'; C_OFF=$'\e[0m'
else
  C_OK=""; C_BAD=""; C_WARN=""; C_DIM=""; C_BOLD=""; C_OFF=""
fi
STEP=0
step() { STEP=$((STEP + 1)); printf '\n%s[%02d]%s %s%s%s\n' "$C_BOLD" "$STEP" "$C_OFF" "$C_BOLD" "$*" "$C_OFF"; }
info() { printf '     %s\n' "$*"; }
ok()   { printf '     %s✔%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '     %s!%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
die()  { printf '\n%s✘ %s%s\n' "$C_BAD" "$*" "$C_OFF" >&2; exit 1; }
trap 'printf "\n%s✘ Falló la línea %s del script.%s\n" "$C_BAD" "$LINENO" "$C_OFF" >&2' ERR

# ---------- privilegios ----------
need_root() {
  if [ "$EUID" -ne 0 ]; then
    exec sudo -E "$0" "$@"
  fi
}

# ---------- configuración ----------
load_config() {
  mkdir -p "$CONF_DIR" "$STATE_DIR" "$LIB_DIR"
  if [ ! -f "$CONF" ]; then
    cp "$REPO_DIR/deploy/lab.conf.example" "$CONF"
    info "Configuración creada en $CONF"
  fi
  # shellcheck disable=SC1090
  . "$CONF"
  : "${LAB_USER:=}"
  if [ -z "$LAB_USER" ]; then
    LAB_USER="${SUDO_USER:-$(stat -c %U "$REPO_DIR")}"
  fi
  [ "$LAB_USER" != "root" ] || die "Ejecuta con un usuario normal mediante sudo, no como root directo."
  LAB_HOME="$(getent passwd "$LAB_USER" | cut -d: -f6)"
  : "${LAN_CIDR:=24}" "${OVERLAY_MODE:=sim}" "${EXPORT_DIR:=/srv/compartido}" "${MOUNT_DIR:=/mnt/compartido}"
  : "${APP_PORT:=5000}" "${AGENT_PORT:=5100}" "${REPL_INTERVAL:=2}" "${WATCH_FAILS:=3}"
  : "${ADMIN_USER:=coordinador}" "${SSH_PASSWORD:=}" "${SUDO_NOPASSWD:=yes}" "${TS_AUTHKEY:=}"
  : "${SEED_USERS:=}" "${LAN_CONFIGURE:=yes}" "${ADMIN_PASS:=}"
  APP_DIR="$REPO_DIR"
}

as_user() { sudo -u "$LAB_USER" -H "$@"; }

lan_of() { case "$1" in servidor-a) echo "$LAN_A";; servidor-b) echo "$LAN_B";; cliente-1) echo "$LAN_C1";; cliente-2) echo "$LAN_C2";; esac; }
ov_of()  { case "$1" in servidor-a) echo "$OV_A";; servidor-b) echo "$OV_B";; cliente-1) echo "$OV_C1";; cliente-2) echo "$OV_C2";; esac; }
ALL_NODES="servidor-a servidor-b cliente-1 cliente-2"

# Dirección con la que los demás nodos alcanzan a cada uno.
addr_of() {
  case "$OVERLAY_MODE" in
    sim)  ov_of "$1" ;;
    real) echo "$1" ;;      # MagicDNS resuelve el nombre del nodo
    *)    lan_of "$1" ;;
  esac
}

export_net() {
  case "$OVERLAY_MODE" in
    sim|real) echo "100.64.0.0/10" ;;
    *) python3 -c "import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1]+'/'+sys.argv[2], strict=False))" "$LAN_A" "$LAN_CIDR" ;;
  esac
}

write_derived() {
  local role="$1" node="$2"
  {
    echo "# Generado por setup.sh, no editar."
    echo "NODE_NAME=$node"
    echo "NODE_ROLE=$role"
    echo "LAB_USER=$LAB_USER"
    echo "LAB_HOME=$LAB_HOME"
    echo "APP_DIR=$APP_DIR"
    echo "EXPORT_DIR=$EXPORT_DIR"
    echo "MOUNT_DIR=$MOUNT_DIR"
    echo "EXPORT_NET=$(export_net)"
    echo "OVERLAY_MODE=$OVERLAY_MODE"
    echo "APP_PORT=$APP_PORT"
    echo "AGENT_PORT=$AGENT_PORT"
    echo "REPL_INTERVAL=$REPL_INTERVAL"
    echo "WATCH_FAILS=$WATCH_FAILS"
    for n in $ALL_NODES; do
      printf 'ADDR_%s=%s\n' "$(echo "$n" | tr 'a-z-' 'A-Z_')" "$(addr_of "$n")"
    done
  } > "$DERIVED"
}

# ---------- utilidades idempotentes ----------
APT_UPDATED=0
apt_install() {
  local missing=() p
  for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  if [ "${#missing[@]}" -eq 0 ]; then ok "Paquetes ya instalados: $*"; return; fi
  if [ "$APT_UPDATED" -eq 0 ]; then
    info "Actualizando índice de paquetes..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >>"$LOG_FILE" 2>&1
    APT_UPDATED=1
  fi
  info "Instalando ${missing[*]}..."
  NEEDRESTART_MODE=a DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >>"$LOG_FILE" 2>&1
  ok "Instalado ${missing[*]}"
}

# Escribe un archivo solo si cambia. Devuelve 0 si lo modificó.
write_file() {
  local path="$1" mode="${2:-644}" tmp
  tmp="$(mktemp)"; cat > "$tmp"
  if [ -f "$path" ] && cmp -s "$tmp" "$path"; then rm -f "$tmp"; return 1; fi
  install -m "$mode" "$tmp" "$path"; rm -f "$tmp"; return 0
}

env_set() {  # env_set CLAVE VALOR  en $APP_DIR/.env
  local key="$1" val="$2" file="$APP_DIR/.env"
  touch "$file"
  if grep -q "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${val//|/\\|}|" "$file"
  else
    echo "${key}=${val}" >> "$file"
  fi
  chown "$LAB_USER":"$LAB_USER" "$file"; chmod 600 "$file"
}

env_get() { grep "^$1=" "$APP_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2- || true; }

svc_enable_now() { systemctl enable --now "$1" >/dev/null 2>&1 && ok "Servicio $1 activo"; }
svc_restart_if() { # svc_restart_if servicio cambió?
  if [ "$2" = "1" ]; then systemctl daemon-reload; systemctl restart "$1"; fi
}

wait_for() { # wait_for "descripción" segundos comando...
  local desc="$1" secs="$2"; shift 2
  local i=0
  while [ "$i" -lt "$secs" ]; do "$@" >/dev/null 2>&1 && { ok "$desc"; return 0; }; sleep 1; i=$((i + 1)); done
  warn "No se cumplió en ${secs}s, $desc"; return 1
}

log_event() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }

# ---------- comprobaciones de validación ----------
FAILS=0; WARNS=0
check() { # check "descripción" comando...
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then printf '     %s✔%s %s\n' "$C_OK" "$C_OFF" "$desc"
  else printf '     %s✘%s %s\n' "$C_BAD" "$C_OFF" "$desc"; FAILS=$((FAILS + 1)); fi
}
check_soft() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then printf '     %s✔%s %s\n' "$C_OK" "$C_OFF" "$desc"
  else printf '     %s!%s %s %s(pendiente)%s\n' "$C_WARN" "$C_OFF" "$desc" "$C_DIM" "$C_OFF"; WARNS=$((WARNS + 1)); fi
}
finish() {
  echo
  if [ "$FAILS" -eq 0 ]; then
    printf '%s%s✔ Todo quedó funcionando.%s' "$C_BOLD" "$C_OK" "$C_OFF"
    [ "$WARNS" -eq 0 ] || printf ' %s%d comprobación(es) pendiente(s), normales si falta otro nodo.%s' "$C_WARN" "$WARNS" "$C_OFF"
    echo
  else
    printf '%s%s✘ %d comprobación(es) fallaron. Revisa los mensajes de arriba.%s\n' "$C_BOLD" "$C_BAD" "$FAILS" "$C_OFF"
    exit 1
  fi
}

# =============================================================================
# Pasos comunes
# =============================================================================
step_base() {
  step "Paquetes base"
  apt_install curl git rsync python3 python3-venv python3-pip jq iproute2 sshpass netcat-openbsd openssh-server
  systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || true
}

step_identity() {
  local node="$1"
  step "Identidad del nodo $node"
  if [ "$(hostnamectl --static 2>/dev/null || hostname)" != "$node" ]; then
    hostnamectl set-hostname "$node"; ok "Nombre del equipo cambiado a $node"
  else ok "Nombre del equipo ya es $node"
  fi
  # Entradas de /etc/hosts gestionadas por el script. En modo real resuelve MagicDNS.
  sed -i '/# sad-lab begin/,/# sad-lab end/d' /etc/hosts
  if [ "$OVERLAY_MODE" != "real" ]; then
    {
      echo "# sad-lab begin"
      for n in $ALL_NODES; do echo "$(addr_of "$n") $n"; done
      echo "# sad-lab end"
    } >> /etc/hosts
    ok "Nombres de los nodos añadidos a /etc/hosts"
  fi
  if [ "$SUDO_NOPASSWD" = "yes" ]; then
    echo "$LAB_USER ALL=(ALL) NOPASSWD:ALL" | write_file /etc/sudoers.d/90-sad-lab 440 && ok "sudo sin contraseña para $LAB_USER" || ok "sudo ya configurado"
  fi
}

lab_iface() {  # segunda tarjeta, la que no tiene la ruta por defecto
  local def
  def="$(ip -4 route show default | awk '{print $5; exit}')"
  ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' \
    | grep -Ev '^(lo|tssim0|tailscale0|docker.*|veth.*|br-.*)$' | grep -vx "${def:-__none__}" | head -1
}

step_lan() {
  local node="$1" ip iface
  step "Red real entre las máquinas"
  if [ "$LAN_CONFIGURE" != "yes" ]; then warn "LAN_CONFIGURE=no, no se toca la red"; return; fi
  ip="$(lan_of "$node")"
  iface="$(lab_iface || true)"
  if [ -z "$iface" ]; then warn "No hay segunda tarjeta de red. Agrega un adaptador solo anfitrión en VirtualBox."; return; fi
  if write_file /etc/netplan/70-sad-lab.yaml 600 <<EOF
network:
  version: 2
  ethernets:
    $iface:
      dhcp4: false
      addresses: [$ip/$LAN_CIDR]
EOF
  then netplan apply; sleep 2; ok "$iface configurada con $ip/$LAN_CIDR"
  else ok "$iface ya tiene $ip/$LAN_CIDR"; fi
}

step_overlay() {
  local node="$1" mine peer
  step "Red privada superpuesta, modo $OVERLAY_MODE"
  case "$OVERLAY_MODE" in
    sim)
      mine="$(ov_of "$node")"
      echo sim > $CONF_DIR/overlay-mode
      {
        echo '#!/usr/bin/env bash'
        echo '# Simula la red privada de Tailscale. Genera la interfaz tssim0 y rutas a los pares.'
        echo "ip link add tssim0 type dummy 2>/dev/null || true"
        echo "ip addr replace $mine/32 dev tssim0"
        echo "ip link set tssim0 up"
        for peer in $ALL_NODES; do
          [ "$peer" = "$node" ] && continue
          echo "ip route replace $(ov_of "$peer")/32 via $(lan_of "$peer") src $mine"
        done
      } | write_file $LIB_DIR/overlay-sim.sh 755 || true
          write_file /etc/systemd/system/sad-overlay-sim.service <<EOF || true
[Unit]
Description=Red privada simulada del laboratorio
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$LIB_DIR/overlay-sim.sh

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload
      systemctl enable sad-overlay-sim >/dev/null 2>&1
      systemctl restart sad-overlay-sim
      ok "Interfaz tssim0 con $mine, simulación de Tailscale"
      info "${C_DIM}Aviso: es una simulación. Las VM comparten un solo equipo físico.${C_OFF}"
      ;;
    real)
      echo real > $CONF_DIR/overlay-mode
      if ! command -v tailscale >/dev/null; then
        info "Instalando Tailscale..."
        curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1
      fi
      systemctl enable --now tailscaled >/dev/null 2>&1
      if ! tailscale status >/dev/null 2>&1 || tailscale status 2>&1 | grep -qi "logged out"; then
        if [ -n "$TS_AUTHKEY" ]; then tailscale up --authkey="$TS_AUTHKEY" --hostname="$node"
        else warn "Autoriza este nodo con el enlace que aparece a continuación."; tailscale up --hostname="$node"; fi
      fi
      ok "Tailscale activo, IP $(tailscale ip -4 | head -1)"
      ;;
    *)
      echo none > $CONF_DIR/overlay-mode
      ok "Sin red superpuesta. Se usan las direcciones LAN."
      ;;
  esac
}

ensure_ssh_key() {
  local key="$LAB_HOME/.ssh/id_ed25519"
  if [ ! -f "$key" ]; then
    as_user mkdir -p "$LAB_HOME/.ssh"; as_user chmod 700 "$LAB_HOME/.ssh"
    as_user ssh-keygen -q -t ed25519 -N "" -f "$key"
    ok "Llave SSH creada"
  else ok "Llave SSH ya existe"; fi
}

SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new"
peer_ssh_ok() { as_user ssh $SSH_OPTS "$LAB_USER@$1" true 2>/dev/null; }

step_ssh_keys() {
  local node="$1" peer addr
  step "Llaves SSH entre nodos"
  ensure_ssh_key
  for peer in $ALL_NODES; do
    [ "$peer" = "$node" ] && continue
    addr="$(addr_of "$peer")"
    if peer_ssh_ok "$addr"; then ok "Acceso SSH a $peer"; continue; fi
    if ! nc -z -w2 "$addr" 22 2>/dev/null; then warn "$peer no está disponible todavía, repite setup.sh cuando esté listo"; continue; fi
    if [ -n "$SSH_PASSWORD" ]; then
      if as_user sshpass -p "$SSH_PASSWORD" ssh-copy-id -o StrictHostKeyChecking=accept-new -i "$LAB_HOME/.ssh/id_ed25519.pub" "$LAB_USER@$addr" >/dev/null 2>&1; then
        ok "Llave copiada a $peer"
      else warn "No se pudo copiar la llave a $peer"; fi
    else warn "Define SSH_PASSWORD en $CONF o ejecuta ssh-copy-id hacia $peer"; fi
  done
}

write_agent() {
  local role="$1" node="$2" targets=""
  step "Agente de estado"
  if [ "$role" = "cliente" ]; then
    targets="web=$(addr_of servidor-a):$APP_PORT,nfs=$(addr_of servidor-a):2049"
  fi
  write_file $CONF_DIR/agent.env 644 <<EOF || true
NODE_NAME=$node
NODE_ROLE=$role
EXPORT_DIR=$EXPORT_DIR
MOUNT_DIR=$MOUNT_DIR
AGENT_PORT=$AGENT_PORT
PROBE_TARGETS=$targets
EOF
  write_file /etc/systemd/system/sad-agent.service <<EOF || true
[Unit]
Description=Agente de estado del laboratorio
After=network-online.target

[Service]
EnvironmentFile=$CONF_DIR/agent.env
ExecStart=/usr/bin/python3 $REPO_DIR/cluster/agent.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable sad-agent >/dev/null 2>&1
  systemctl restart sad-agent
  wait_for "Agente respondiendo en el puerto $AGENT_PORT" 10 curl -fsS "http://127.0.0.1:$AGENT_PORT/health" || true
}

# =============================================================================
# Servidores
# =============================================================================
step_nfs_server() {
  local role="$1" opts line uid gid
  step "Servidor NFS, carpeta $EXPORT_DIR"
  apt_install nfs-kernel-server
  mkdir -p "$EXPORT_DIR/.cluster"
  chown -R "$LAB_USER":"$LAB_USER" "$EXPORT_DIR"; chmod 775 "$EXPORT_DIR"
  modprobe nfsd 2>/dev/null || true
  grep -qw nfsd /proc/filesystems || die "El kernel no trae nfsd."
  if [ "$role" = "servidor-b" ] && [ ! -f "$STATE_DIR/promoted" ]; then opts="ro"; else opts="rw"; fi
  uid="$(id -u "$LAB_USER")"; gid="$(id -g "$LAB_USER")"
  line="$EXPORT_DIR $(export_net)($opts,sync,no_subtree_check,all_squash,anonuid=$uid,anongid=$gid)"
  touch /etc/exports
  if grep -qxF "$line" /etc/exports; then ok "Exportación ya correcta ($opts)"
  else
    sed -i "\|^$EXPORT_DIR |d" /etc/exports; echo "$line" >> /etc/exports
    ok "Exportación escrita, modo $opts"
  fi
  systemctl enable --now nfs-server >/dev/null 2>&1
  exportfs -ra
  ok "NFS activo"
}

step_app() {
  local role="$1" node="$2" secret admin_pass peers=""
  step "Aplicación web sad-app"
  [ -f "$APP_DIR/requirements.txt" ] || die "No encuentro requirements.txt en $APP_DIR."
  if [ ! -d "$APP_DIR/.venv" ]; then as_user python3 -m venv "$APP_DIR/.venv"; ok "Entorno virtual creado"; fi
  local want have
  want="$(sha256sum "$APP_DIR/requirements.txt" | cut -d' ' -f1)"
  have="$(cat "$APP_DIR/.venv/.req-hash" 2>/dev/null || true)"
  if [ "$want" != "$have" ]; then
    info "Instalando dependencias de Python..."
    as_user "$APP_DIR/.venv/bin/pip" install -q -r "$APP_DIR/requirements.txt"
    echo "$want" | as_user tee "$APP_DIR/.venv/.req-hash" >/dev/null
    ok "Dependencias instaladas"
  else ok "Dependencias ya instaladas"; fi

  touch "$APP_DIR/.env"; chown "$LAB_USER":"$LAB_USER" "$APP_DIR/.env"; chmod 600 "$APP_DIR/.env"
  if [ -z "$(env_get SECRET)" ]; then
    secret="$(python3 -c 'import secrets;print(secrets.token_hex(32))')"; env_set SECRET "$secret"
  fi
  if [ -z "$(env_get ADMIN_PASS)" ]; then
    admin_pass="${ADMIN_PASS:-$(python3 -c 'import secrets;print(secrets.token_urlsafe(12))')}"
    env_set ADMIN_USER "$ADMIN_USER"; env_set ADMIN_PASS "$admin_pass"
  fi
  write_credentials() {
    printf 'Coordinador  usuario=%s  clave=%s\n' "$(env_get ADMIN_USER)" "$(env_get ADMIN_PASS)" > $CONF_DIR/credenciales.txt
    chmod 600 $CONF_DIR/credenciales.txt
  }
  write_credentials
  # B toma el SECRET y la clave de A para que la conmutación sea transparente.
  if [ "$role" = "servidor-b" ]; then
    local tmp; tmp="$(mktemp)"; chmod 666 "$tmp"
    if as_user scp $SSH_OPTS -q "$LAB_USER@$(addr_of servidor-a):$APP_DIR/.env" "$tmp" 2>/dev/null; then
      for key in SECRET ADMIN_USER ADMIN_PASS; do
        v="$(grep "^$key=" "$tmp" | head -1 | cut -d= -f2- || true)"; [ -n "$v" ] && env_set "$key" "$v"
      done
      write_credentials
      ok "SECRET y clave del coordinador sincronizados desde servidor-a"
    else warn "No pude leer el .env de servidor-a. Repite setup.sh en servidor-b cuando A esté listo."; fi
    rm -f "$tmp"
  fi
  env_set COOKIE_SECURE 0
  env_set STORAGE_DIR "$EXPORT_DIR/sad-storage"
  env_set NODE_NAME "$node"
  if [ "$role" = "servidor-a" ] || [ -f "$STATE_DIR/promoted" ]; then env_set NODE_ROLE primario; else env_set NODE_ROLE replica; fi
  for n in servidor-a servidor-b cliente-1 cliente-2; do peers="$peers${peers:+,}$n=http://$(addr_of "$n"):$AGENT_PORT"; done
  env_set CLUSTER_NODES "$peers"
  if [ "$role" = "servidor-a" ]; then env_set PEER_WEB_URL "http://$(addr_of servidor-b):$APP_PORT"
  else env_set PEER_WEB_URL "http://$(addr_of servidor-a):$APP_PORT"; fi
  ok "Archivo .env al día"
  as_user mkdir -p "$EXPORT_DIR/sad-storage" "$APP_DIR/data"

  write_file /etc/systemd/system/sad-app.service <<EOF || true
[Unit]
Description=sad-app, archivos compartidos
After=network-online.target nfs-server.service

[Service]
User=$LAB_USER
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/.venv/bin/gunicorn --workers 1 --threads 8 --bind 0.0.0.0:$APP_PORT --access-logfile - wsgi:app
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  if [ "$role" = "servidor-a" ] || [ -f "$STATE_DIR/promoted" ]; then
    systemctl enable sad-app >/dev/null 2>&1
    systemctl restart sad-app
    wait_for "sad-app responde en el puerto $APP_PORT" 25 curl -fsS "http://127.0.0.1:$APP_PORT/healthz" || true
  else
    systemctl disable --now sad-app >/dev/null 2>&1 || true
    ok "sad-app instalada y en espera, solo arranca si B se promueve"
  fi
}

step_seed_users() {
  [ -n "$SEED_USERS" ] || return 0
  step "Usuarios de prueba"
  as_user "$APP_DIR/.venv/bin/python" - "$APP_DIR/data/sad.db" "$SEED_USERS" <<'PY'
import sqlite3, sys, time
from werkzeug.security import generate_password_hash as g
db, spec = sys.argv[1], sys.argv[2]
c = sqlite3.connect(db)
if not c.execute("SELECT 1 FROM sqlite_master WHERE name='users'").fetchone():
    print("     ! La base todavía no tiene tablas. Repite setup.sh cuando sad-app esté activa.")
    sys.exit(0)
for item in spec.split(","):
    if ":" not in item: continue
    name, pw = item.split(":", 1)
    row = c.execute("SELECT 1 FROM users WHERE name=?", (name.strip().lower(),)).fetchone()
    if row: print(f"     ✔ {name} ya existe"); continue
    c.execute("INSERT INTO users(name,password_hash,r,w,d,active,session_epoch,created_at) VALUES(?,?,1,1,0,1,0,?)",
              (name.strip().lower(), g(pw), time.time()))
    print(f"     ✔ {name} creado con lectura y escritura")
c.commit()
PY
}

step_replicator() {
  step "Replicador A hacia B"
  write_file $LIB_DIR/replicate.sh 755 <<'EOF' || true
#!/usr/bin/env bash
# Copia la carpeta compartida y una instantánea de la base de datos a servidor-b.
set -u
. /etc/sad-lab/lab.conf
. /etc/sad-lab/derived.conf
SSH="ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new"
state=""
mkdir -p "$EXPORT_DIR/.cluster"
while true; do
  printf '{"ts": %s, "node": "%s"}\n' "$(date +%s.%N)" "$NODE_NAME" > "$EXPORT_DIR/.cluster/heartbeat.tmp" \
    && mv -f "$EXPORT_DIR/.cluster/heartbeat.tmp" "$EXPORT_DIR/.cluster/heartbeat"
  if [ -f "$APP_DIR/data/sad.db" ]; then
    "$APP_DIR/.venv/bin/python" - "$APP_DIR/data/sad.db" "$EXPORT_DIR/.cluster/sad.db.tmp" <<'PY' 2>/dev/null && mv -f "$EXPORT_DIR/.cluster/sad.db.tmp" "$EXPORT_DIR/.cluster/sad.db"
import sqlite3, sys
src = sqlite3.connect(sys.argv[1]); dst = sqlite3.connect(sys.argv[2])
src.backup(dst); dst.close(); src.close()
PY
  fi
  if rsync -a --delete --exclude 'lost+found' -e "$SSH" "$EXPORT_DIR/" "$LAB_USER@$ADDR_SERVIDOR_B:$EXPORT_DIR/" 2>/tmp/sad-repl.err; then
    [ "$state" = "ok" ] || { echo "réplica al día con servidor-b"; state=ok; }
  else
    [ "$state" = "fail" ] || { echo "servidor-b no responde: $(head -1 /tmp/sad-repl.err)"; state=fail; }
  fi
  sleep "$REPL_INTERVAL"
done
EOF
  write_file /etc/systemd/system/sad-replicator.service <<EOF || true
[Unit]
Description=Replicador de la carpeta compartida hacia servidor-b
After=network-online.target nfs-server.service

[Service]
User=$LAB_USER
ExecStart=$LIB_DIR/replicate.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable sad-replicator >/dev/null 2>&1
  systemctl restart sad-replicator
  ok "Replicador activo, intervalo ${REPL_INTERVAL}s"
}

step_watchdog() {
  step "Vigilante con testigos en servidor-b"
  write_file $LIB_DIR/watchdog.sh 755 <<'EOF' || true
#!/usr/bin/env bash
# Si servidor-a deja de responder y los testigos coinciden, B se promueve a primario.
set -u
. /etc/sad-lab/lab.conf
. /etc/sad-lab/derived.conf
LOG=/var/log/sad-lab.log
say() { printf '%s [vigilante] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }

a_alive() {
  curl -fsS -m 2 "http://$ADDR_SERVIDOR_A:$APP_PORT/healthz" >/dev/null 2>&1 \
    && nc -z -w2 "$ADDR_SERVIDOR_A" 2049 2>/dev/null
}

# Pregunta a cada cliente si ve a A. Imprime "ves noes".
witnesses() {
  local w alive=0 dead=0 web nfs
  for w in "$ADDR_CLIENTE_1" "$ADDR_CLIENTE_2"; do
    web="$(curl -fsS -m 3 "http://$w:$AGENT_PORT/probe?target=web" 2>/dev/null | jq -r '.reachable' 2>/dev/null || true)"
    nfs="$(curl -fsS -m 3 "http://$w:$AGENT_PORT/probe?target=nfs" 2>/dev/null | jq -r '.reachable' 2>/dev/null || true)"
    [ -z "$web" ] || [ -z "$nfs" ] && continue
    if [ "$web" = "true" ] && [ "$nfs" = "true" ]; then alive=$((alive + 1)); else dead=$((dead + 1)); fi
  done
  echo "$alive $dead"
}

promote() {
  say "Promoviendo servidor-b a primario"
  mkdir -p /var/lib/sad-lab; date +%s > /var/lib/sad-lab/promoted
  sed -i "\|^$EXPORT_DIR |s/(ro,/(rw,/" /etc/exports
  exportfs -ra
  if [ -f "$EXPORT_DIR/.cluster/sad.db" ]; then
    systemctl stop sad-app 2>/dev/null || true
    rm -f "$APP_DIR/data/sad.db" "$APP_DIR/data/sad.db-wal" "$APP_DIR/data/sad.db-shm"
    install -o "$LAB_USER" -g "$LAB_USER" -m 640 "$EXPORT_DIR/.cluster/sad.db" "$APP_DIR/data/sad.db"
    say "Base de datos restaurada desde la última instantánea replicada"
  fi
  sed -i 's/^NODE_ROLE=.*/NODE_ROLE=primario/' "$APP_DIR/.env"
  systemctl enable --now sad-app
  say "servidor-b es ahora el primario"
}

fails=0
say "Vigilando a servidor-a, umbral $WATCH_FAILS fallos"
while true; do
  if [ -f /var/lib/sad-lab/promoted ]; then sleep 5; continue; fi
  if a_alive; then
    [ "$fails" -eq 0 ] || say "servidor-a volvió a responder"
    fails=0
  else
    fails=$((fails + 1)); say "servidor-a no responde, fallo $fails de $WATCH_FAILS"
  fi
  if [ "$fails" -ge "$WATCH_FAILS" ]; then
    read -r alive dead < <(witnesses)
    say "Testigos que ven a A: $alive, que no la ven: $dead"
    if [ "$dead" -ge 1 ] && [ "$alive" -eq 0 ]; then promote
    else say "Sin acuerdo de los testigos, no me promuevo"; fi
    fails=0
  fi
  sleep 2
done
EOF
  write_file /etc/systemd/system/sad-watchdog.service <<EOF || true
[Unit]
Description=Vigilante de servidor-a con testigos
After=network-online.target nfs-server.service

[Service]
ExecStart=$LIB_DIR/watchdog.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable sad-watchdog >/dev/null 2>&1
  systemctl restart sad-watchdog
  ok "Vigilante activo"
}

# =============================================================================
# Clientes
# =============================================================================
step_client() {
  local node="$1"
  step "Cliente NFS"
  apt_install nfs-common
  mkdir -p "$MOUNT_DIR"
  write_file /usr/local/bin/sad-mount 755 <<'EOF' || true
#!/usr/bin/env bash
# sad-mount [auto|a|b|salir]   Monta la carpeta compartida desde el servidor que esté vivo.
. /etc/sad-lab/derived.conf
mode="${1:-auto}"
OPTS="soft,timeo=30,retrans=2"
writable() { timeout 5 sh -c "f=$MOUNT_DIR/.probe-\$(hostname); touch \$f && rm -f \$f" 2>/dev/null; }
try() {  # try dirección  -> 0 si monta
  umount -f -l "$MOUNT_DIR" 2>/dev/null
  timeout 15 mount -t nfs4 -o "$OPTS" "$1:$EXPORT_DIR" "$MOUNT_DIR" 2>/dev/null
}
case "$mode" in
  salir) umount -f -l "$MOUNT_DIR" 2>/dev/null; echo "Desmontado."; exit 0 ;;
  a) try "$ADDR_SERVIDOR_A" && echo "Montado desde servidor-a" && exit 0; exit 1 ;;
  b) try "$ADDR_SERVIDOR_B" && echo "Montado desde servidor-b" && exit 0; exit 1 ;;
esac
ro_host=""
for h in "$ADDR_SERVIDOR_A" "$ADDR_SERVIDOR_B"; do
  if try "$h"; then
    if writable; then echo "Montado desde $h con escritura"; exit 0; fi
    [ -n "$ro_host" ] || ro_host="$h"
  fi
done
if [ -n "$ro_host" ] && try "$ro_host"; then echo "Montado desde $ro_host solo para lectura"; exit 0; fi
echo "No se pudo montar desde ningún servidor" >&2; exit 1
EOF
  write_file $LIB_DIR/mount-watch.sh 755 <<'EOF' || true
#!/usr/bin/env bash
# Vuelve a montar desde el servidor correcto si el actual deja de responder o de aceptar escrituras.
. /etc/sad-lab/derived.conf
say() { printf '%s [cliente] %s\n' "$(date '+%F %T')" "$*" | tee -a /var/log/sad-lab.log; }
ok_mount() { mountpoint -q "$MOUNT_DIR" && timeout 5 sh -c "f=$MOUNT_DIR/.probe-\$(hostname); touch \$f && rm -f \$f" 2>/dev/null; }
bad=0
while true; do
  if ok_mount; then bad=0
  else
    bad=$((bad + 1))
    if [ "$bad" -ge 2 ]; then say "La carpeta no responde o no es escribible, buscando servidor"; /usr/local/bin/sad-mount auto | tee -a /var/log/sad-lab.log; bad=0; fi
  fi
  sleep 3
done
EOF
  write_file /etc/systemd/system/sad-mount.service <<EOF || true
[Unit]
Description=Montaje de la carpeta compartida
After=network-online.target sad-overlay-sim.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/sad-mount auto

[Install]
WantedBy=multi-user.target
EOF
  write_file /etc/systemd/system/sad-mount-watch.service <<EOF || true
[Unit]
Description=Vigilante del montaje
After=sad-mount.service

[Service]
ExecStart=$LIB_DIR/mount-watch.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF
  write_file $LIB_DIR/editar.sh 755 <<'EOF' || true
#!/usr/bin/env bash
# Prueba de concurrencia. editar.sh Nombre [--lock]
. /etc/sad-lab/derived.conf
F="$MOUNT_DIR/contador.txt"
[ -f "$F" ] || echo 0 > "$F"
if [ "${2:-}" = "--lock" ]; then exec 9>>"$F"; flock 9; fi
v=$(cat "$F")
echo "$(date +%T) $1 leyó $v, editando 8 s"
sleep 8
echo $((v + 1)) > "$F"
echo "$(date +%T) $1 escribió $((v + 1))"
EOF
  systemctl daemon-reload
  systemctl enable sad-mount sad-mount-watch >/dev/null 2>&1
  systemctl restart sad-mount
  systemctl restart sad-mount-watch
  if mountpoint -q "$MOUNT_DIR"; then ok "Carpeta montada en $MOUNT_DIR"; else warn "Todavía no se pudo montar. Los servidores deben estar listos."; fi
}

# =============================================================================
# Validaciones por rol
# =============================================================================
overlay_ip_present() { ip -4 -o addr show | grep -q " $1/"; }
svc_active() { systemctl is-active --quiet "$1"; }
http_ok() { curl -fsS -m 3 "$1" >/dev/null; }
exports_has() { grep -q "^$EXPORT_DIR .*($1," /etc/exports; }
heartbeat_fresh() {
  local f="$EXPORT_DIR/.cluster/heartbeat" ts
  [ -f "$f" ] || return 1
  ts="$(jq -r .ts "$f")"
  python3 -c "import sys,time; sys.exit(0 if time.time()-float(sys.argv[1]) < $1 else 1)" "$ts"
}

validate_servidor_a() {
  step "Validación final de servidor-a"
  [ "$OVERLAY_MODE" = "none" ] || check "Dirección de red privada $(ov_of servidor-a) presente" overlay_ip_present "$(ov_of servidor-a)"
  check "NFS activo y exportando en lectura y escritura" exports_has rw
  check "Servicio nfs-server activo" svc_active nfs-server
  check "sad-app activa" svc_active sad-app
  check "sad-app responde en /healthz" http_ok "http://127.0.0.1:$APP_PORT/healthz"
  check "Agente responde" http_ok "http://127.0.0.1:$AGENT_PORT/health"
  check "Replicador activo" svc_active sad-replicator
  check "Latido reciente en la carpeta compartida" heartbeat_fresh 10
  check_soft "SSH sin contraseña hacia servidor-b" peer_ssh_ok "$(addr_of servidor-b)"
  check_soft "servidor-b alcanzable por NFS" nc -z -w2 "$(addr_of servidor-b)" 2049
}

validate_servidor_b() {
  step "Validación final de servidor-b"
  [ "$OVERLAY_MODE" = "none" ] || check "Dirección de red privada $(ov_of servidor-b) presente" overlay_ip_present "$(ov_of servidor-b)"
  check "NFS activo y exportando en solo lectura" exports_has ro
  check "Servicio nfs-server activo" svc_active nfs-server
  check "Vigilante activo" svc_active sad-watchdog
  check "Agente responde" http_ok "http://127.0.0.1:$AGENT_PORT/health"
  check "sad-app instalada en $APP_DIR/.venv" test -x "$APP_DIR/.venv/bin/gunicorn"
  check_soft "Réplica recibiendo latidos de servidor-a" heartbeat_fresh 15
  check_soft "SSH sin contraseña hacia servidor-a" peer_ssh_ok "$(addr_of servidor-a)"
}

validate_cliente() {
  step "Validación final de $1"
  [ "$OVERLAY_MODE" = "none" ] || check "Dirección de red privada $(ov_of "$1") presente" overlay_ip_present "$(ov_of "$1")"
  check "Agente responde" http_ok "http://127.0.0.1:$AGENT_PORT/health"
  check "Vigilante del montaje activo" svc_active sad-mount-watch
  check_soft "Carpeta montada en $MOUNT_DIR" mountpoint -q "$MOUNT_DIR"
  check_soft "Se puede escribir en la carpeta" sh -c "touch $MOUNT_DIR/.setup-probe && rm -f $MOUNT_DIR/.setup-probe"
}

# =============================================================================
# Subcomandos
# =============================================================================
cmd_install() {
  local role="$1" node
  case "$role" in
    servidor-a|servidor-b) node="$role" ;;
    cliente)
      local n="${2:-}"
      [ -n "$n" ] || n="$(hostname | sed -n 's/^cliente-\([12]\)$/\1/p')"
      [ -n "$n" ] || die "Indica el número del cliente, por ejemplo: ./setup.sh cliente 1"
      node="cliente-$n" ;;
    *) die "Rol desconocido. Usa servidor-a, servidor-b o cliente." ;;
  esac
  need_root "$@"; load_config
  printf '%sLaboratorio de archivos distribuidos%s  nodo %s%s%s  red %s  usuario %s\n' "$C_BOLD" "$C_OFF" "$C_BOLD" "$node" "$C_OFF" "$OVERLAY_MODE" "$LAB_USER"
  write_derived "$role" "$node"
  step_base
  step_identity "$node"
  step_lan "$node"
  step_overlay "$node"
  write_derived "$role" "$node"
  step_ssh_keys "$node"
  case "$role" in
    servidor-a)
      step_nfs_server "$role"; step_app "$role" "$node"; step_seed_users
      write_agent "$role" "$node"; step_replicator; validate_servidor_a
      [ -f $CONF_DIR/credenciales.txt ] && { echo; info "$(cat $CONF_DIR/credenciales.txt)"; } ;;
    servidor-b)
      step_nfs_server "$role"; step_app "$role" "$node"
      write_agent "$role" "$node"; step_watchdog; validate_servidor_b ;;
    cliente)
      write_agent "cliente" "$node"; step_client "$node"; validate_cliente "$node" ;;
  esac
  finish
}

cmd_status() {
  need_root "$@"; load_config
  [ -f "$DERIVED" ] || die "Este equipo todavía no se configuró con setup.sh."
  # shellcheck disable=SC1090
  . "$DERIVED"
  printf '%-12s %-10s %-9s %-16s %-8s %s\n' NODO ROL RED IP RETRASO SERVICIOS
  local n a j
  for n in $ALL_NODES; do
    a="$(addr_of "$n")"
    j="$(curl -fsS -m 2 "http://$a:$AGENT_PORT/status" 2>/dev/null || true)"
    if [ -z "$j" ]; then printf '%-12s %s%s%s\n' "$n" "$C_BAD" "sin respuesta" "$C_OFF"; continue; fi
    printf '%-12s %-10s %-9s %-16s %-8s %s\n' "$n" \
      "$(jq -r .effective_role <<<"$j")" \
      "$(jq -r .overlay.mode <<<"$j")" \
      "$(jq -r '.overlay.ip // "-"' <<<"$j")" \
      "$(jq -r 'if .heartbeat_age == null or .effective_role != "replica" then "-" else "\(.heartbeat_age)s" end' <<<"$j")" \
      "$(jq -r '[.services | to_entries[] | select(.value=="active") | .key] | join(",")' <<<"$j")"
  done
}

# Ejecuta un comando en otro nodo por SSH como el usuario del laboratorio.
rsh() { local node="$1"; shift; as_user ssh $SSH_OPTS "$LAB_USER@$(addr_of "$node")" "$@"; }

cmd_test() {
  need_root "$@"; load_config
  # shellcheck disable=SC1090
  . "$DERIVED"
  local pass=0 fail=0 out="$LAB_HOME/resultados-pruebas.txt" v lag t0 t1 f
  : > "$out"
  res() { # res "nombre" estado "detalle"
    if [ "$2" = ok ]; then pass=$((pass + 1)); printf '     %s✔%s %-34s %s\n' "$C_OK" "$C_OFF" "$1" "$3"
    else fail=$((fail + 1)); printf '     %s✘%s %-34s %s\n' "$C_BAD" "$C_OFF" "$1" "$3"; fi
    printf '%s | %s | %s\n' "$1" "$2" "$3" >> "$out"
  }
  step "Pruebas de punta a punta desde $(hostname)"
  mountpoint -q "$MOUNT_DIR" || die "La carpeta no está montada. Ejecuta primero: setup.sh cliente"
  local other="cliente-2"; [ "$(hostname)" = "cliente-2" ] && other="cliente-1"

  f="$MOUNT_DIR/prueba-acceso-$$.txt"
  echo "hola desde $(hostname)" > "$f"
  v="$(rsh "$other" cat "$f" 2>/dev/null || true)"
  [ "$v" = "hola desde $(hostname)" ] && res "Acceso compartido" ok "$other leyó el archivo creado aquí" || res "Acceso compartido" fail "$other no vio el archivo"
  rm -f "$f"

  echo 0 > "$MOUNT_DIR/contador.txt"
  info "Sin bloqueo, los dos clientes editan a la vez durante 8 segundos..."
  rsh "$other" "$LIB_DIR/editar.sh $other" >/dev/null 2>&1 &
  "$LIB_DIR/editar.sh" "$(hostname)" >/dev/null 2>&1
  wait; sleep 2
  v="$(cat "$MOUNT_DIR/contador.txt")"
  [ "$v" = "1" ] && res "Concurrencia sin bloqueo" ok "contador final $v, se perdió una actualización" || res "Concurrencia sin bloqueo" fail "contador final $v, se esperaba 1"

  echo 0 > "$MOUNT_DIR/contador.txt"
  info "Con bloqueo flock, el segundo cliente espera su turno..."
  rsh "$other" "$LIB_DIR/editar.sh $other --lock" >/dev/null 2>&1 &
  sleep 0.5
  "$LIB_DIR/editar.sh" "$(hostname)" --lock >/dev/null 2>&1
  wait; sleep 2
  v="$(cat "$MOUNT_DIR/contador.txt")"
  [ "$v" = "2" ] && res "Concurrencia con bloqueo flock" ok "contador final $v, sin pérdida" || res "Concurrencia con bloqueo flock" fail "contador final $v, se esperaba 2"

  f="replica-$$.txt"; t0="$(date +%s.%N)"
  echo "$t0" > "$MOUNT_DIR/$f"
  lag=""
  for _ in $(seq 1 60); do
    if rsh servidor-b "test -f $EXPORT_DIR/$f" 2>/dev/null; then t1="$(date +%s.%N)"; lag="$(echo "$t1 - $t0" | bc -l | xargs printf '%.1f')"; break; fi
    sleep 0.3
  done
  [ -n "$lag" ] && res "Retraso de la réplica" ok "${lag} s hasta aparecer en servidor-b" || res "Retraso de la réplica" fail "no llegó a servidor-b"
  rm -f "$MOUNT_DIR/$f"

  echo; info "Resultados guardados en $out"
  printf '     %d pruebas correctas, %d fallidas\n' "$pass" "$fail"
  [ "$fail" -eq 0 ] || return 1
}

cmd_simulate_failure() {
  need_root "$@"; load_config
  step "Simulando la caída de servidor-a"
  for s in sad-replicator sad-app nfs-server sad-agent; do systemctl stop "$s" && ok "Detenido $s"; done
  log_event "caída simulada de servidor-a"
  info "Los clientes y servidor-b lo notarán en unos segundos. Para volver, ejecuta ./setup.sh failback"
  if [ "${2:-}" = "--poweroff" ]; then info "Apagando el equipo"; systemctl poweroff; fi
}

cmd_demote() {
  need_root "$@"; load_config
  # shellcheck disable=SC1090
  . "$DERIVED"
  step "Devolviendo servidor-b a réplica"
  systemctl disable --now sad-app 2>/dev/null || true
  rm -f "$STATE_DIR/promoted"
  sed -i "\|^$EXPORT_DIR |s/(rw,/(ro,/" /etc/exports
  exportfs -ra
  sed -i 's/^NODE_ROLE=.*/NODE_ROLE=replica/' "$APP_DIR/.env"
  log_event "servidor-b vuelve a ser réplica"
  ok "servidor-b es réplica de nuevo"
}

cmd_failback() {
  need_root "$@"; load_config
  # shellcheck disable=SC1090
  . "$DERIVED"
  local b tmp="/tmp/sad-b.db"
  b="$(addr_of servidor-b)"
  step "Failback, servidor-a recupera el servicio"
  peer_ssh_ok "$b" || die "No puedo conectar por SSH con servidor-b."
  systemctl stop sad-replicator sad-app 2>/dev/null || true
  info "Trayendo de servidor-b lo escrito durante la caída..."
  rsh servidor-b "$APP_DIR/.venv/bin/python - $APP_DIR/data/sad.db /tmp/sad-b.db" <<'PY'
import sqlite3, sys
src = sqlite3.connect(sys.argv[1]); dst = sqlite3.connect(sys.argv[2]); src.backup(dst); dst.close(); src.close()
PY
  as_user scp $SSH_OPTS -q "$LAB_USER@$b:/tmp/sad-b.db" "$tmp"
  as_user rsync -a --delete --exclude '.cluster/heartbeat*' --exclude '.cluster/sad.db*' -e "ssh $SSH_OPTS" "$LAB_USER@$b:$EXPORT_DIR/" "$EXPORT_DIR/"
  rm -f "$APP_DIR/data/sad.db" "$APP_DIR/data/sad.db-wal" "$APP_DIR/data/sad.db-shm"
  install -o "$LAB_USER" -g "$LAB_USER" -m 640 "$tmp" "$APP_DIR/data/sad.db"; rm -f "$tmp"
  ok "Archivos y base de datos copiados desde servidor-b"
  rsh servidor-b "sudo $APP_DIR/setup.sh demote" >/dev/null && ok "servidor-b vuelve a ser réplica"
  sed -i 's/^NODE_ROLE=.*/NODE_ROLE=primario/' "$APP_DIR/.env"
  systemctl start nfs-server sad-app sad-replicator sad-agent
  wait_for "sad-app responde" 25 curl -fsS "http://127.0.0.1:$APP_PORT/healthz" || true
  log_event "failback completado, servidor-a es primario"
  FAILS=0; validate_servidor_a; finish
}

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }

main() {
case "${1:-}" in
  servidor-a|servidor-b|cliente) cmd_install "$@" ;;
  status)            cmd_status "$@" ;;
  test)              cmd_test "$@" || exit $? ;;
  simulate-failure)  cmd_simulate_failure "$@" ;;
  failback)          cmd_failback "$@" ;;
  demote)            cmd_demote "$@" ;;
  -h|--help|help|"") usage ;;
  *) usage; exit 1 ;;
esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
