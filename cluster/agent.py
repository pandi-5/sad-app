#!/usr/bin/env python3
"""Agente de estado de un nodo del laboratorio.

Solo usa la biblioteca estándar. Responde en el puerto 5100.

  GET /status           estado del nodo en JSON
  GET /probe?target=x   comprueba si este nodo alcanza a un objetivo vigilado
                        y lo informa. Lo usa el vigilante del servidor B como
                        testigo antes de promoverse.

Variables de entorno, tomadas de /etc/sad-lab/lab.conf mediante systemd:
  NODE_NAME, NODE_ROLE, EXPORT_DIR, MOUNT_DIR, AGENT_PORT,
  PROBE_TARGETS  ejemplo  a=100.64.0.11:5000,nfs=100.64.0.11:2049
"""
from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

NODE_NAME = os.environ.get("NODE_NAME") or socket.gethostname()
NODE_ROLE = os.environ.get("NODE_ROLE", "autonomo")
EXPORT_DIR = os.environ.get("EXPORT_DIR", "/srv/compartido")
MOUNT_DIR = os.environ.get("MOUNT_DIR", "/mnt/compartido")
EXPORTS_FILE = os.environ.get("EXPORTS_FILE", "/etc/exports")
PORT = int(os.environ.get("AGENT_PORT", "5100"))
SERVICES = ["nfs-server", "sad-app", "sad-replicator", "sad-watchdog", "sad-mount-watch"]
BOOT = time.time()


def run(cmd: list[str], timeout: float = 3) -> str:
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def service_states() -> dict:
    states = {}
    for name in SERVICES:
        state = run(["systemctl", "is-active", name])
        if state and state != "inactive":
            states[name] = state
        elif state == "inactive" and os.path.exists(f"/etc/systemd/system/{name}.service"):
            states[name] = state
    return states


def overlay() -> dict:
    """Dirección del rango 100.64.0.0/10 y si viene de Tailscale real o simulada."""
    mode = "ninguna"
    try:
        mode = open("/etc/sad-lab/overlay-mode").read().strip() or "ninguna"
    except OSError:
        pass
    ip = ""
    iface = ""
    for line in run(["ip", "-4", "-o", "addr", "show"]).splitlines():
        parts = line.split()
        if len(parts) >= 4:
            addr = parts[3].split("/")[0]
            octets = addr.split(".")
            if len(octets) == 4 and octets[0] == "100" and 64 <= int(octets[1]) <= 127:
                ip, iface = addr, parts[1]
                break
    return {"ip": ip, "interface": iface, "mode": mode}


def exports() -> list[str]:
    try:
        lines = open(EXPORTS_FILE).read().splitlines()
    except OSError:
        return []
    return [ln.strip() for ln in lines if ln.strip() and not ln.startswith("#")]


def effective_role() -> str:
    if NODE_ROLE not in ("servidor-a", "servidor-b"):
        return "cliente" if NODE_ROLE == "cliente" else NODE_ROLE
    if run(["systemctl", "is-active", "nfs-server"]) != "active":
        return "detenido"
    for line in exports():
        if line.split()[0] == EXPORT_DIR:
            if "(rw," in line or "(rw)" in line:
                return "primario"
            if "(ro," in line or "(ro)" in line:
                return "replica"
    return "sin-exportar"


def heartbeat() -> dict | None:
    path = os.path.join(EXPORT_DIR, ".cluster", "heartbeat")
    try:
        data = json.load(open(path))
        return {"ts": float(data["ts"]), "node": data.get("node", "")}
    except (OSError, ValueError, KeyError):
        return None


def mounts() -> list[dict]:
    found = []
    try:
        for line in open("/proc/mounts"):
            parts = line.split()
            if len(parts) >= 4 and parts[2] in ("nfs", "nfs4"):
                opts = parts[3].split(",")
                found.append({
                    "source": parts[0],
                    "target": parts[1],
                    "mode": "ro" if "ro" in opts else "rw",
                })
    except OSError:
        pass
    return found


def disk() -> dict | None:
    for path in (EXPORT_DIR, MOUNT_DIR):
        if os.path.isdir(path):
            try:
                total, used, free = shutil.disk_usage(path)
                return {"path": path, "total": total, "used": used, "free": free}
            except OSError:
                return None
    return None


def status() -> dict:
    hb = heartbeat()
    age = round(time.time() - hb["ts"], 1) if hb else None
    return {
        "node": NODE_NAME,
        "configured_role": NODE_ROLE,
        "effective_role": effective_role(),
        "host": socket.gethostname(),
        "time": time.time(),
        "uptime": round(time.time() - BOOT),
        "overlay": overlay(),
        "services": service_states(),
        "exports": exports(),
        "mounts": mounts(),
        "heartbeat_age": age,
        "heartbeat_from": hb["node"] if hb else None,
        "promoted": os.path.exists("/var/lib/sad-lab/promoted"),
        "disk": disk(),
    }


def probe(target: str) -> dict:
    """target se busca en PROBE_TARGETS, por ejemplo a=100.64.0.11:5000."""
    table = {}
    for chunk in os.environ.get("PROBE_TARGETS", "").split(","):
        if "=" in chunk:
            key, addr = chunk.split("=", 1)
            table[key.strip()] = addr.strip()
    addr = table.get(target)
    if not addr or ":" not in addr:
        return {"target": target, "known": False, "reachable": False}
    host, port = addr.rsplit(":", 1)
    try:
        with socket.create_connection((host, int(port)), timeout=2):
            return {"target": target, "known": True, "reachable": True, "by": NODE_NAME}
    except OSError:
        return {"target": target, "known": True, "reachable": False, "by": NODE_NAME}


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        url = urlparse(self.path)
        if url.path == "/status":
            self._send(200, status())
        elif url.path == "/probe":
            target = parse_qs(url.query).get("target", [""])[0]
            self._send(200, probe(target))
        elif url.path == "/health":
            self._send(200, {"status": "ok", "node": NODE_NAME})
        else:
            self._send(404, {"error": "no encontrado"})

    def log_message(self, fmt, *args) -> None:  # silencio en journald
        return


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"Agente de {NODE_NAME} escuchando en el puerto {PORT}", flush=True)
    server.serve_forever()
