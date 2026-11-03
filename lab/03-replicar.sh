#!/usr/bin/env bash
# Ejecutar en el servidor A. Copia la carpeta compartida al servidor B cada
# INTERVALO_REPLICA segundos. Es replicación ASÍNCRONA: B puede ir con retraso.
# Requisito una sola vez:  ssh-keygen  y  ssh-copy-id $USUARIO@$SERVIDOR_B
set -euo pipefail
cd "$(dirname "$0")"
. ./lab.env

command -v rsync >/dev/null || sudo apt-get install -y -qq rsync
echo "Replicando $EXPORT_DIR de A hacia $SERVIDOR_B cada ${INTERVALO_REPLICA}s. Ctrl+C para parar."
while true; do
  if rsync -a --delete -e "ssh -o ConnectTimeout=3 -o BatchMode=yes" \
       "$EXPORT_DIR/" "$USUARIO@$SERVIDOR_B:$EXPORT_DIR/" 2>/tmp/replica.err; then
    echo "$(date +%T) réplica al día"
  else
    echo "$(date +%T) B no responde: $(head -1 /tmp/replica.err)"
  fi
  sleep "$INTERVALO_REPLICA"
done
