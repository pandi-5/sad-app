"""Pruebas de las partes de setup.sh que no necesitan systemd, NFS ni red."""
from __future__ import annotations

import subprocess
import textwrap
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


def run_bash(script: str, tmp_path: Path) -> subprocess.CompletedProcess:
    prelude = textwrap.dedent(
        f"""
        set -Eeuo pipefail
        source {ROOT}/setup.sh
        CONF_DIR={tmp_path}/etc; CONF=$CONF_DIR/lab.conf; DERIVED=$CONF_DIR/derived.conf
        STATE_DIR={tmp_path}/state; LIB_DIR={tmp_path}/lib; mkdir -p "$CONF_DIR" "$STATE_DIR" "$LIB_DIR"
        cp {ROOT}/deploy/lab.conf.example "$CONF"
        LAB_USER=tester; LAB_HOME={tmp_path}; APP_DIR={tmp_path}/app; mkdir -p "$APP_DIR"
        . "$CONF"; LAB_USER=tester; APP_DIR={tmp_path}/app
        """
    )
    return subprocess.run(
        ["bash", "-c", prelude + textwrap.dedent(script)],
        capture_output=True, text=True, timeout=30,
    )


def test_script_has_valid_syntax():
    assert subprocess.run(["bash", "-n", str(ROOT / "setup.sh")]).returncode == 0


def test_usage_lists_roles():
    out = subprocess.run([str(ROOT / "setup.sh"), "help"], capture_output=True, text=True)
    assert out.returncode == 0
    for word in ("servidor-a", "servidor-b", "cliente", "failback"):
        assert word in out.stdout


def test_unknown_command_fails():
    out = subprocess.run([str(ROOT / "setup.sh"), "inventado"], capture_output=True, text=True)
    assert out.returncode == 1


def test_addresses_follow_overlay_mode(tmp_path):
    out = run_bash(
        """
        OVERLAY_MODE=sim;  echo "sim:$(addr_of servidor-a)"
        OVERLAY_MODE=none; echo "none:$(addr_of servidor-b)"
        OVERLAY_MODE=real; echo "real:$(addr_of cliente-1)"
        OVERLAY_MODE=sim;  echo "net:$(export_net)"
        OVERLAY_MODE=none; echo "lan:$(export_net)"
        """,
        tmp_path,
    )
    assert out.returncode == 0, out.stderr
    assert "sim:100.64.0.11" in out.stdout
    assert "none:192.168.56.12" in out.stdout
    assert "real:cliente-1" in out.stdout
    assert "net:100.64.0.0/10" in out.stdout
    assert "lan:192.168.56.0/24" in out.stdout


def test_write_file_is_idempotent(tmp_path):
    out = run_bash(
        f"""
        t={tmp_path}/prueba.txt
        echo contenido | write_file "$t" 644 && echo primera=cambio
        echo contenido | write_file "$t" 644 || echo segunda=sin-cambio
        echo otro | write_file "$t" 644 && echo tercera=cambio
        """,
        tmp_path,
    )
    assert out.returncode == 0, out.stderr
    assert "primera=cambio" in out.stdout
    assert "segunda=sin-cambio" in out.stdout
    assert "tercera=cambio" in out.stdout


def test_env_set_replaces_instead_of_duplicating(tmp_path):
    out = run_bash(
        """
        chown() { :; }
        env_set NODE_NAME servidor-a
        env_set NODE_NAME servidor-b
        env_set CLUSTER_NODES "a=http://1.1.1.1:5100,b=http://2.2.2.2:5100"
        env_set CLUSTER_NODES "a=http://1.1.1.1:5100"
        grep -c '^NODE_NAME=' "$APP_DIR/.env"
        env_get NODE_NAME
        env_get CLUSTER_NODES
        """,
        tmp_path,
    )
    assert out.returncode == 0, out.stderr
    lines = out.stdout.split()
    assert lines[0] == "1"
    assert lines[1] == "servidor-b"
    assert lines[2] == "a=http://1.1.1.1:5100"


def test_derived_config_contains_all_peer_addresses(tmp_path):
    out = run_bash(
        """
        OVERLAY_MODE=sim
        write_derived servidor-b servidor-b
        grep -E '^(NODE_ROLE|ADDR_SERVIDOR_A|ADDR_CLIENTE_2|EXPORT_NET)=' "$DERIVED"
        """,
        tmp_path,
    )
    assert out.returncode == 0, out.stderr
    assert "NODE_ROLE=servidor-b" in out.stdout
    assert "ADDR_SERVIDOR_A=100.64.0.11" in out.stdout
    assert "ADDR_CLIENTE_2=100.64.0.22" in out.stdout
    assert "EXPORT_NET=100.64.0.0/10" in out.stdout


def test_embedded_scripts_have_valid_syntax(tmp_path):
    """Extrae los scripts que setup.sh instala en las máquinas y comprueba su sintaxis."""
    text = (ROOT / "setup.sh").read_text()
    import re
    blocks = re.findall(r"<<'EOF' \|\| true\n(#!/usr/bin/env bash.*?)\nEOF\n", text, re.S)
    assert len(blocks) >= 5
    for i, block in enumerate(blocks):
        path = tmp_path / f"embebido{i}.sh"
        path.write_text(block + "\n")
        result = subprocess.run(["bash", "-n", str(path)], capture_output=True, text=True)
        assert result.returncode == 0, f"{block[:60]!r}: {result.stderr}"


def test_embedded_scripts_load_derived_after_lab_conf():
    """lab.conf deja LAB_USER vacío. derived.conf debe leerse después para que no lo pise."""
    text = (ROOT / "setup.sh").read_text()
    for name in ("replicate.sh", "watchdog.sh"):
        start = text.index(f"{name} 755")
        block = text[start:start + 700]
        assert block.index("lab.conf") < block.index("derived.conf"), name


def test_seven_nodes_have_addresses(tmp_path):
    out = run_bash(
        """
        echo "nodos:$ALL_NODES"
        OVERLAY_MODE=sim;  echo "sim-d:$(addr_of servidor-d) sim-c3:$(addr_of cliente-3)"
        OVERLAY_MODE=none; echo "lan-c:$(addr_of servidor-c)"
        OVERLAY_MODE=real; TSIP_C3=100.99.1.2; echo "real-c3:$(addr_of cliente-3) real-d:$(addr_of servidor-d)"
        echo "primero:$(first_server)"
        """,
        tmp_path,
    )
    assert out.returncode == 0, out.stderr
    assert "nodos:servidor-a servidor-b servidor-c servidor-d cliente-1 cliente-2 cliente-3" in out.stdout
    assert "sim-d:100.64.0.14 sim-c3:100.64.0.23" in out.stdout
    assert "lan-c:192.168.56.13" in out.stdout
    assert "real-c3:100.99.1.2 real-d:servidor-d" in out.stdout
    assert "primero:servidor-a" in out.stdout


def test_derived_lists_servers_in_succession_order(tmp_path):
    out = run_bash(
        """
        OVERLAY_MODE=real; WITNESS_QUORUM=2
        write_derived servidor servidor-c
        . "$DERIVED"
        echo "servers:$SERVERS"; echo "clients:$CLIENTS"; echo "q:$WITNESS_QUORUM"; echo "d:$ADDR_SERVIDOR_D"
        """,
        tmp_path,
    )
    assert out.returncode == 0, out.stderr
    assert "servers:servidor-a servidor-b servidor-c servidor-d" in out.stdout
    assert "clients:cliente-1 cliente-2 cliente-3" in out.stdout
    assert "q:2" in out.stdout
    assert "d:servidor-d" in out.stdout


def test_lab_conf_example_has_no_crlf():
    assert b"\r" not in (ROOT / "deploy" / "lab.conf.example").read_bytes()
    assert b"\r" not in (ROOT / "setup.sh").read_bytes()


def _watchdog_world(tmp_path, up, cut=(), primary_here=None, others_primary=None):
    """Prepara un vigilante de servidor-c con red, testigos y agentes simulados."""
    import re
    text = (ROOT / "setup.sh").read_text()
    body = re.search(r"watchdog.sh 755 <<'EOF' \|\| true\n(#!/usr/bin/env bash.*?)\nEOF\n", text, re.S).group(1)
    etc, state, world, bindir = (tmp_path / d for d in ("etc", "state", "world", "bin"))
    for d in (etc, state, world / "up", world / "cut", world / "role", world / "epoch", bindir,
              tmp_path / "share" / ".cluster", tmp_path / "app"):
        d.mkdir(parents=True, exist_ok=True)
    body = body.replace("/etc/sad-lab", str(etc)).replace("/var/lib/sad-lab", str(state)).replace("/var/log/sad-lab.log", str(tmp_path / "log"))
    (tmp_path / "watchdog.sh").write_text(body + "\n")
    (etc / "lab.conf").write_text('LAB_USER=""\n')
    addrs = "".join(f"ADDR_{n.upper().replace('-', '_')}={n}\n" for n in
                    "servidor-a servidor-b servidor-c servidor-d cliente-1 cliente-2 cliente-3".split())
    (etc / "derived.conf").write_text(
        f"NODE_NAME=servidor-c\nLAB_USER=root\nAPP_DIR={tmp_path}/app\nEXPORT_DIR={tmp_path}/share\n"
        'AGENT_PORT=5100\nWATCH_FAILS=2\nWITNESS_QUORUM=2\n'
        'SERVERS="servidor-a servidor-b servidor-c servidor-d"\nCLIENTS="cliente-1 cliente-2 cliente-3"\n' + addrs)
    (tmp_path / "share" / ".cluster" / "heartbeat").write_text("{}")
    (tmp_path / "exports").write_text(f"{tmp_path}/share 100.64.0.0/10(ro,sync)\n")
    body = (tmp_path / "watchdog.sh").read_text().replace("/etc/exports", str(tmp_path / "exports"))
    (tmp_path / "watchdog.sh").write_text(body)
    (tmp_path / "app" / ".env").write_text("NODE_ROLE=replica\n")
    (tmp_path / "app" / "setup.sh").write_text(f"#!/bin/bash\nrm -f {state}/primary\necho demote >> {tmp_path}/log\n")
    (tmp_path / "app" / "setup.sh").chmod(0o755)
    for h in up:
        (world / "up" / h).touch()
    for h in cut:
        (world / "cut" / h).touch()
    for h, epoch in (others_primary or {}).items():
        (world / "role" / h).write_text("primario")
        (world / "epoch" / h).write_text(str(epoch))
    if primary_here is not None:
        (state / "primary").write_text(str(primary_here))
    w = str(world)
    fakes = {
        "curl": f'url="${{@: -1}}"; h=$(echo "$url" | sed -E "s#http://([^:/]+).*#\\1#")\n'
                f'[ -f {w}/up/$h ] && [ ! -f {w}/cut/$h ] || exit 7\n'
                f'case "$url" in */status) echo "{{\\"effective_role\\":\\"$(cat {w}/role/$h 2>/dev/null || echo replica)\\",'
                f'\\"primary_epoch\\":$(cat {w}/epoch/$h 2>/dev/null || echo null)}}";;\n'
                f'*/probe*) t=${{url##*target=}}; [ -f {w}/up/$t ] && echo \'{{"reachable":true}}\' || echo \'{{"reachable":false}}\';; esac',
        "nc": f'h="${{@: -2:1}}"; [ -f {w}/up/$h ] && [ ! -f {w}/cut/$h ]',
        "sleep": f'n=$(cat {tmp_path}/n 2>/dev/null || echo 0); echo $((n+1)) > {tmp_path}/n; [ $n -ge 6 ] && kill -TERM $PPID; exit 0',
        "exportfs": "exit 0", "systemctl": "exit 0", "install": "exit 0",
    }
    for name, code in fakes.items():
        f = bindir / name
        f.write_text("#!/bin/bash\n" + code + "\n")
        f.chmod(0o755)
    import os
    env = dict(os.environ, PATH=f"{bindir}:{os.environ['PATH']}")
    subprocess.run(["bash", str(tmp_path / "watchdog.sh")], env=env, capture_output=True, text=True, timeout=30)
    return (tmp_path / "log").read_text(), (state / "primary").exists()


TESTIGOS = ["cliente-1", "cliente-2", "cliente-3"]


def test_watchdog_waits_for_earlier_server(tmp_path):
    log, primary = _watchdog_world(tmp_path, ["servidor-b", "servidor-c", "servidor-d", *TESTIGOS])
    assert "servidor-b sigue vivo" in log and not primary


def test_watchdog_takes_over_when_earlier_servers_are_down(tmp_path):
    log, primary = _watchdog_world(tmp_path, ["servidor-c", "servidor-d", *TESTIGOS])
    assert "Asumiendo como primario" in log and primary
    assert "(rw," in (tmp_path / "exports").read_text()


def test_watchdog_needs_witness_majority(tmp_path):
    log, primary = _watchdog_world(tmp_path, ["servidor-c", "servidor-d", "cliente-1"])
    assert "Sin mayoría de testigos" in log and not primary


def test_watchdog_does_not_take_over_on_own_partition(tmp_path):
    up = ["servidor-a", "servidor-b", "servidor-c", "servidor-d", *TESTIGOS]
    log, primary = _watchdog_world(tmp_path, up, cut=["servidor-a", "servidor-b"])
    assert "puede ser mi red" in log and not primary


def test_watchdog_older_primary_steps_down(tmp_path):
    log, primary = _watchdog_world(tmp_path, ["servidor-d", *TESTIGOS], primary_here=100,
                                   others_primary={"servidor-d": 200})
    assert "Cedo y vuelvo a réplica" in log and not primary
