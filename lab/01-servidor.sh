#!/usr/bin/env bash
# Ejecutar en los DOS servidores, dentro de WSL.
#   ./01-servidor.sh primario    en el servidor A (lectura y escritura)
#   ./01-servidor.sh replica     en el servidor B (solo lectura hasta promoverlo)
set -euo pipefail
cd "$(dirname "$0")"
. ./lab.env

ROL="${1:-}"
[[ "$ROL" == "primario" || "$ROL" == "replica" ]] || { echo "Uso: $0 primario|replica"; exit 1; }

sudo apt-get update -qq
sudo apt-get install -y -qq nfs-kernel-server rsync openssh-server

sudo mkdir -p "$EXPORT_DIR"
sudo chown "$(id -u):$(id -g)" "$EXPORT_DIR"
sudo chmod 775 "$EXPORT_DIR"

if [[ "$ROL" == "primario" ]]; then OPC="rw"; else OPC="ro"; fi

# Solo la red de Tailscale (100.64.0.0/10) puede montar la carpeta.
# all_squash hace que todos los clientes escriban como el mismo usuario.
LINEA="$EXPORT_DIR 100.64.0.0/10($OPC,sync,no_subtree_check,all_squash,anonuid=$(id -u),anongid=$(id -g))"
sudo sed -i "\|^$EXPORT_DIR |d" /etc/exports
echo "$LINEA" | sudo tee -a /etc/exports >/dev/null

sudo modprobe nfsd 2>/dev/null || true
if ! grep -qw nfsd /proc/filesystems; then
  echo
  echo "ERROR: este kernel de WSL no trae el servidor NFS (nfsd)."
  echo "Alternativas: actualizar el kernel con 'wsl --update', o usar SSHFS"
  echo "(ver README, sección Plan B)."
  exit 2
fi

sudo systemctl enable --now ssh
sudo systemctl restart nfs-kernel-server
sudo exportfs -ra
echo
echo "Servidor $ROL listo. Exportación activa:"
sudo exportfs -v
