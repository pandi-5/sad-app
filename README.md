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

Además de la web, el repositorio incluye un despliegue de cuatro nodos para estudiar
sistemas de archivos distribuidos. Se instala con un solo script, `setup.sh`.

```text
  cliente-1 ─┐                              ┌─ servidor-a  primario, NFS lectura y escritura, sad-app
             ├─ red privada 100.64.0.0/10 ──┤        │ rsync cada 2 s, latido y base de datos
  cliente-2 ─┘                              └─ servidor-b  réplica, NFS solo lectura, vigilante
```

| Rol | Qué hace |
| --- | --- |
| `servidor-a` | Exporta `/srv/compartido` por NFS, ejecuta `sad-app` con su almacenamiento en la carpeta compartida y replica hacia B. |
| `servidor-b` | Recibe la réplica. Su vigilante promueve a B si A cae y los testigos, los clientes, confirman la caída. |
| `cliente` | Monta la carpeta desde el servidor que esté vivo y vuelve a montar solo si cambia el primario. |

### Uso

```bash
git clone https://github.com/pandi-5/sad-app ~/sad-app && cd ~/sad-app
sudo ./setup.sh servidor-a      # en la máquina A
sudo ./setup.sh servidor-b      # en la máquina B
sudo ./setup.sh cliente 1       # en el cliente 1
sudo ./setup.sh cliente 2       # en el cliente 2
```

Ejecútalo una segunda vez en cada máquina cuando las demás estén listas, para cerrar
las llaves SSH pendientes. El script se puede repetir sin dañar nada. Al terminar valida
el nodo y muestra una marca por cada comprobación.

| Comando | Para qué sirve |
| --- | --- |
| `./setup.sh status` | Rol, red, retraso y servicios de los cuatro nodos. |
| `./setup.sh test` | Desde un cliente. Acceso compartido, concurrencia con y sin bloqueo, y retraso de la réplica. |
| `./setup.sh simulate-failure` | En A. Detiene NFS, la web y el replicador. B se promueve solo. |
| `./setup.sh failback` | En A. Trae lo escrito en B, devuelve B a réplica y retoma el servicio. |

La configuración está en `/etc/sad-lab/lab.conf`, plantilla en `deploy/lab.conf.example`.

### Red privada, real o simulada

`OVERLAY_MODE=real` instala Tailscale y une el nodo a la red. `OVERLAY_MODE=sim` crea la
interfaz `tssim0` con direcciones del rango 100.64.0.0/10 y rutas hacia los demás nodos.
Sirve cuando las máquinas virtuales comparten un solo equipo físico. Es una simulación
y no debe presentarse como Tailscale real. `OVERLAY_MODE=none` usa las direcciones LAN.

### Máquinas virtuales en Windows

`deploy/windows/crear-vms.ps1` crea las cuatro VM en VirtualBox con Ubuntu Server de forma
desatendida, y `deploy/windows/desplegar.ps1` copia el proyecto y ejecuta `setup.sh` en cada una.

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
