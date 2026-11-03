#!/usr/bin/env bash
# Ejecutar en el servidor B cuando A haya caído: B pasa de solo lectura a
# lectura y escritura. Después los clientes montan con  ./02-cliente.sh b
set -euo pipefail
cd "$(dirname "$0")"
. ./lab.env

sudo sed -i "\|^$EXPORT_DIR |s/(ro,/(rw,/" /etc/exports
sudo exportfs -ra
echo "B promovido a primario:"
sudo exportfs -v
