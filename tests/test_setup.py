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
        . "$CONF"; LAB_USER=tester
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
