from __future__ import annotations

import importlib.util
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest

from conftest import admin_login, make_user

ROOT = Path(__file__).resolve().parents[1]


def load_agent(monkeypatch, tmp_path, role="servidor-a", exports=""):
    exports_file = tmp_path / "exports"
    exports_file.write_text(exports)
    monkeypatch.setenv("NODE_NAME", "nodo-prueba")
    monkeypatch.setenv("NODE_ROLE", role)
    monkeypatch.setenv("EXPORT_DIR", str(tmp_path / "share"))
    monkeypatch.setenv("EXPORTS_FILE", str(exports_file))
    spec = importlib.util.spec_from_file_location("sad_agent", ROOT / "cluster" / "agent.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeAgent(BaseHTTPRequestHandler):
    payload: dict = {}

    def do_GET(self):  # noqa: N802
        body = json.dumps(self.payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        return


def serve(payload):
    handler = type("H", (FakeAgent,), {"payload": payload})
    server = HTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_address[1]}"


def status_payload(role, lag=None, nfs="active"):
    return {
        "node": "x",
        "effective_role": role,
        "overlay": {"ip": "100.64.0.11", "interface": "tssim0", "mode": "sim"},
        "services": {"nfs-server": nfs, "sad-app": "active"},
        "exports": ["/srv/compartido 100.64.0.0/10(rw,sync)"],
        "mounts": [],
        "heartbeat_age": lag,
        "promoted": False,
    }


def test_cluster_requires_login(app):
    client = app.test_client()
    assert client.get("/cluster").status_code == 302
    assert client.get("/api/cluster").status_code == 302


def test_cluster_standalone_shows_local_node(app):
    client = make_user(app, "alice")
    data = client.get("/api/cluster").get_json()
    assert data["nodes"] == []
    assert data["summary"]["state"] == "local"
    assert data["node"]["mode"] == "libre"
    page = client.get("/cluster").get_data(as_text=True)
    assert "Estado del clúster" in page


def test_cluster_summary_with_two_servers(app):
    primary, url_a = serve(status_payload("primario"))
    replica, url_b = serve(status_payload("replica", lag=1.8))
    app.config["CLUSTER_NODES"] = [
        {"name": "servidor-a", "url": url_a},
        {"name": "servidor-b", "url": url_b},
    ]
    try:
        client = make_user(app, "alice")
        data = client.get("/api/cluster").get_json()
        assert data["summary"]["state"] == "ok"
        assert data["summary"]["primary"] == "servidor-a"
        assert data["summary"]["replica_lag"] == 1.8
        assert data["summary"]["nodes_up"] == 2
        page = client.get("/cluster/fragment").get_data(as_text=True)
        assert "servidor-b" in page and "1.8" in page
    finally:
        primary.shutdown()
        replica.shutdown()


def test_cluster_marks_unreachable_node_as_degraded(app):
    primary, url_a = serve(status_payload("primario"))
    app.config["CLUSTER_NODES"] = [
        {"name": "servidor-a", "url": url_a},
        {"name": "servidor-b", "url": "http://127.0.0.1:9"},
    ]
    app.config["CLUSTER_TIMEOUT"] = 0.5
    try:
        client = make_user(app, "alice")
        data = client.get("/api/cluster").get_json()
        assert data["summary"]["state"] == "degradado"
        down = [n for n in data["nodes"] if not n["up"]][0]
        assert down["name"] == "servidor-b" and down["error"]
    finally:
        primary.shutdown()


def test_cluster_without_primary_is_down(app):
    replica, url_b = serve(status_payload("replica", lag=3))
    app.config["CLUSTER_NODES"] = [{"name": "servidor-b", "url": url_b}]
    try:
        data = make_user(app, "alice").get("/api/cluster").get_json()
        assert data["summary"]["state"] == "caido"
        assert data["summary"]["primary"] is None
    finally:
        replica.shutdown()


def test_healthz_reports_node(app):
    app.config["NODE_NAME"] = "servidor-a"
    app.config["NODE_ROLE"] = "primario"
    body = app.test_client().get("/healthz").get_json()
    assert body["node"] == "servidor-a" and body["role"] == "primario"


def test_agent_effective_role_follows_exports(monkeypatch, tmp_path):
    share = str(tmp_path / "share")
    agent = load_agent(monkeypatch, tmp_path, "servidor-b", f"{share} 100.64.0.0/10(ro,sync)\n")
    monkeypatch.setattr(agent, "run", lambda cmd, timeout=3: "active")
    assert agent.effective_role() == "replica"
    (tmp_path / "exports").write_text(f"{share} 100.64.0.0/10(rw,sync)\n")
    assert agent.effective_role() == "primario"
    (tmp_path / "exports").write_text("")
    assert agent.effective_role() == "sin-exportar"
    monkeypatch.setattr(agent, "run", lambda cmd, timeout=3: "inactive")
    assert agent.effective_role() == "detenido"


def test_agent_heartbeat_age(monkeypatch, tmp_path):
    agent = load_agent(monkeypatch, tmp_path, "servidor-b")
    assert agent.heartbeat() is None
    hb = tmp_path / "share" / ".cluster"
    hb.mkdir(parents=True)
    (hb / "heartbeat").write_text(json.dumps({"ts": time.time() - 4, "node": "servidor-a"}))
    data = agent.status()
    assert 3.5 <= data["heartbeat_age"] <= 6
    assert data["heartbeat_from"] == "servidor-a"


def test_agent_probe_unknown_target(monkeypatch, tmp_path):
    agent = load_agent(monkeypatch, tmp_path, "cliente")
    assert agent.probe("a") == {"target": "a", "known": False, "reachable": False}
    server, url = serve({})
    host, port = url.removeprefix("http://").split(":")
    monkeypatch.setenv("PROBE_TARGETS", f"a={host}:{port},muerto=127.0.0.1:9")
    assert agent.probe("a")["reachable"] is True
    assert agent.probe("muerto")["reachable"] is False
    server.shutdown()


def test_agent_reports_primary_epoch(monkeypatch, tmp_path):
    state = tmp_path / "state"
    state.mkdir()
    monkeypatch.setenv("STATE_DIR", str(state))
    monkeypatch.setenv("FIRST_SERVER", "servidor-a")
    agent = load_agent(monkeypatch, tmp_path, "servidor")
    assert agent.status()["primary_epoch"] is None
    (state / "primary").write_text("1793000000.5\n")
    data = agent.status()
    assert data["primary_epoch"] == 1793000000.5
    assert data["promoted"] is True
    monkeypatch.setattr(agent, "run", lambda cmd, timeout=3: "active")
    (tmp_path / "exports").write_text(f"{tmp_path / 'share'} 100.64.0.0/10(rw,sync)\n")
    assert agent.effective_role() == "primario"
