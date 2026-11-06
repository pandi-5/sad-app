"""Pruebas del elector con un etcd real de un solo miembro. Se omiten si etcd no está instalado."""
from __future__ import annotations

import importlib.util
import json
import shutil
import socket
import subprocess
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SERVERS = "servidor-a servidor-b servidor-c servidor-d"

pytestmark = pytest.mark.skipif(shutil.which("etcd") is None, reason="etcd no está instalado")


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture
def etcd(tmp_path):
    client, peer = free_port(), free_port()
    proc = subprocess.Popen(
        ["etcd", "--name", "t", "--data-dir", str(tmp_path / "etcd"),
         "--listen-client-urls", f"http://127.0.0.1:{client}", "--advertise-client-urls", f"http://127.0.0.1:{client}",
         "--listen-peer-urls", f"http://127.0.0.1:{peer}", "--initial-advertise-peer-urls", f"http://127.0.0.1:{peer}",
         "--initial-cluster", f"t=http://127.0.0.1:{peer}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    url = f"http://127.0.0.1:{client}"
    mod = load()
    for _ in range(50):
        try:
            mod.Etcd([url]).get("/x")
            break
        except mod.EtcdError:
            time.sleep(0.2)
    yield proc, url
    proc.kill()
    proc.wait()


def load():
    spec = importlib.util.spec_from_file_location("sad_elector", ROOT / "cluster" / "elector.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def make(mod, tmp_path, name, url, heartbeat_epoch=None):
    base = tmp_path / name
    for d in ("state", "share/.cluster", "app/data"):
        (base / d).mkdir(parents=True, exist_ok=True)
    (base / "exports").write_text(f"{base}/share 100.64.0.0/10(ro,sync)\n")
    (base / "app" / ".env").write_text("NODE_ROLE=replica\n")
    if heartbeat_epoch is not None:
        (base / "share" / ".cluster" / "heartbeat").write_text(json.dumps({"epoch": heartbeat_epoch}))
    conf = {"NODE_NAME": name, "SERVERS": SERVERS, "ETCD_ENDPOINTS": url, "LEASE_TTL": "3",
            "RANK_DELAY": "0.3", "STALE_GRACE": "30", "STATE_DIR": str(base / "state"),
            "EXPORTS_FILE": str(base / "exports"), "EXPORT_DIR": str(base / "share"),
            "APP_DIR": str(base / "app"), "LOG_FILE": str(tmp_path / "log")}
    el = mod.Elector(conf)
    el.run_cmd = lambda *cmd: None
    return el, base


def is_primary(base: Path) -> bool:
    return (base / "state" / "primary").exists() and "(rw," in (base / "exports").read_text()


def test_first_server_wins_and_others_follow(tmp_path, etcd):
    mod = load()
    _, url = etcd
    a, ba = make(mod, tmp_path, "servidor-a", url)
    b, bb = make(mod, tmp_path, "servidor-b", url, heartbeat_epoch=0)
    a.tick()
    b.tick()
    assert is_primary(ba) and not is_primary(bb)
    assert (bb / "state" / "leader").read_text().strip() == "servidor-a"
    assert int((ba / "state" / "primary").read_text()) > 0


def test_replica_takes_over_when_lease_expires(tmp_path, etcd):
    mod = load()
    _, url = etcd
    a, ba = make(mod, tmp_path, "servidor-a", url)
    a.tick()
    epoch = int((ba / "state" / "primary").read_text())
    b, bb = make(mod, tmp_path, "servidor-b", url, heartbeat_epoch=epoch)
    b.tick()
    assert not is_primary(bb)
    deadline = time.time() + 10   # A deja de renovar, como si se hubiera caído
    while time.time() < deadline and not is_primary(bb):
        b.tick()
        time.sleep(0.5)
    assert is_primary(bb)
    assert int((bb / "state" / "primary").read_text()) > epoch


def test_server_with_old_data_does_not_take_over(tmp_path, etcd):
    mod = load()
    _, url = etcd
    a, ba = make(mod, tmp_path, "servidor-a", url)
    a.tick()
    b, bb = make(mod, tmp_path, "servidor-b", url, heartbeat_epoch=1)  # época vieja
    deadline = time.time() + 6
    while time.time() < deadline:
        b.tick()
        time.sleep(0.5)
    assert not is_primary(bb)
    assert "Mis datos no son del último primario" in (tmp_path / "log").read_text()


def test_primary_fences_itself_without_quorum(tmp_path, etcd):
    mod = load()
    proc, url = etcd
    a, ba = make(mod, tmp_path, "servidor-a", url)
    a.tick()
    assert is_primary(ba)
    proc.kill()
    proc.wait()
    start = time.time()
    while time.time() - start < 6 and is_primary(ba):
        a.tick()
        time.sleep(0.3)
    assert not is_primary(ba)
    assert time.time() - start < 3, "debe aislarse antes de que venza el contrato de 3 s"
    assert "me aíslo en solo lectura" in (tmp_path / "log").read_text()


def test_stepdown_and_reservation_hand_over(tmp_path, etcd):
    mod = load()
    _, url = etcd
    a, ba = make(mod, tmp_path, "servidor-a", url)
    a.tick()
    epoch = int((ba / "state" / "primary").read_text())
    c, bc = make(mod, tmp_path, "servidor-c", url, heartbeat_epoch=epoch)
    etcd_client = mod.Etcd([url])
    etcd_client.put(mod.RESERVE_KEY, {"node": "servidor-c"}, etcd_client.grant(30))
    (ba / "state" / "stepdown").touch()
    a.tick()
    assert not is_primary(ba)
    a.tick()                      # en enfriamiento, no vuelve a postularse
    c.tick()
    assert is_primary(bc) and not is_primary(ba)
    assert etcd_client.get(mod.RESERVE_KEY) is None


def test_restart_never_starts_as_primary(tmp_path, etcd):
    mod = load()
    _, url = etcd
    a, ba = make(mod, tmp_path, "servidor-a", url)
    (ba / "state" / "primary").write_text("5\n")
    (ba / "exports").write_text(f"{ba}/share 100.64.0.0/10(rw,sync)\n")
    b, bb = make(mod, tmp_path, "servidor-b", url, heartbeat_epoch=0)
    b.tick()  # B no tiene la época del último primario, pero tampoco hay último primario
    a.run(max_ticks=1)
    log = (tmp_path / "log").read_text()
    assert "primero hay que ganar la elección" in log
