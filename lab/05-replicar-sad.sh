#!/usr/bin/env bash
# Opcional. Ejecutar en el servidor A junto a sad-app. Copia la base de datos y
# los archivos de sad-app al servidor B. La base se copia con la API de backup
# de SQLite, porque copiar el archivo en caliente puede dejarlo corrupto.
# Uso:  ./05-replicar-sad.sh /ruta/a/sad-app
set -euo pipefail
cd "$(dirname "$0")"
. ./lab.env

APP="${1:?Uso: $0 /ruta/a/sad-app}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

while true; do
  python3 -I - "$APP/data/sad.db" "$TMP/sad.db" <<'PY'
import sqlite3, sys
src = sqlite3.connect(sys.argv[1]); dst = sqlite3.connect(sys.argv[2])
src.backup(dst); dst.close(); src.close()
PY
  rsync -a "$TMP/sad.db" "$USUARIO@$SERVIDOR_B:$APP/data/sad.db" \
    && rsync -a --delete "$APP/storage/" "$USUARIO@$SERVIDOR_B:$APP/storage/" \
    && echo "$(date +%T) sad-app replicado" \
    || echo "$(date +%T) B no responde"
  sleep "$INTERVALO_REPLICA"
done
