#!/usr/bin/env bash
# Ejecutar en los clientes, dentro de WSL.
#   ./02-cliente.sh a      monta la carpeta desde el servidor A
#   ./02-cliente.sh b      monta la carpeta desde el servidor B
#   ./02-cliente.sh salir  desmonta
set -euo pipefail
cd "$(dirname "$0")"
. ./lab.env

ORIGEN="${1:-a}"
case "$ORIGEN" in
  a) HOST="$SERVIDOR_A" ;;
  b) HOST="$SERVIDOR_B" ;;
  salir) sudo umount -f -l "$MOUNT_DIR" 2>/dev/null || true; echo "Desmontado."; exit 0 ;;
  *) echo "Uso: $0 a|b|salir"; exit 1 ;;
esac

sudo apt-get install -y -qq nfs-common
sudo mkdir -p "$MOUNT_DIR"
sudo umount -f -l "$MOUNT_DIR" 2>/dev/null || true

# soft + timeo corto: si el servidor cae, las operaciones fallan en segundos
# en lugar de quedarse colgadas para siempre.
sudo mount -t nfs4 -o soft,timeo=30,retrans=2 "$HOST:$EXPORT_DIR" "$MOUNT_DIR"
echo "Montado $HOST:$EXPORT_DIR en $MOUNT_DIR"
mount | grep " $MOUNT_DIR "
