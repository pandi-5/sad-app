#!/usr/bin/env bash
# Ejecutar en el servidor A. Crea un archivo y mide cuánto tarda en aparecer
# en B. Es la evidencia del retraso de la replicación asíncrona.
set -euo pipefail
cd "$(dirname "$0")/.."
. ./lab.env

NOMBRE="prueba-$(date +%s).txt"
echo "creado en A a las $(date +%T)" > "$EXPORT_DIR/$NOMBRE"
INICIO=$(date +%s.%N)
until ssh -o BatchMode=yes -o ConnectTimeout=3 "$USUARIO@$SERVIDOR_B" "test -f $EXPORT_DIR/$NOMBRE"; do
  sleep 0.2
done
FIN=$(date +%s.%N)
printf "El archivo %s llegó a B en %.1f segundos\n" "$NOMBRE" "$(echo "$FIN - $INICIO" | bc -l)"
