#!/usr/bin/env bash
# Demo de concurrencia. Ejecutar en AMBOS clientes casi al mismo tiempo:
#   ./editar.sh Cliente1            sin protección  -> actualización perdida
#   ./editar.sh Cliente1 --lock     con flock       -> el segundo espera
# Cada cliente lee un contador, espera 8 s (simula editar) y escribe contador+1.
# Con dos clientes el resultado correcto es 2.
set -euo pipefail
cd "$(dirname "$0")/.."
. ./lab.env

NOMBRE="${1:?Uso: $0 NombreCliente [--lock]}"
ARCHIVO="$MOUNT_DIR/contador.txt"
[[ -f "$ARCHIVO" ]] || echo 0 > "$ARCHIVO"

editar() {
  local valor; valor=$(cat "$ARCHIVO")
  echo "$(date +%T) $NOMBRE leyó el contador: $valor. Editando 8 s..."
  sleep 8
  echo $((valor + 1)) > "$ARCHIVO"
  echo "$(date +%T) $NOMBRE escribió: $((valor + 1))"
}

if [[ "${2:-}" == "--lock" ]]; then
  echo "$(date +%T) $NOMBRE pide el bloqueo..."
  exec 9>>"$ARCHIVO"
  flock 9
  echo "$(date +%T) $NOMBRE obtuvo el bloqueo"
  editar
  flock -u 9
else
  editar
fi
echo "Valor final visto por $NOMBRE: $(cat "$ARCHIVO")"
