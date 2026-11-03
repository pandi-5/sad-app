"""Vista y API del clúster: estado de cada nodo, réplica y servicio.

Cada nodo del laboratorio ejecuta un agente de estado (cluster/agent.py) que
responde en el puerto 5100. Esta aplicación consulta esos agentes en paralelo
y resume el estado del conjunto. Si no hay nodos configurados funciona igual
y muestra solo el nodo local.
"""
from __future__ import annotations

import json
import socket
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

from flask import Blueprint, current_app, jsonify, render_template

from .db import get_db, get_mode
from .security import login_required

bp = Blueprint("cluster", __name__)


def _fetch_node(node: dict, timeout: float) -> dict:
    """Consulta el agente de un nodo. Nunca lanza excepciones."""
    started = time.monotonic()
    result = {
        "name": node["name"],
        "url": node["url"],
        "up": False,
        "latency_ms": None,
        "status": None,
        "error": None,
    }
    try:
        with urllib.request.urlopen(node["url"] + "/status", timeout=timeout) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        result.update(up=True, status=data)
    except (urllib.error.URLError, socket.timeout, TimeoutError, ValueError, OSError) as exc:
        reason = getattr(exc, "reason", exc)
        result["error"] = str(reason)[:120]
    result["latency_ms"] = round((time.monotonic() - started) * 1000)
    return result


def fetch_nodes(nodes: list[dict], timeout: float) -> list[dict]:
    if not nodes:
        return []
    with ThreadPoolExecutor(max_workers=min(8, len(nodes))) as pool:
        return list(pool.map(lambda n: _fetch_node(n, timeout), nodes))


def summarize(nodes: list[dict]) -> dict:
    """Resume el estado global a partir de lo que informan los agentes."""
    total = len(nodes)
    up = sum(1 for n in nodes if n["up"])
    primary = None
    lag = None
    for n in nodes:
        st = n.get("status") or {}
        role = st.get("effective_role")
        if role == "primario" and st.get("services", {}).get("nfs-server") == "active":
            primary = n["name"]
        if role == "replica" and st.get("heartbeat_age") is not None:
            lag = st["heartbeat_age"]
    if total == 0:
        state = "local"
    elif primary and up == total:
        state = "ok"
    elif primary:
        state = "degradado"
    else:
        state = "caido"
    return {
        "state": state,
        "primary": primary,
        "replica_lag": lag,
        "nodes_up": up,
        "nodes_total": total,
    }


def local_info() -> dict:
    cfg = current_app.config
    db = get_db()
    now = time.time()
    online = db.execute(
        "SELECT COUNT(*) AS n FROM users WHERE seen > ?",
        (now - cfg["ONLINE_WINDOW"],),
    ).fetchone()["n"]
    files = db.execute("SELECT COUNT(*) AS n FROM files").fetchone()["n"]
    return {
        "name": cfg["NODE_NAME"],
        "role": cfg["NODE_ROLE"],
        "host": socket.gethostname(),
        "time": now,
        "mode": get_mode(),
        "files": files,
        "users_online": online,
    }


def snapshot() -> dict:
    cfg = current_app.config
    nodes = fetch_nodes(cfg["CLUSTER_NODES"], cfg["CLUSTER_TIMEOUT"])
    return {
        "node": local_info(),
        "nodes": nodes,
        "summary": summarize(nodes),
    }


@bp.get("/cluster")
@login_required
def page():
    return render_template("cluster/index.html", snap=snapshot())


@bp.get("/cluster/fragment")
@login_required
def fragment():
    return render_template("cluster/_nodes.html", snap=snapshot())


@bp.get("/api/cluster")
@login_required
def api():
    return jsonify(snapshot())
