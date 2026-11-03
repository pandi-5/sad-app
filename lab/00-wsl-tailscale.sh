#!/usr/bin/env bash
# Ejecutar en CADA equipo, dentro de WSL (Ubuntu). Instala Tailscale en WSL
# para que WSL tenga su propia IP en la red Tailscale.
set -euo pipefail

if ! grep -q '^systemd *= *true' /etc/wsl.conf 2>/dev/null; then
  echo "Activando systemd en WSL..."
  printf '[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf >/dev/null
  echo
  echo "Cierra esta terminal y ejecuta en PowerShell:  wsl --shutdown"
  echo "Luego abre WSL de nuevo y vuelve a ejecutar este script."
  exit 0
fi

if ! command -v tailscale >/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi

sudo systemctl enable --now tailscaled
sudo tailscale up
echo
echo "IP de Tailscale de este equipo:"
tailscale ip -4
