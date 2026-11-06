#!/usr/bin/env bash
# =============================================================================
# setup.sh  Despliegue único del laboratorio de archivos distribuidos.
#
#   sudo ./setup.sh servidor-a        Servidor primario inicial
#   sudo ./setup.sh servidor-b        Réplica, primera en la línea de sucesión
#   sudo ./setup.sh servidor-c        Réplica, segunda en la línea de sucesión
#   sudo ./setup.sh servidor-d        Réplica, tercera en la línea de sucesión
#   sudo ./setup.sh cliente [1|2|3]   Cliente y testigo
#
#   ./setup.sh doctor                 Diagnóstico de este equipo y de la red
#   ./setup.sh status                 Estado de todos los nodos
#   ./setup.sh test                   Pruebas de punta a punta, desde un cliente
#   ./setup.sh simulate-failure       Simula la caída del primario, en el primario
#   ./setup.sh failback               Devuelve el servicio a este servidor
#   ./setup.sh demote                 Devuelve este servidor a réplica
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

# Nodos por defecto. El orden de SERVERS es el orden de sucesión.
SERVERS="servidor-a servidor-b servidor-c servidor-d"
CLIENTS="cliente-1 cliente-2 cliente-3"
ALL_NODES="$SERVERS $CLIENTS"

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

# ---------- entorno ----------
is_wsl() { grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; }
has_systemd() { [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ]; }

# ---------- configuración ----------
load_config() {
  mkdir -p "$CONF_DIR" "$STATE_DIR" "$LIB_DIR"
  if [ ! -f "$CONF" ]; then
    if [ -f "$REPO_DIR/deploy/lab.conf" ]; then cp "$REPO_DIR/deploy/lab.conf" "$CONF"
    else cp "$REPO_DIR/deploy/lab.conf.example" "$CONF"; fi
    chmod 600 "$CONF"
    info "Configuración creada en $CONF"
  fi
  # Un lab.conf editado en Windows trae CRLF y cada valor quedaba con un \r al final.
  if grep -q $'\r' "$CONF"; then sed -i 's/\r$//' "$CONF"; fi
  # shellcheck disable=SC1090
  . "$CONF"
  : "${LAB_USER:=}"
  # Un mismo usuario en todos los nodos. Con usuarios distintos en cada equipo
  # fallaban SSH, rsync y el failback.
  [ -n "$LAB_USER" ] || LAB_USER=sadlab
  [ "$LAB_USER" != "root" ] || die "LAB_USER no puede ser root."
  : "${LAN_CIDR:=24}" "${OVERLAY_MODE:=real}" "${EXPORT_DIR:=/srv/compartido}" "${MOUNT_DIR:=/mnt/compartido}"
  : "${APP_PORT:=5000}" "${AGENT_PORT:=5100}" "${REPL_INTERVAL:=2}" "${WATCH_FAILS:=3}"
  : "${ADMIN_USER:=coordinador}" "${SSH_PASSWORD:=}" "${SUDO_NOPASSWD:=yes}" "${TS_AUTHKEY:=}"
  : "${SEED_USERS:=}" "${LAN_CONFIGURE:=yes}" "${ADMIN_PASS:=}" "${APP_DIR:=/opt/sad-app}"
  : "${WITNESS_QUORUM:=}"
  ALL_NODES="$SERVERS $CLIENTS"
  local nc; nc=$(wc -w <<<"$CLIENTS")
  [ -n "$WITNESS_QUORUM" ] || WITNESS_QUORUM=$((nc / 2 + 1))
  LAB_HOME="$(getent passwd "$LAB_USER" | cut -d: -f6 || true)"
  [ -n "$LAB_HOME" ] || LAB_HOME="/home/$LAB_USER"
}

as_user() { sudo -u "$LAB_USER" -H "$@"; }

# servidor-a -> A, cliente-1 -> C1
suffix_of() {
  case "$1" in
    servidor-*) printf '%s' "${1#servidor-}" | tr 'a-z' 'A-Z' ;;
    cliente-*)  printf 'C%s' "${1#cliente-}" ;;
    *) return 1 ;;
  esac
}
var_of() { local v; v="$1_$(suffix_of "$2")"; printf '%s' "${!v:-}"; }
lan_of() { var_of LAN "$1"; }
ov_of()  { var_of OV "$1"; }
key_of() { printf 'ADDR_%s' "$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')"; }
is_server() { case " $SERVERS " in *" $1 "*) return 0 ;; esac; return 1; }
is_client() { case " $CLIENTS " in *" $1 "*) return 0 ;; esac; return 1; }
first_server() { set -- $SERVERS; printf '%s' "$1"; }

# Dirección con la que los demás nodos alcanzan a cada uno.
addr_of() {
  case "$OVERLAY_MODE" in
    sim)  ov_of "$1" ;;
    # En modo real se usa el nombre. sad-hosts lo escribe en /etc/hosts con la IP
    # que Tailscale le dio a ese nodo, así no depende de MagicDNS. TSIP_X fija una IP a mano.
    real) local ip; ip="$(var_of TSIP "$1")"; printf '%s' "${ip:-$1}" ;;
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
    echo "WITNESS_QUORUM=$WITNESS_QUORUM"
    echo "SERVERS=\"$SERVERS\""
    echo "CLIENTS=\"$CLIENTS\""
    for n in $ALL_NODES; do
      printf '%s=%s\n' "$(key_of "$n")" "$(addr_of "$n")"
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

wait_for() { # wait_for "descripción" segundos comando...
  local desc="$1" secs="$2"; shift 2
  local i=0
  while [ "$i" -lt "$secs" ]; do "$@" >/dev/null 2>&1 && { ok "$desc"; return 0; }; sleep 1; i=$((i + 1)); done
  warn "No se cumplió en ${secs}s, $desc"; return 1
}

log_event() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }

# Consulta el agente de un nodo. Imprime el JSON o nada.
agent_status() { curl -fsS -m 2 "http://$(addr_of "$1"):$AGENT_PORT/status" 2>/dev/null || true; }

# Servidor que hoy es primario según los agentes, o nada.
current_primary() {
  local s j
  for s in $SERVERS; do
    j="$(agent_status "$s")"
    [ -n "$j" ] && [ "$(jq -r .effective_role <<<"$j" 2>/dev/null)" = "primario" ] && { printf '%s' "$s"; return 0; }
  done
  return 1
}

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

# Revisa lo que antes fallaba a mitad de camino y avisa antes de tocar nada.
step_preflight() {
  local role="$1"
  step "Comprobaciones previas"
  if is_wsl; then
    info "Equipo WSL detectado"
    if ! has_systemd; then
      wsl_conf_set boot systemd true
      die "WSL no tiene systemd activo. Ya lo activé en /etc/wsl.conf. En PowerShell ejecuta  wsl --shutdown , abre Ubuntu de nuevo y repite setup.sh."
    fi
    ok "systemd activo en WSL"
    if [ "$role" != "cliente" ]; then
      modprobe nfsd 2>/dev/null || true
      grep -qw nfsd /proc/filesystems \
        || die "El kernel de WSL no trae el servidor NFS (nfsd). Los servidores deben ser máquinas virtuales con Ubuntu Server. En WSL usa el rol cliente."
    fi
  fi
  if [ "$role" = "cliente" ]; then
    modprobe nfs 2>/dev/null || true
    grep -qw nfs4 /proc/filesystems || grep -qw nfs /proc/filesystems \
      || warn "El kernel no muestra soporte NFS todavía. Si el montaje falla, actualiza WSL con  wsl --update"
  fi
  ok "Equipo apto para el rol $role"
}

# Edita /etc/wsl.conf sin borrar lo que el usuario ya tenía.
wsl_conf_set() {
  python3 - "$1" "$2" "$3" <<'PY'
import configparser, sys
sec, key, val = sys.argv[1:]
c = configparser.ConfigParser()
c.optionxform = str
c.read("/etc/wsl.conf")
if not c.has_section(sec):
    c.add_section(sec)
c.set(sec, key, val)
with open("/etc/wsl.conf", "w") as f:
    c.write(f)
PY
}

step_base() {
  step "Paquetes base"
  apt_install curl git rsync python3 python3-venv python3-pip jq iproute2 sshpass netcat-openbsd openssh-server bc
  systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || true
  # Relojes sincronizados. El retraso de la réplica se mide comparando horas de dos equipos.
  timedatectl set-ntp true >/dev/null 2>&1 || true
}

# Usuario común en todos los nodos.
step_user() {
  step "Usuario del laboratorio $LAB_USER"
  if ! id "$LAB_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$LAB_USER"; ok "Usuario $LAB_USER creado"
  else ok "Usuario $LAB_USER ya existe"; fi
  LAB_HOME="$(getent passwd "$LAB_USER" | cut -d: -f6)"
  # lab.conf guarda claves. Lo lee root y el grupo del laboratorio, que usa el replicador.
  chown root:"$LAB_USER" "$CONF"; chmod 640 "$CONF"
  if [ -n "$SSH_PASSWORD" ]; then
    echo "$LAB_USER:$SSH_PASSWORD" | chpasswd
    # Ubuntu Server trae PasswordAuthentication no en 50-cloud-init.conf. Sin esto
    # ssh-copy-id fallaba y las llaves nunca se intercambiaban. El primer valor gana.
    if write_file /etc/ssh/sshd_config.d/10-sad-lab.conf 644 <<EOF
# Generado por setup.sh. Permite el primer intercambio de llaves del laboratorio.
PasswordAuthentication yes
KbdInteractiveAuthentication yes
EOF
    then systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1 || true; ok "SSH acepta contraseña para el intercambio de llaves"
    else ok "SSH ya acepta contraseña para el intercambio de llaves"; fi
  else
    warn "SSH_PASSWORD está vacío. Las llaves SSH tendrán que copiarse a mano."
  fi
  if [ "$SUDO_NOPASSWD" = "yes" ]; then
    echo "$LAB_USER ALL=(ALL) NOPASSWD:ALL" | write_file /etc/sudoers.d/90-sad-lab 440 && ok "sudo sin contraseña para $LAB_USER" || ok "sudo ya configurado"
  fi
}

# Copia el proyecto a la misma ruta en todos los nodos. Antes cada uno lo tenía en
# su propio home y el failback llamaba rutas que no existían en el otro equipo.
step_code() {
  step "Código del proyecto en $APP_DIR"
  mkdir -p "$APP_DIR"
  if [ "$(cd "$APP_DIR" && pwd -P)" != "$(cd "$REPO_DIR" && pwd -P)" ]; then
    rsync -a --delete \
      --exclude '/.git/' --exclude '/.venv/' --exclude '/.env' --exclude '/data/' \
      --exclude '/storage/' --exclude '/logs/' --exclude '/capturas/' --exclude '__pycache__/' \
      "$REPO_DIR/" "$APP_DIR/"
    ok "Proyecto copiado desde $REPO_DIR"
  else ok "El proyecto ya está en $APP_DIR"; fi
  mkdir -p "$APP_DIR/data"
  chown -R "$LAB_USER":"$LAB_USER" "$APP_DIR"
  chmod +x "$APP_DIR/setup.sh"
}

step_identity() {
  local node="$1"
  step "Identidad del nodo $node"
  if is_wsl; then
    # En WSL hostnamectl no sobrevive al reinicio. El nombre se fija en wsl.conf.
    wsl_conf_set network hostname "$node"
    wsl_conf_set network generateHosts false
    if [ "$(hostname)" != "$node" ]; then
      hostname "$node" 2>/dev/null || true
      warn "Nombre fijado en /etc/wsl.conf. Queda permanente tras  wsl --shutdown"
    else ok "Nombre del equipo ya es $node"; fi
  elif [ "$(hostnamectl --static 2>/dev/null || hostname)" != "$node" ]; then
    hostnamectl set-hostname "$node"; ok "Nombre del equipo cambiado a $node"
  else ok "Nombre del equipo ya es $node"
  fi
  grep -qE "^127\.0\.1\.1\s+$node\b" /etc/hosts || echo "127.0.1.1 $node" >> /etc/hosts
  sed -i '/# sad-lab begin/,/# sad-lab end/d' /etc/hosts
  if [ "$OVERLAY_MODE" != "real" ]; then
    {
      echo "# sad-lab begin"
      for n in $ALL_NODES; do echo "$(addr_of "$n") $n"; done
      echo "# sad-lab end"
    } >> /etc/hosts
    ok "Nombres de los nodos añadidos a /etc/hosts"
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
  # Con Tailscale real no hace falta una red entre las VM. Antes este paso ponía una
  # IP fija en una segunda tarjeta que en modo real no existía o no se usaba.
  [ "$OVERLAY_MODE" = "real" ] && return 0
  step "Red real entre las máquinas"
  if [ "$LAN_CONFIGURE" != "yes" ] || is_wsl; then warn "No se toca la red local"; return; fi
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

tailscale_hostname_ok() {
  tailscale status --json 2>/dev/null | jq -e --arg n "$1" '(.Self.HostName|ascii_downcase) == $n' >/dev/null
}

step_overlay() {
  local node="$1" mine peer dns
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
        curl -fsSL https://tailscale.com/install.sh | sh >>"$LOG_FILE" 2>&1 || die "No se pudo instalar Tailscale. Revisa $LOG_FILE"
      fi
      systemctl enable --now tailscaled >/dev/null 2>&1
      if [ "$(tailscale status --json 2>/dev/null | jq -r .BackendState)" != "Running" ]; then
        # --accept-dns=false  En WSL Tailscale peleaba con el resolv.conf que genera
        # Windows y MagicDNS dejaba de resolver. Los nombres los pone sad-hosts.
        if [ -n "$TS_AUTHKEY" ]; then tailscale up --authkey="$TS_AUTHKEY" --hostname="$node" --accept-dns=false
        else warn "Autoriza este nodo con el enlace que aparece a continuación."; tailscale up --hostname="$node" --accept-dns=false; fi
      fi
      # Si el nodo ya estaba unido con otro nombre, tailscale up no lo cambiaba.
      tailscale set --hostname="$node" --accept-dns=false >/dev/null 2>&1 || true
      tailscale_hostname_ok "$node" && ok "Tailscale activo como $node, IP $(tailscale ip -4 | head -1)" \
        || warn "Tailscale no reporta el nombre $node. Revisa  tailscale status"
      dns="$(tailscale status --json | jq -r '.Self.DNSName' | cut -d. -f1)"
      if [ -n "$dns" ] && [ "$dns" != "$node" ]; then
        warn "Tailscale te nombró $dns porque ya existe otra máquina $node en la red."
        warn "Borra la máquina vieja en https://login.tailscale.com/admin/machines. setup.sh funciona igual."
      fi
      step_hosts_sync
      ;;
    *)
      echo none > $CONF_DIR/overlay-mode
      ok "Sin red superpuesta. Se usan las direcciones LAN."
      ;;
  esac
}

# Escribe en /etc/hosts la IP de Tailscale de cada nodo y la refresca cada 30 s.
# Así los nombres resuelven aunque MagicDNS no funcione y aunque un nodo se una tarde.
step_hosts_sync() {
  write_file $LIB_DIR/hosts-sync.sh 755 <<'EOF' || true
#!/usr/bin/env bash
# Actualiza el bloque sad-lab de /etc/hosts con las IP de Tailscale de los nodos.
set -u
. /etc/sad-lab/lab.conf
. /etc/sad-lab/derived.conf
json="$(tailscale status --json 2>/dev/null)" || exit 0
block="$(TS_JSON="$json" python3 - "$SERVERS $CLIENTS" <<'PY'
import json, os, sys
nodes = sys.argv[1].split()
data = json.loads(os.environ["TS_JSON"])
peers = [data.get("Self", {})] + list((data.get("Peer") or {}).values())
over = {}
for line in open("/etc/sad-lab/lab.conf"):
    line = line.strip()
    if line.startswith("TSIP_") and "=" in line:
        k, v = line.split("=", 1)
        v = v.strip().strip('"')
        if v:
            over[k[5:]] = v
def suffix(n):
    return n.split("-", 1)[1].upper() if n.startswith("servidor-") else "C" + n.split("-", 1)[1]
out = []
for n in nodes:
    ip = over.get(suffix(n))
    if not ip:
        found = [p for p in peers if (p.get("HostName") or "").lower() == n]
        found.sort(key=lambda p: not p.get("Online", True))
        for p in found:
            v4 = [a for a in p.get("TailscaleIPs") or [] if "." in a]
            if v4:
                ip = v4[0]
                break
    if ip:
        out.append(f"{ip} {n}")
print("\n".join(out))
PY
)"
[ -n "$block" ] || exit 0
new="$(sed '/# sad-lab begin/,/# sad-lab end/d' /etc/hosts; printf '# sad-lab begin\n%s\n# sad-lab end\n' "$block")"
if [ "$new" != "$(cat /etc/hosts)" ]; then printf '%s\n' "$new" > /etc/hosts; fi
EOF
  write_file /etc/systemd/system/sad-hosts.service <<EOF || true
[Unit]
Description=Nombres de los nodos del laboratorio desde Tailscale
After=tailscaled.service

[Service]
Type=oneshot
ExecStart=$LIB_DIR/hosts-sync.sh
EOF
  write_file /etc/systemd/system/sad-hosts.timer <<EOF || true
[Unit]
Description=Refresca los nombres de los nodos cada 30 s

[Timer]
OnBootSec=5
OnUnitActiveSec=30

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now sad-hosts.timer >/dev/null 2>&1
  "$LIB_DIR/hosts-sync.sh" || true
  local n absent=""
  for n in $ALL_NODES; do getent hosts "$n" >/dev/null || absent="$absent $n"; done
  if [ -z "$absent" ]; then ok "Los $(wc -w <<<"$ALL_NODES") nodos resuelven por nombre"
  else warn "Todavía no aparecen en Tailscale:$absent. Se agregan solos cuando se unan."; fi
}

ensure_ssh_key() {
  local key="$LAB_HOME/.ssh/id_ed25519"
  if [ ! -f "$key" ]; then
    as_user mkdir -p "$LAB_HOME/.ssh"; as_user chmod 700 "$LAB_HOME/.ssh"
    as_user ssh-keygen -q -t ed25519 -N "" -f "$key"
    ok "Llave SSH creada"
  else ok "Llave SSH ya existe"; fi
}

SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=accept-new"
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
      else warn "No se pudo copiar la llave a $peer. ¿Ya corrió setup.sh allá con la misma SSH_PASSWORD?"; fi
    else warn "Define SSH_PASSWORD en $CONF o ejecuta ssh-copy-id hacia $peer"; fi
  done
}

write_agent() {
  local role="$1" node="$2" targets="" s
  step "Agente de estado"
  if [ "$role" = "cliente" ]; then
    # El testigo comprueba el puerto NFS de cada servidor.
    for s in $SERVERS; do targets="$targets${targets:+,}$s=$(addr_of "$s"):2049"; done
  fi
  write_file $CONF_DIR/agent.env 644 <<EOF || true
NODE_NAME=$node
NODE_ROLE=$role
EXPORT_DIR=$EXPORT_DIR
MOUNT_DIR=$MOUNT_DIR
AGENT_PORT=$AGENT_PORT
FIRST_SERVER=$(first_server)
PROBE_TARGETS=$targets
EOF
  write_file /etc/systemd/system/sad-agent.service <<EOF || true
[Unit]
Description=Agente de estado del laboratorio
After=network-online.target

[Service]
EnvironmentFile=$CONF_DIR/agent.env
ExecStart=/usr/bin/python3 $APP_DIR/cluster/agent.py
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
# Un servidor es primario si existe $STATE_DIR/primary. El archivo guarda la época,
# la hora en que asumió. Si dos se creen primarios, cede el de época más vieja.
is_primary_local() { [ -f "$STATE_DIR/primary" ]; }

step_role_state() {
  local node="$1" other
  step "Papel de $node en el clúster"
  if [ -f "$STATE_DIR/initialized" ]; then
    is_primary_local && ok "$node es primario" || ok "$node es réplica"
    return
  fi
  if [ "$node" = "$(first_server)" ]; then
    other="$(current_primary || true)"
    if [ -n "$other" ] && [ "$other" != "$node" ]; then
      warn "$other ya es primario. $node entra como réplica, usa failback para recuperar el servicio."
    else
      date +%s.%N > "$STATE_DIR/primary"; ok "$node arranca como primario"
    fi
  else ok "$node arranca como réplica, puesto $(server_rank "$node") en la sucesión"; fi
  touch "$STATE_DIR/initialized"
}

server_rank() { local i=0 s; for s in $SERVERS; do i=$((i + 1)); [ "$s" = "$1" ] && { echo "$i"; return; }; done; echo 0; }

step_nfs_server() {
  local opts line uid gid
  step "Servidor NFS, carpeta $EXPORT_DIR"
  apt_install nfs-kernel-server
  mkdir -p "$EXPORT_DIR/.cluster"
  chown -R "$LAB_USER":"$LAB_USER" "$EXPORT_DIR"; chmod 775 "$EXPORT_DIR"
  modprobe nfsd 2>/dev/null || true
  grep -qw nfsd /proc/filesystems || die "El kernel no trae nfsd."
  if is_primary_local; then opts="rw"; else opts="ro"; fi
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
  local node="$1" secret admin_pass peers="" s tmp key v
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
  write_credentials() {
    printf 'Coordinador  usuario=%s  clave=%s\n' "$(env_get ADMIN_USER)" "$(env_get ADMIN_PASS)" > $CONF_DIR/credenciales.txt
    chmod 600 $CONF_DIR/credenciales.txt
  }
  # Todos los servidores usan el mismo SECRET y la misma clave del coordinador, así
  # la sesión sigue valiendo cuando otro servidor asume. Se toman del primer servidor
  # que responda y ya los tenga.
  if [ "$node" != "$(first_server)" ]; then
    tmp="$(mktemp)"; chmod 666 "$tmp"
    for s in $SERVERS; do
      [ "$s" = "$node" ] && continue
      if as_user scp $SSH_OPTS -q "$LAB_USER@$(addr_of "$s"):$APP_DIR/.env" "$tmp" 2>/dev/null && grep -q '^SECRET=' "$tmp"; then
        for key in SECRET ADMIN_USER ADMIN_PASS; do
          v="$(grep "^$key=" "$tmp" | head -1 | cut -d= -f2- || true)"; [ -n "$v" ] && env_set "$key" "$v"
        done
        ok "SECRET y clave del coordinador sincronizados desde $s"; break
      fi
    done
    rm -f "$tmp"
  fi
  if [ -z "$(env_get SECRET)" ]; then
    secret="$(python3 -c 'import secrets;print(secrets.token_hex(32))')"; env_set SECRET "$secret"
    [ "$node" = "$(first_server)" ] || warn "No pude leer el .env de otro servidor. Repite setup.sh cuando $(first_server) esté listo."
  fi
  if [ -z "$(env_get ADMIN_PASS)" ]; then
    admin_pass="${ADMIN_PASS:-$(python3 -c 'import secrets;print(secrets.token_urlsafe(12))')}"
    env_set ADMIN_USER "$ADMIN_USER"; env_set ADMIN_PASS "$admin_pass"
  fi
  write_credentials
  env_set COOKIE_SECURE 0
  env_set STORAGE_DIR "$EXPORT_DIR/sad-storage"
  env_set NODE_NAME "$node"
  if is_primary_local; then env_set NODE_ROLE primario; else env_set NODE_ROLE replica; fi
  for s in $ALL_NODES; do peers="$peers${peers:+,}$s=http://$(addr_of "$s"):$AGENT_PORT"; done
  env_set CLUSTER_NODES "$peers"
  for s in $SERVERS; do [ "$s" != "$node" ] && { env_set PEER_WEB_URL "http://$(addr_of "$s"):$APP_PORT"; break; }; done
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
  if is_primary_local; then
    systemctl enable sad-app >/dev/null 2>&1
    systemctl restart sad-app
    wait_for "sad-app responde en el puerto $APP_PORT" 25 curl -fsS "http://127.0.0.1:$APP_PORT/healthz" || true
  else
    systemctl disable --now sad-app >/dev/null 2>&1 || true
    ok "sad-app instalada y en espera, solo arranca si este servidor asume"
  fi
}

step_seed_users() {
  [ -n "$SEED_USERS" ] || return 0
  is_primary_local || return 0
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

# Corre en todos los servidores. Solo trabaja mientras este servidor sea el primario,
# y entonces copia a todas las demás réplicas. Si otro asume, sigue desde allá.
step_replicator() {
  step "Replicador hacia las demás réplicas"
  write_file $LIB_DIR/replicate.sh 755 <<'EOF' || true
#!/usr/bin/env bash
# Mientras este servidor sea el primario copia la carpeta y la base a cada réplica.
set -u
. /etc/sad-lab/lab.conf
. /etc/sad-lab/derived.conf
SSH="ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new"
addr() { local v="ADDR_$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')"; printf '%s' "${!v}"; }
declare -A state
mkdir -p "$EXPORT_DIR/.cluster"
while true; do
  if [ ! -f /var/lib/sad-lab/primary ]; then sleep "$REPL_INTERVAL"; continue; fi
  printf '{"ts": %s, "node": "%s"}\n' "$(date +%s.%N)" "$NODE_NAME" > "$EXPORT_DIR/.cluster/heartbeat.tmp" \
    && mv -f "$EXPORT_DIR/.cluster/heartbeat.tmp" "$EXPORT_DIR/.cluster/heartbeat"
  if [ -f "$APP_DIR/data/sad.db" ]; then
    "$APP_DIR/.venv/bin/python" - "$APP_DIR/data/sad.db" "$EXPORT_DIR/.cluster/sad.db.tmp" <<'PY' 2>/dev/null && mv -f "$EXPORT_DIR/.cluster/sad.db.tmp" "$EXPORT_DIR/.cluster/sad.db"
import sqlite3, sys
src = sqlite3.connect(sys.argv[1]); dst = sqlite3.connect(sys.argv[2])
src.backup(dst); dst.close(); src.close()
PY
  fi
  # Si otro servidor también se cree primario no se copia nada. El vigilante decide
  # cuál cede, y así nunca se pisa la carpeta del primario bueno con datos viejos.
  other=""
  for s in $SERVERS; do
    [ "$s" = "$NODE_NAME" ] && continue
    role="$(curl -fsS -m 2 "http://$(addr "$s"):$AGENT_PORT/status" 2>/dev/null | jq -r .effective_role 2>/dev/null || true)"
    [ "$role" = "primario" ] && { other="$s"; break; }
  done
  if [ -n "$other" ]; then
    [ "${state[split_]:-}" = "split" ] || { echo "$other también es primario, pauso la réplica"; state[split_]=split; }
    sleep "$REPL_INTERVAL"; continue
  fi
  state[split_]=""
  for s in $SERVERS; do
    [ "$s" = "$NODE_NAME" ] && continue
    a="$(addr "$s")"
    if timeout 60 rsync -a --delete --exclude 'lost+found' -e "$SSH" "$EXPORT_DIR/" "$LAB_USER@$a:$EXPORT_DIR/" 2>/tmp/sad-repl.err; then
      [ "${state[$s]:-}" = "ok" ] || { echo "réplica al día con $s"; state[$s]=ok; }
    else
      [ "${state[$s]:-}" = "fail" ] || { echo "$s no responde: $(head -1 /tmp/sad-repl.err)"; state[$s]=fail; }
    fi
  done
  sleep "$REPL_INTERVAL"
done
EOF
  write_file /etc/systemd/system/sad-replicator.service <<EOF || true
[Unit]
Description=Replicador de la carpeta compartida hacia las réplicas
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

# Corre en todos los servidores.
#   Réplica  si no hay primario vivo y todos los servidores anteriores en la sucesión
#            están caídos, pregunta a los testigos y asume si la mayoría confirma.
#   Primario si encuentra otro primario con época más nueva, cede y vuelve a réplica.
step_watchdog() {
  step "Vigilante con testigos"
  write_file $LIB_DIR/watchdog.sh 755 <<'EOF' || true
#!/usr/bin/env bash
# Sucesión ordenada de servidores con testigos por mayoría y época contra cerebro dividido.
set -u
. /etc/sad-lab/lab.conf
. /etc/sad-lab/derived.conf
LOG=/var/log/sad-lab.log
STATE=/var/lib/sad-lab
say() { printf '%s [vigilante] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
addr() { local v="ADDR_$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')"; printf '%s' "${!v}"; }
status_of() { curl -fsS -m 2 "http://$(addr "$1"):$AGENT_PORT/status" 2>/dev/null || true; }
reachable() { nc -z -w2 "$(addr "$1")" 2049 2>/dev/null || nc -z -w2 "$(addr "$1")" "$AGENT_PORT" 2>/dev/null; }
my_epoch() { cat "$STATE/primary" 2>/dev/null || echo 0; }

# Servidores que van antes que yo en la sucesión.
ahead() { local s; for s in $SERVERS; do [ "$s" = "$NODE_NAME" ] && return; echo "$s"; done; }

# ¿Hay un primario vivo? Devuelve su nombre.
live_primary() {
  local s j
  for s in $SERVERS; do
    [ "$s" = "$NODE_NAME" ] && continue
    j="$(status_of "$s")"
    [ "$(jq -r .effective_role <<<"$j" 2>/dev/null)" = "primario" ] || continue
    nc -z -w2 "$(addr "$s")" 2049 2>/dev/null && { echo "$s"; return 0; }
  done
  return 1
}

# Pregunta a cada testigo si ve a alguno de los servidores anteriores. Imprime "ven noven".
witnesses() {
  local w s r sees=0 nosee=0 answered seen
  for w in $CLIENTS; do
    answered=0; seen=0
    for s in "$@"; do
      r="$(curl -fsS -m 3 "http://$(addr "$w"):$AGENT_PORT/probe?target=$s" 2>/dev/null | jq -r '.reachable' 2>/dev/null || true)"
      [ -n "$r" ] || continue
      answered=1; [ "$r" = "true" ] && seen=1
    done
    [ "$answered" -eq 1 ] || continue
    if [ "$seen" -eq 1 ]; then sees=$((sees + 1)); else nosee=$((nosee + 1)); fi
  done
  echo "$sees $nosee"
}

promote() {
  say "Asumiendo como primario"
  date +%s.%N > "$STATE/primary"
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
  say "$NODE_NAME es ahora el primario, replica hacia las demás réplicas"
}

fails=0
say "Vigilante de $NODE_NAME, sucesión: $SERVERS, quórum de testigos $WITNESS_QUORUM"
while true; do
  if [ -f "$STATE/primary" ]; then
    # Cerebro dividido. Si otro primario es más nuevo, este cede.
    for s in $SERVERS; do
      [ "$s" = "$NODE_NAME" ] && continue
      j="$(status_of "$s")"
      [ "$(jq -r .effective_role <<<"$j" 2>/dev/null)" = "primario" ] || continue
      other="$(jq -r '.primary_epoch // 0' <<<"$j")"
      if python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) > float(sys.argv[2]) else 1)" "$other" "$(my_epoch)"; then
        say "$s es primario desde después que yo. Cedo y vuelvo a réplica"
        "$APP_DIR/setup.sh" demote >/dev/null 2>&1 || true
        break
      fi
    done
    fails=0; sleep 2; continue
  fi

  if p="$(live_primary)"; then
    [ "$fails" -eq 0 ] || say "$p responde como primario"
    fails=0; sleep 2; continue
  fi
  fails=$((fails + 1)); say "No hay primario que responda, fallo $fails de $WATCH_FAILS"
  if [ "$fails" -lt "$WATCH_FAILS" ]; then sleep 2; continue; fi
  fails=0

  # Sin latido nunca hubo un primario. No se asume en una instalación a medias.
  if [ ! -f "$EXPORT_DIR/.cluster/heartbeat" ]; then say "Nunca recibí réplica, no asumo"; sleep 2; continue; fi

  before="$(ahead | xargs)"
  waiting=""
  for s in $before; do reachable "$s" && waiting="$s" && break; done
  if [ -n "$waiting" ]; then say "$waiting sigue vivo y va antes en la sucesión, le toca a él"; sleep 2; continue; fi

  if [ -z "$before" ]; then set -- $SERVERS; else set -- $before; fi
  read -r sees nosee < <(witnesses "$@")
  say "Testigos que ven a ${before:-algún servidor}: $sees, que no: $nosee, quórum $WITNESS_QUORUM"
  if [ "$sees" -eq 0 ] && [ "$nosee" -ge "$WITNESS_QUORUM" ]; then promote
  elif [ "$sees" -gt 0 ]; then say "Algún testigo todavía ve un servidor anterior. El problema puede ser mi red, no asumo"
  else say "Sin mayoría de testigos, no asumo"; fi
  sleep 2
done
EOF
  write_file /etc/systemd/system/sad-watchdog.service <<EOF || true
[Unit]
Description=Vigilante de la sucesión de servidores
After=network-online.target nfs-server.service sad-agent.service

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
  step "Cliente NFS"
  apt_install nfs-common
  mkdir -p "$MOUNT_DIR"
  write_file /usr/local/bin/sad-mount 755 <<'EOF' || true
#!/usr/bin/env bash
# sad-mount [auto|salir|servidor-x]   Monta la carpeta desde el servidor que esté vivo.
. /etc/sad-lab/derived.conf
mode="${1:-auto}"
OPTS="soft,timeo=30,retrans=2"
addr() { local v="ADDR_$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')"; printf '%s' "${!v}"; }
writable() { timeout 5 sh -c "f=$MOUNT_DIR/.probe-\$(hostname); touch \$f && rm -f \$f" 2>/dev/null; }
try() {  # try dirección  -> 0 si monta
  umount -f -l "$MOUNT_DIR" 2>/dev/null
  timeout 15 mount -t nfs4 -o "$OPTS" "$1:$EXPORT_DIR" "$MOUNT_DIR" 2>/dev/null
}
case "$mode" in
  salir) umount -f -l "$MOUNT_DIR" 2>/dev/null; echo "Desmontado."; exit 0 ;;
  servidor-*) try "$(addr "$mode")" && echo "Montado desde $mode" && exit 0; exit 1 ;;
esac
ro_host=""
for s in $SERVERS; do
  if try "$(addr "$s")"; then
    if writable; then echo "Montado desde $s con escritura"; exit 0; fi
    [ -n "$ro_host" ] || ro_host="$s"
  fi
done
if [ -n "$ro_host" ] && try "$(addr "$ro_host")"; then echo "Montado desde $ro_host solo para lectura"; exit 0; fi
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
After=network-online.target sad-overlay-sim.service tailscaled.service sad-hosts.service
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
  systemctl restart sad-mount || true
  systemctl restart sad-mount-watch
  if mountpoint -q "$MOUNT_DIR"; then ok "Carpeta montada en $MOUNT_DIR"; else warn "Todavía no se pudo montar. Los servidores deben estar listos."; fi
  if is_wsl; then
    warn "WSL se apaga solo cuando no hay ventanas abiertas y el testigo desaparece."
    warn "En Windows ejecuta deploy\\windows\\cliente-wsl.cmd para mantenerlo encendido."
  fi
}

# =============================================================================
# Validaciones por rol
# =============================================================================
# En modo real la IP la asigna Tailscale. Antes se buscaba la IP simulada OV_X y la
# validación siempre fallaba aunque todo estuviera bien.
overlay_ip_present() {
  case "$OVERLAY_MODE" in
    real) [ -n "$(tailscale ip -4 2>/dev/null | head -1)" ] ;;
    sim)  ip -4 -o addr show | grep -q " $(ov_of "$1")/" ;;
    *)    return 0 ;;
  esac
}
svc_active() { systemctl is-active --quiet "$1"; }
http_ok() { curl -fsS -m 3 "$1" >/dev/null; }
exports_has() { grep -q "^$EXPORT_DIR .*($1," /etc/exports; }
heartbeat_fresh() {
  local f="$EXPORT_DIR/.cluster/heartbeat" ts
  [ -f "$f" ] || return 1
  ts="$(jq -r .ts "$f")"
  python3 -c "import sys,time; sys.exit(0 if time.time()-float(sys.argv[1]) < $1 else 1)" "$ts"
}
all_names_resolve() { local n; for n in $ALL_NODES; do getent hosts "$(addr_of "$n")" >/dev/null || return 1; done; }

validate_server() {
  local node="$1" s
  step "Validación final de $node"
  check "Red privada presente ($OVERLAY_MODE)" overlay_ip_present "$node"
  check "Servicio nfs-server activo" svc_active nfs-server
  check "Agente responde" http_ok "http://127.0.0.1:$AGENT_PORT/health"
  check "Vigilante activo" svc_active sad-watchdog
  check "Replicador activo" svc_active sad-replicator
  if is_primary_local; then
    check "NFS exportando en lectura y escritura" exports_has rw
    check "sad-app responde en /healthz" http_ok "http://127.0.0.1:$APP_PORT/healthz"
    check "Latido reciente en la carpeta compartida" heartbeat_fresh 10
  else
    check "NFS exportando en solo lectura" exports_has ro
    check "sad-app instalada en $APP_DIR/.venv" test -x "$APP_DIR/.venv/bin/gunicorn"
    check_soft "Réplica recibiendo latidos del primario" heartbeat_fresh 20
  fi
  check_soft "Todos los nodos resuelven por nombre" all_names_resolve
  for s in $SERVERS; do
    [ "$s" = "$node" ] && continue
    check_soft "SSH sin contraseña hacia $s" peer_ssh_ok "$(addr_of "$s")"
  done
}

validate_cliente() {
  step "Validación final de $1"
  check "Red privada presente ($OVERLAY_MODE)" overlay_ip_present "$1"
  check "Agente responde" http_ok "http://127.0.0.1:$AGENT_PORT/health"
  check "Vigilante del montaje activo" svc_active sad-mount-watch
  check_soft "Todos los nodos resuelven por nombre" all_names_resolve
  check_soft "Carpeta montada en $MOUNT_DIR" mountpoint -q "$MOUNT_DIR"
  check_soft "Se puede escribir en la carpeta" sh -c "touch $MOUNT_DIR/.setup-probe && rm -f $MOUNT_DIR/.setup-probe"
}

# =============================================================================
# Subcomandos
# =============================================================================
cmd_install() {
  local role="$1" node
  case "$role" in
    servidor-*) node="$role" ;;
    cliente)
      local n="${2:-}"
      [ -n "$n" ] || n="$(hostname | sed -n 's/^cliente-\([0-9]\+\)$/\1/p')"
      [ -n "$n" ] || die "Indica el número del cliente, por ejemplo: ./setup.sh cliente 1"
      node="cliente-$n" ;;
    *) die "Rol desconocido. Usa servidor-a a servidor-d o cliente N." ;;
  esac
  need_root "$@"; load_config
  if [ "$role" = "cliente" ]; then is_client "$node" || die "$node no está en CLIENTS ($CLIENTS) de $CONF"
  else is_server "$node" || die "$node no está en SERVERS ($SERVERS) de $CONF"; role=servidor; fi
  printf '%sLaboratorio de archivos distribuidos%s  nodo %s%s%s  red %s  usuario %s\n' "$C_BOLD" "$C_OFF" "$C_BOLD" "$node" "$C_OFF" "$OVERLAY_MODE" "$LAB_USER"
  step_preflight "$role"
  step_base
  step_user
  step_code
  write_derived "$role" "$node"
  step_identity "$node"
  step_lan "$node"
  step_overlay "$node"
  write_derived "$role" "$node"
  step_ssh_keys "$node"
  case "$role" in
    servidor)
      write_agent "$role" "$node"
      step_role_state "$node"
      step_nfs_server; step_app "$node"; step_seed_users
      step_replicator; step_watchdog; validate_server "$node"
      [ -f $CONF_DIR/credenciales.txt ] && is_primary_local && { echo; info "$(cat $CONF_DIR/credenciales.txt)"; } ;;
    cliente)
      write_agent "cliente" "$node"; step_client; validate_cliente "$node" ;;
  esac
  finish
}

cmd_doctor() {
  need_root "$@"; load_config
  local n a j t skew
  step "Este equipo"
  if is_wsl; then info "WSL $(uname -r)"; check "systemd activo" has_systemd; else info "Linux $(uname -r)"; fi
  check_soft "Kernel con servidor NFS, solo hace falta en servidores" sh -c 'modprobe nfsd 2>/dev/null; grep -qw nfsd /proc/filesystems'
  check_soft "Kernel con cliente NFS" sh -c 'modprobe nfs 2>/dev/null; grep -Eqw "nfs|nfs4" /proc/filesystems'
  check "Usuario $LAB_USER existe" id "$LAB_USER"
  check "Reloj sincronizado" sh -c 'timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes'
  if [ "$OVERLAY_MODE" = "real" ]; then
    check "Tailscale conectado" sh -c '[ "$(tailscale status --json | jq -r .BackendState)" = Running ]'
    info "Nombre en Tailscale: $(tailscale status --json 2>/dev/null | jq -r .Self.HostName)  IP $(tailscale ip -4 2>/dev/null | head -1)"
  fi
  step "Los demás nodos"
  printf '     %-12s %-16s %-6s %-6s %-6s %s\n' NODO IP PING SSH AGENTE "DESFASE RELOJ"
  for n in $ALL_NODES; do
    a="$(getent hosts "$(addr_of "$n")" | awk '{print $1; exit}')"
    j="$(agent_status "$n")"
    skew="-"
    if [ -n "$j" ]; then t="$(jq -r .time <<<"$j")"; skew="$(python3 -c "import sys,time; print(f'{float(sys.argv[1])-time.time():+.1f} s')" "$t")"; fi
    printf '     %-12s %-16s %-6s %-6s %-6s %s\n' "$n" "${a:-?}" \
      "$(ping -c1 -W2 "${a:-0.0.0.0}" >/dev/null 2>&1 && echo si || echo no)" \
      "$(nc -z -w2 "${a:-0.0.0.0}" 22 2>/dev/null && echo si || echo no)" \
      "$([ -n "$j" ] && echo si || echo no)" "$skew"
  done
  info "${C_DIM}Un desfase mayor a 2 s daña la medida del retraso. Arréglalo con  sudo timedatectl set-ntp true${C_OFF}"
  echo
  [ "$FAILS" -eq 0 ] && ok "Sin problemas en este equipo" || warn "$FAILS comprobación(es) fallaron en este equipo"
}

cmd_status() {
  need_root "$@"; load_config
  [ -f "$DERIVED" ] || die "Este equipo todavía no se configuró con setup.sh."
  printf '%-12s %-10s %-9s %-16s %-8s %s\n' NODO ROL RED IP RETRASO SERVICIOS
  local n j
  for n in $ALL_NODES; do
    j="$(agent_status "$n")"
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
  local pass=0 fail=0 out="$LAB_HOME/resultados-pruebas.txt" v lag t0 t1 f me others="" c n s primary
  : > "$out"
  res() { # res "nombre" estado "detalle"
    if [ "$2" = ok ]; then pass=$((pass + 1)); printf '     %s✔%s %-34s %s\n' "$C_OK" "$C_OFF" "$1" "$3"
    else fail=$((fail + 1)); printf '     %s✘%s %-34s %s\n' "$C_BAD" "$C_OFF" "$1" "$3"; fi
    printf '%s | %s | %s\n' "$1" "$2" "$3" >> "$out"
  }
  me="$NODE_NAME"
  step "Pruebas de punta a punta desde $me"
  mountpoint -q "$MOUNT_DIR" || die "La carpeta no está montada. Ejecuta primero: setup.sh cliente"
  for c in $CLIENTS; do
    [ "$c" = "$me" ] && continue
    if rsh "$c" "mountpoint -q $MOUNT_DIR" 2>/dev/null; then others="$others $c"
    else warn "$c no responde o no tiene la carpeta montada, queda fuera de las pruebas"; fi
  done
  n=$(( $(wc -w <<<"$others") + 1 ))

  f="$MOUNT_DIR/prueba-acceso-$$.txt"
  echo "hola desde $me" > "$f"
  for c in $others; do
    v="$(rsh "$c" cat "$f" 2>/dev/null || true)"
    [ "$v" = "hola desde $me" ] && res "Acceso compartido $c" ok "leyó el archivo creado en $me" || res "Acceso compartido $c" fail "no vio el archivo"
  done
  rm -f "$f"

  echo 0 > "$MOUNT_DIR/contador.txt"
  info "Sin bloqueo, $n clientes editan a la vez durante 8 segundos..."
  for c in $others; do rsh "$c" "$LIB_DIR/editar.sh $c" >/dev/null 2>&1 & done
  "$LIB_DIR/editar.sh" "$me" >/dev/null 2>&1
  wait; sleep 2
  v="$(cat "$MOUNT_DIR/contador.txt")"
  [ "$v" = "1" ] && res "Concurrencia sin bloqueo" ok "contador final $v de $n, se perdieron $((n - 1))" || res "Concurrencia sin bloqueo" fail "contador final $v, se esperaba 1"

  echo 0 > "$MOUNT_DIR/contador.txt"
  info "Con bloqueo flock, cada cliente espera su turno..."
  for c in $others; do rsh "$c" "$LIB_DIR/editar.sh $c --lock" >/dev/null 2>&1 & done
  sleep 0.5
  "$LIB_DIR/editar.sh" "$me" --lock >/dev/null 2>&1
  wait; sleep 2
  v="$(cat "$MOUNT_DIR/contador.txt")"
  [ "$v" = "$n" ] && res "Concurrencia con bloqueo flock" ok "contador final $v de $n, sin pérdida" || res "Concurrencia con bloqueo flock" fail "contador final $v, se esperaba $n"

  primary="$(current_primary || true)"
  f="replica-$$.txt"; t0="$(date +%s.%N)"
  echo "$t0" > "$MOUNT_DIR/$f"
  for s in $SERVERS; do
    [ "$s" = "$primary" ] && continue
    lag=""
    for _ in $(seq 1 60); do
      if rsh "$s" "test -f $EXPORT_DIR/$f" 2>/dev/null; then t1="$(date +%s.%N)"; lag="$(echo "$t1 - $t0" | bc -l | xargs printf '%.1f')"; break; fi
      sleep 0.3
    done
    [ -n "$lag" ] && res "Retraso de la réplica en $s" ok "${lag} s" || res "Retraso de la réplica en $s" fail "no llegó"
  done
  rm -f "$MOUNT_DIR/$f"

  echo; info "Primario actual: ${primary:-ninguno}. Resultados guardados en $out"
  printf '     %d pruebas correctas, %d fallidas\n' "$pass" "$fail"
  [ "$fail" -eq 0 ] || return 1
}

cmd_simulate_failure() {
  need_root "$@"; load_config
  is_primary_local || die "Este servidor no es el primario. Ejecútalo en el primario, mira  ./setup.sh status"
  step "Simulando la caída de $(hostname)"
  for s in sad-watchdog sad-replicator sad-app nfs-server sad-agent; do systemctl stop "$s" && ok "Detenido $s"; done
  log_event "caída simulada de $(hostname)"
  info "El siguiente servidor de la sucesión asumirá en unos segundos. Para volver, ejecuta ./setup.sh failback"
  if [ "${2:-}" = "--poweroff" ]; then info "Apagando el equipo"; systemctl poweroff; fi
}

cmd_demote() {
  need_root "$@"; load_config
  # shellcheck disable=SC1090
  . "$DERIVED"
  step "Devolviendo $NODE_NAME a réplica"
  systemctl disable --now sad-app 2>/dev/null || true
  rm -f "$STATE_DIR/primary"
  sed -i "\|^$EXPORT_DIR |s/(rw,/(ro,/" /etc/exports
  exportfs -ra
  sed -i 's/^NODE_ROLE=.*/NODE_ROLE=replica/' "$APP_DIR/.env"
  log_event "$NODE_NAME vuelve a ser réplica"
  ok "$NODE_NAME es réplica de nuevo"
}

cmd_failback() {
  need_root "$@"; load_config
  # shellcheck disable=SC1090
  . "$DERIVED"
  local p a tmp="/tmp/sad-primary.db"
  step "Failback, $NODE_NAME recupera el servicio"
  systemctl start nfs-server sad-agent 2>/dev/null || true
  p="$(current_primary || true)"
  if [ -n "$p" ] && [ "$p" != "$NODE_NAME" ]; then
    a="$(addr_of "$p")"
    peer_ssh_ok "$a" || die "No puedo conectar por SSH con $p."
    systemctl stop sad-replicator sad-app sad-watchdog 2>/dev/null || true
    info "Trayendo de $p lo escrito durante la caída..."
    rsh "$p" "$APP_DIR/.venv/bin/python - $APP_DIR/data/sad.db $tmp" <<'PY'
import sqlite3, sys
src = sqlite3.connect(sys.argv[1]); dst = sqlite3.connect(sys.argv[2]); src.backup(dst); dst.close(); src.close()
PY
    as_user scp $SSH_OPTS -q "$LAB_USER@$a:$tmp" "$tmp"
    as_user rsync -a --delete --exclude '.cluster/heartbeat*' --exclude '.cluster/sad.db*' -e "ssh $SSH_OPTS" "$LAB_USER@$a:$EXPORT_DIR/" "$EXPORT_DIR/"
    rm -f "$APP_DIR/data/sad.db" "$APP_DIR/data/sad.db-wal" "$APP_DIR/data/sad.db-shm"
    install -o "$LAB_USER" -g "$LAB_USER" -m 640 "$tmp" "$APP_DIR/data/sad.db"; rm -f "$tmp"
    ok "Archivos y base de datos copiados desde $p"
    rsh "$p" "sudo $APP_DIR/setup.sh demote" >/dev/null && ok "$p vuelve a ser réplica"
  elif [ "$p" = "$NODE_NAME" ]; then ok "$NODE_NAME ya es el primario"
  else warn "Ningún servidor responde como primario. $NODE_NAME asume con lo que tiene."; fi
  date +%s.%N > "$STATE_DIR/primary"
  sed -i "\|^$EXPORT_DIR |s/(ro,/(rw,/" /etc/exports
  exportfs -ra
  sed -i 's/^NODE_ROLE=.*/NODE_ROLE=primario/' "$APP_DIR/.env"
  systemctl enable sad-app >/dev/null 2>&1
  systemctl start nfs-server sad-app sad-replicator sad-agent sad-watchdog
  wait_for "sad-app responde" 25 curl -fsS "http://127.0.0.1:$APP_PORT/healthz" || true
  log_event "failback completado, $NODE_NAME es primario"
  FAILS=0; validate_server "$NODE_NAME"; finish
}

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

main() {
case "${1:-}" in
  servidor-*|cliente) cmd_install "$@" ;;
  doctor)            cmd_doctor "$@" ;;
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
