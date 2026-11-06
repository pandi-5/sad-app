# Archivos compartidos (SAD)

Aplicación web para compartir archivos dentro de un equipo pequeño. Incluye
cuentas con contraseña, permisos por operación, edición de archivos de texto,
historial de versiones nativo y tres modos de concurrencia.

El servidor está escrito con Flask y SQLite, sin servicios externos, CDN ni paso
de compilación en el frontend.

## Características

- Registro abierto de usuarios. Las cuentas nuevas nacen en **solo lectura**.
- El coordinador administra usuarios, permisos, modo de concurrencia y auditoría.
- Subida múltiple, descarga y vista previa de imágenes.
- Edición web de archivos UTF-8 con detección de conflictos y borrador local.
- Historial de versiones con restauración, sin Git ni repositorios externos.
- Modos de concurrencia: `libre`, `versiones` y `bloqueo`.
- Bloqueos con caducidad y renovación por latido desde el editor.
- Sesiones con CSRF, revocación por cambio de contraseña, límite de intentos de
  acceso y cabeceras de seguridad.
- Interfaz adaptable, tema claro/oscuro y sin dependencias de frontend.
- Docker con usuario sin privilegios y *healthcheck*.

## Inicio rápido con Docker

Requisitos: Docker y Docker Compose.

```bash
cp .env.example .env
```

Edita `.env` y define al menos:

- `SECRET`: cadena aleatoria de 32 bytes en hexadecimal.
- `ADMIN_PASS` o, preferiblemente, `ADMIN_PASS_HASH`.

Genera un secreto:

```bash
python3 -c "import secrets; print(secrets.token_hex(32))"
```

Genera el hash de la contraseña del coordinador:

```bash
docker compose run --rm sad \
  python -c "from werkzeug.security import generate_password_hash as g; print(g('TU-CONTRASEÑA-FUERTE'))"
```

Copia el valor resultante en `ADMIN_PASS_HASH` y elimina `ADMIN_PASS` del
archivo. Después:

```bash
docker compose up -d --build
```

La aplicación queda en <http://localhost:5000>. El *healthcheck* está en
`/healthz`.

El contenedor se ejecuta como UID/GID `1000:1000`. Si los directorios `data/` y
`storage/` pertenecen a otro usuario del host, ajusta `user:` en
`docker-compose.yml` o los permisos de esos directorios.

## Acceso del coordinador

El coordinador no se guarda en la tabla `users`; sus credenciales se leen de
`.env` al arrancar.

- Usuario: valor de `ADMIN_USER` (por defecto `coordinador`).
- Contraseña: `ADMIN_PASS` o la contraseña cuyo hash esté en `ADMIN_PASS_HASH`.

El coordinador entra directamente al panel, pero también puede usar el espacio
de archivos con todos los permisos.

> `.env` contiene secretos y está excluido por `.gitignore`. No lo publiques ni
> lo incluyas en imágenes o copias compartidas.

## Variables de entorno

| Variable | Por defecto | Descripción |
| --- | --- | --- |
| `SECRET` | — | Clave de firma de sesiones. Obligatoria, mínimo 24 caracteres. |
| `ADMIN_USER` | `coordinador` | Nombre del coordinador. |
| `ADMIN_PASS` | — | Contraseña del coordinador en claro. Se hashea al arrancar. |
| `ADMIN_PASS_HASH` | — | Hash de la contraseña del coordinador. Tiene prioridad. |
| `COOKIE_SECURE` | `0` | `1` cuando se sirve por HTTPS. |
| `MAX_UPLOAD_MB` | `25` | Tamaño máximo por archivo subido. |
| `MAX_TEXT_KB` | `512` | Tamaño máximo para editar un archivo como texto. |
| `MAX_VERSIONS` | `10` | Versiones conservadas por archivo (incluida la actual). |
| `LOCK_TTL` | `90` | Segundos de validez de un bloqueo sin latido. |
| `ONLINE_WINDOW` | `30` | Segundos para considerar a un usuario conectado. |
| `SESSION_LIFETIME_H` | `8` | Duración de la sesión en horas. |
| `MAX_FILES_PER_UPLOAD` | `20` | Archivos por envío. |
| `LOGIN_MAX_ATTEMPTS` | `5` | Intentos fallidos antes de esperar. |
| `LOGIN_WINDOW` | `900` | Ventana de bloqueo de intentos, en segundos. |
| `PASSWORD_MIN_LENGTH` | `8` | Longitud mínima de contraseña de clientes. |
| `DB_PATH` | `data/sad.db` | Ruta de SQLite. En Docker: `/app/data/sad.db`. |
| `STORAGE_DIR` | `storage` | Directorio de archivos. En Docker: `/app/storage`. |
| `ALLOW_INSECURE_DEFAULTS` | `0` | Solo para desarrollo. No usar en producción. |

La aplicación se niega a arrancar si detecta un secreto débil, falta la
contraseña del coordinador o se usa la contraseña histórica `admin123`, salvo
que `ALLOW_INSECURE_DEFAULTS=1`.

## Uso

### Usuarios y permisos

1. Un usuario se registra desde la pantalla de acceso.
2. Nace con permiso de lectura (`r`) y sin escritura ni borrado.
3. El coordinador concede `w` (subir, editar, reemplazar, renombrar, reservar)
   y `d` (borrar) desde **Panel → Usuarios**.
4. Al retirar `w`, también se liberan los bloqueos que tuviera ese usuario.

### Modos de concurrencia

Se cambian desde **Panel → Modo** y afectan a toda la aplicación.

| Modo | Comportamiento |
| --- | --- |
| `libre` | Gana el último guardado. Si se pisa una versión ajena se registra `SOBRESCRITURA` en la auditoría. |
| `versiones` | Control optimista. Se compara la versión abierta con la actual; si cambió, se muestra un conflicto con el texto local y el del servidor. |
| `bloqueo` | Control pesimista. Al reservar, solo el dueño del bloqueo puede guardar o reemplazar. El bloqueo caduca a los `LOCK_TTL` segundos y el editor lo renueva. |

En `versiones`, ante un conflicto puedes guardar tu texto sobre la versión actual
o conservarlo como una copia nueva. En `bloqueo`, el coordinador puede liberar
un bloqueo desde el panel.

### Archivos y versiones

- Los archivos se guardan con un nombre UUID interno; el nombre original solo es
  para mostrar y descargar.
- Se consideran editables los archivos que caben en `MAX_TEXT_KB` y son UTF-8
  válido. Los demás se descargan o se previsualizan si son imágenes.
- Cada guardado, reemplazo o restauración crea una versión nueva.
- Las instantáneas viven en `storage/versions/<id>/<versión>.bin`.
- Se conservan las `MAX_VERSIONS` más recientes. Las anteriores se eliminan del
  historial y del disco.
- Restaurar una versión antigua no la mueve: crea una versión nueva con ese
  contenido.

### Auditoría

El panel muestra las operaciones recientes (`LOGIN`, `WRITE`, `SOBRESCRITURA`,
`CONFLICTO`, `LOCK`, `DELETE`, cambios de permisos, etc.). El registro se guarda
en la tabla `log` de SQLite.

## Estructura

```text
app/
  __init__.py        fábrica de Flask, filtros y contexto
  config.py          configuración por entorno y validaciones
  db.py              esquema SQLite, WAL y transacciones
  security.py        sesión, CSRF, permisos, límites y cabeceras
  auth.py            registro, acceso, salida y contraseña
  files.py           subida, descarga, edición, bloqueos y versiones
  admin.py           panel del coordinador
  utils.py           nombres, hashes, texto, instantáneas y diffs
  audit.py           registro de auditoría
  cluster.py         página y API del estado del clúster
templates/           Jinja: acceso, archivos, editor, panel y errores
static/              CSS, JavaScript e iconos locales
tests/               suite de pytest
data/                SQLite (se crea al arrancar)
storage/files/       archivos actuales
storage/versions/    instantáneas de versiones
storage/tmp/         temporales de subida y respaldo
cluster/agent.py     agente de estado de cada nodo
deploy/              plantilla de configuración y scripts de Windows
setup.sh             despliegue único por rol
wsgi.py              entrada para gunicorn
run.py               servidor de desarrollo
```

## Laboratorio distribuido con réplica

Además de la web, el repositorio incluye un despliegue de siete nodos para estudiar
sistemas de archivos distribuidos: cuatro servidores y tres clientes unidos por Tailscale.
Se instala con un solo script, `setup.sh`.

```text
                          red privada Tailscale 100.64.0.0/10
  cliente-1 (WSL) ─┐  etcd ─ Raft ─ etcd ─ Raft ─ etcd   ┌─ servidor-a ┐
  cliente-2 (WSL) ─┼─ escriben en el primario ───────────┼─ servidor-b ├─ uno es el primario
  cliente-3 (WSL) ─┘  leen de la réplica más cercana ────┼─ servidor-c │  los demás, réplicas
                                                         └─ servidor-d ┘
           el primario copia a las réplicas apenas cambia un archivo, con latido y base de datos
```

| Rol | Dónde corre | Qué hace |
| --- | --- | --- |
| `servidor-a` a `servidor-d` | VM de VirtualBox con Ubuntu Server | Exportan `/srv/compartido` por NFS. El primario lo exporta con escritura, ejecuta `sad-app` y replica hacia los demás. Las réplicas lo exportan en solo lectura y atienden lecturas. |
| `cliente 1` a `cliente 3` | WSL en el computador de cada integrante | Forman el clúster etcd. Montan `/mnt/compartido` con escritura desde el primario y `/mnt/lectura` en solo lectura desde la réplica más cercana. |

Los servidores van en máquinas virtuales porque el kernel de WSL no trae el servidor NFS.
Los clientes sí pueden ir en WSL.

### Consenso, contrato y fencing

Quién es el primario lo decide etcd, que replica sus datos con el algoritmo de consenso
Raft entre los tres clientes. Mientras dos de los tres respondan, etcd funciona.

1. **Elección.** Cada servidor ejecuta `sad-elector` (`cluster/elector.py`). El primario es
   quien logra crear la llave `/sad-lab/primario` en etcd. La creación es atómica, así que
   solo uno puede ganar.
2. **Contrato.** La llave vive atada a un contrato (lease) de `LEASE_TTL` segundos que el
   primario renueva cada segundo. Si el primario se cae, deja de renovar, el contrato vence
   y otro servidor asume.
3. **Fencing.** Si el primario queda aislado de la mayoría de etcd, no puede renovar. A un
   tercio del plazo se pone solo en solo lectura, antes de que el contrato venza y otro
   pueda asumir. Así nunca hay dos servidores aceptando escrituras.
4. **Época.** La revisión de etcd en que se creó la llave es la época del primario. Siempre
   crece, viaja en el latido de la réplica y sirve como ficha de fencing.
5. **Datos al día.** Solo se postula el último primario o una réplica cuyo latido trae la
   época del último primario. Un servidor que estuvo caído no vuelve a mandar con datos viejos.
6. **Sucesión.** El último primario va primero y después el orden de `SERVERS`. Cada servidor
   espera `RANK_DELAY` segundos por cada puesto que tiene delante.

Si se apagan dos de los tres clientes, etcd pierde la mayoría, nadie puede ser primario y
la carpeta queda en solo lectura. Es la decisión del teorema CAP: ante una partición, el
sistema prefiere consistencia antes que aceptar escrituras que podrían perderse.

### Réplica y lecturas

El replicador ya no espera un intervalo fijo. `inotify` lo despierta apenas cambia un
archivo y copia con `rsync` a las tres réplicas en paralelo, así el retraso queda por debajo
de un segundo. La réplica sigue siendo asíncrona: el primario no espera a que las réplicas
confirmen.

Cada cliente monta además `/mnt/lectura` en solo lectura desde la réplica con menor latencia.
Las lecturas se reparten entre las réplicas y el primario atiende las escrituras.

### Uso

Todos los nodos deben tener el mismo `deploy/lab.conf`. Créalo a partir de
`deploy/lab.conf.example` y llena `TS_AUTHKEY` con una llave reutilizable de Tailscale y
`SSH_PASSWORD` con una clave para el usuario común `sadlab`.

```bash
# primero los clientes, que forman etcd. Con dos ya hay mayoría.
sudo ./setup.sh cliente 1
sudo ./setup.sh cliente 2
sudo ./setup.sh cliente 3
# después los servidores, primero servidor-a
sudo ./setup.sh servidor-a
sudo ./setup.sh servidor-b
sudo ./setup.sh servidor-c
sudo ./setup.sh servidor-d
```

Ejecútalo una segunda vez en cada nodo cuando todos estén listos, para cerrar las llaves
SSH pendientes. El script se puede repetir sin dañar nada. Al terminar valida el nodo y
muestra una marca por cada comprobación.

| Comando | Para qué sirve |
| --- | --- |
| `./setup.sh doctor` | Diagnóstico de este equipo, estado de etcd y tabla de los siete nodos con ping, SSH, agente y desfase del reloj. |
| `./setup.sh status` | Primario, época, miembros de etcd y estado de los siete nodos. |
| `./setup.sh test` | Desde un cliente. Acceso compartido, concurrencia de los tres clientes con y sin bloqueo, retraso hacia cada réplica y lectura desde la réplica. |
| `./setup.sh simulate-failure` | En el primario. Lo detiene sin soltar el contrato y otro servidor asume. |
| `./setup.sh failback` | En el servidor que debe volver a ser primario. Reserva el puesto en etcd, pide al primario actual que ceda, trae sus datos y gana la elección. |
| `python3 /opt/sad-app/cluster/elector.py status` | Primario, época, reserva, miembros de etcd y líder de Raft. |

La configuración queda en `/etc/sad-lab/lab.conf` y el proyecto en `/opt/sad-app` en
todos los nodos.

### Despliegue distribuido entre los cuatro integrantes

Cada integrante pone una VM servidora en su computador, y tres de ellos además un cliente
en WSL. Todos los nodos se unen a la misma red de Tailscale con la misma llave, así que se
ven entre sí aunque estén en casas distintas.

| Integrante | VM de VirtualBox | WSL |
| --- | --- | --- |
| 1 | `servidor-a` | `cliente-1` |
| 2 | `servidor-b` | `cliente-2` |
| 3 | `servidor-c` | `cliente-3` |
| 4 | `servidor-d` | — |

Cada uno, en su computador:

1. Clona el repo fuera de OneDrive y pone el mismo `deploy\lab.conf` que los demás.
2. Si tiene cliente, ejecuta `deploy\windows\cliente-wsl.cmd` con su número.
3. Ejecuta `deploy\windows\servidor-vm.cmd` con su letra. Crea la VM, si hace falta, y la instala.
4. Cuando todos estén unidos, repite los dos scripts una vez para cerrar las llaves SSH.

Los clientes van primero porque forman etcd. Las capturas del escenario se toman desde el
computador que tiene `servidor-a`. Con otra VM, antes de correrlo: `set SAD_PROPIO=servidor-x`.

### Lo que no se hizo y por qué

La réplica síncrona por bloques con DRBD no se incluyó. Necesita un disco virtual extra en
cada VM, un módulo del kernel y DRBD 9 para más de dos nodos, y reemplaza por completo el
modelo de carpeta replicada con rsync. Con el replicador por inotify el retraso ya es menor
a un segundo, y la pérdida posible ante una caída queda en ese margen.

### Problemas de la primera prueba con Tailscale real y cómo quedaron resueltos

| Problema | Solución en `setup.sh` |
| --- | --- |
| La validación buscaba la IP simulada `100.64.0.11` y fallaba aunque Tailscale funcionara. | En modo real comprueba la IP que asigna Tailscale. |
| MagicDNS no resolvía dentro de WSL y los nodos no se encontraban por nombre. | `tailscale up --accept-dns=false` y el servicio `sad-hosts` escribe en `/etc/hosts` la IP de cada nodo cada 30 s. |
| Tailscale renombraba a `servidor-a-1` si ya existía una máquina vieja con ese nombre. | Los nodos se buscan por su nombre de equipo, no por el de MagicDNS, y el script avisa que borres la máquina vieja. |
| Cada integrante tenía un usuario Linux distinto y fallaban SSH, rsync y el failback. | Usuario común `sadlab` en todos los nodos. |
| El proyecto estaba en el home de cada uno y el failback llamaba rutas que no existían en el otro equipo. | El proyecto se instala siempre en `/opt/sad-app`. |
| Ubuntu Server trae `PasswordAuthentication no` y `ssh-copy-id` nunca copiaba las llaves. | Se habilita la clave para el primer intercambio de llaves. |
| WSL sin systemd no podía arrancar tailscaled ni los servicios. | El script activa systemd en `/etc/wsl.conf` y pide reiniciar WSL. |
| El nombre del equipo en WSL se perdía al reiniciar. | Se fija en `/etc/wsl.conf`. |
| El servidor NFS no arrancaba en WSL. | Los servidores van en VM. `setup.sh` lo detecta y lo explica antes de empezar. |
| WSL se apagaba al cerrar la ventana y el testigo desaparecía. | `cliente-wsl.cmd` fija `vmIdleTimeout=-1` y deja WSL encendido. |
| Archivos editados en Windows con CRLF rompían `setup.sh` y `lab.conf`. | `.gitattributes` fuerza LF, los scripts de Windows convierten al copiar y `setup.sh` limpia `lab.conf`. |
| Relojes desfasados daban retrasos de réplica negativos o enormes. | Se activa NTP y `doctor` muestra el desfase de cada nodo. |
| Una réplica podía asumir antes de que el primario existiera. | Una réplica nunca asume si no ha recibido ni un latido. |
| La decisión de quién manda la tomaba un script propio con testigos. | La toma etcd con Raft, con contrato y fencing. |

### Red privada, real o simulada

`OVERLAY_MODE=real` instala Tailscale y une el nodo a la red. `OVERLAY_MODE=sim` crea la
interfaz `tssim0` con direcciones del rango 100.64.0.0/10 y rutas hacia los demás nodos.
Sirve cuando todas las máquinas virtuales comparten un solo equipo físico. Es una simulación
y no debe presentarse como Tailscale real. `OVERLAY_MODE=none` usa las direcciones LAN.

### Scripts de Windows

| Script | Para qué sirve |
| --- | --- |
| `deploy/windows/servidor-vm.cmd` | En el computador de cada integrante. Crea su VM servidora y la instala. |
| `deploy/windows/2-crear-vms.cmd` | Crea las cuatro VM servidoras en VirtualBox con Ubuntu Server de forma desatendida, 1,5 GB de RAM cada una. |
| `deploy/windows/3-desplegar.cmd` | Copia el proyecto y `deploy/lab.conf` a los servidores y ejecuta `setup.sh` en cada uno. |
| `deploy/windows/cliente-wsl.cmd` | En el computador de cada integrante. Deja WSL encendido e instala el cliente dentro de WSL. |
| `deploy/windows/4-escenario.cmd` | Recorre el escenario completo con capturas: normal con etcd y montajes, caída de A, caída de B, failback. |

### Vista de clúster en la web

La web incluye la página `/cluster` y la API `/api/cluster`. Muestran el rol de cada servidor,
el retraso de la réplica y los servicios activos, y avisan en pantalla cuando el servidor actual
deja de responder. Cada nodo ejecuta un agente de estado, `cluster/agent.py`, en el puerto 5100.

## Desarrollo

Con Python 3.12 o superior:

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt -r requirements-dev.txt
cp .env.example .env
# edita .env
python run.py
```

El servidor de desarrollo escucha en `0.0.0.0:5000` sin modo depuración.

### Pruebas

Con el entorno virtual activo:

```bash
python -m pytest -q
```

O dentro de Docker, sin instalar nada en el host:

```bash
docker build --target test -t sad-test .
docker run --rm -v "$PWD":/app -w /app sad-test python -m pytest -q
```

La suite cubre autenticación, permisos, CSRF, subida y descarga, detección de
texto, versiones, conflictos, bloqueos y panel del coordinador.

## Copias de seguridad

Copia siempre **juntos** `data/` y `storage/`; la base de datos referencia
nombres internos que viven en `storage/`.

Con la aplicación detenida:

```bash
docker compose stop
tar -czf sad-backup-$(date +%F).tar.gz data storage .env
docker compose start
```

Para restaurar, detén la aplicación, reemplaza `data/`, `storage/` y `.env`, y
vuelve a arrancar. Si el esquema de la base es anterior al actual, la aplicación
crea una copia `data/sad.db.bak-*` y arranca con una base limpia; conserva esa
copia por si necesitas migrar datos manualmente.

## Seguridad y limitaciones

- Sirve la aplicación detrás de un proxy con HTTPS y activa `COOKIE_SECURE=1`.
  No expongas el puerto 5000 directamente a Internet.
- Usa `ADMIN_PASS_HASH` en producción y protege `.env` con permisos restringidos.
- El límite de intentos de acceso se guarda en SQLite y es por IP + usuario. Un
  proxy inverso con límite de peticiones añade otra capa.
- No hay recuperación de contraseña por correo. El coordinador puede generar una
  contraseña temporal desde el panel.
- No hay análisis antivirus. Los archivos se sirven como descarga y las imágenes
  se previsualizan con `Content-Type` controlado y `nosniff`.
- SQLite y los bloqueos están pensados para un servidor pequeño. El
  `Dockerfile` usa un solo proceso de gunicorn con varios hilos para reducir
  contención de escritura. Para más carga, considera migrar a PostgreSQL y
  almacenamiento de objetos.
- No se incluye integración con Git/GitHub. El historial se basa en instantáneas
  nativas.
- La aplicación no cifra los archivos en reposo; usa el cifrado de disco del
  servidor si lo necesitas.
