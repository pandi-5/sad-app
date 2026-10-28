from __future__ import annotations

import re
import time

from conftest import file_row, make_user, set_mode, upload


def _editor(client, file_id):
    return client.get(f"/files/{file_id}")


def test_versions_mode_detects_conflict_and_preserves_text(app):
    set_mode(app, "versiones")
    alice = make_user(app, "alice", perms=(True, True, False))
    bob = make_user(app, "bob", perms=(True, True, False))
    upload(alice, "conflicto.txt", b"base")
    row = file_row(app, "conflicto.txt")

    assert _editor(alice, row["id"]).status_code == 200
    assert _editor(bob, row["id"]).status_code == 200

    assert alice.post(
        f"/files/{row['id']}/save",
        data={"text": "texto de alice", "ver": "1"},
    ).status_code == 302

    conflict = bob.post(
        f"/files/{row['id']}/save",
        data={"text": "texto de bob", "ver": "1"},
    )
    assert conflict.status_code == 409
    body = conflict.get_data(as_text=True)
    assert "Conflicto" in body
    assert "texto de alice" in body
    assert "texto de bob" in body

    row = file_row(app, "conflicto.txt")
    assert row["ver"] == 2
    assert alice.get(f"/files/{row['id']}/download").data == b"texto de alice"

    retry = bob.post(
        f"/files/{row['id']}/save",
        data={"text": "texto de bob", "ver": "2"},
    )
    assert retry.status_code == 302
    row = file_row(app, "conflicto.txt")
    assert row["ver"] == 3
    assert bob.get(f"/files/{row['id']}/download").data == b"texto de bob"


def test_libre_mode_last_write_wins_and_logs_overwrite(app):
    set_mode(app, "libre")
    alice = make_user(app, "alice", perms=(True, True, False))
    bob = make_user(app, "bob", perms=(True, True, False))
    upload(alice, "libre.txt", b"base")
    row = file_row(app, "libre.txt")

    assert alice.post(
        f"/files/{row['id']}/save",
        data={"text": "alice", "ver": "1"},
    ).status_code == 302
    assert bob.post(
        f"/files/{row['id']}/save",
        data={"text": "bob", "ver": "1"},
    ).status_code == 302

    row = file_row(app, "libre.txt")
    assert row["ver"] == 3
    assert bob.get(f"/files/{row['id']}/download").data == b"bob"

    from app.db import connect_db

    conn = connect_db(app.config["DB_PATH"])
    try:
        entry = conn.execute(
            "SELECT * FROM log WHERE op='SOBRESCRITURA' AND file='libre.txt'"
        ).fetchone()
    finally:
        conn.close()
    assert entry is not None


def test_editor_root_does_not_expose_lock_countdown(app):
    set_mode(app, "versiones")
    alice = make_user(app, "alice", perms=(True, True, False))
    upload(alice, "editor.txt", b"base")
    row = file_row(app, "editor.txt")

    body = alice.get(f"/files/{row['id']}").get_data(as_text=True)
    root = re.search(r'<div class="editor-layout"[^>]*>', body).group(0)
    assert "data-lock-initial" in root
    assert "data-lock-remaining" not in root


def test_lock_mode_blocks_other_users(app):
    set_mode(app, "bloqueo")
    alice = make_user(app, "alice", perms=(True, True, False))
    bob = make_user(app, "bob", perms=(True, True, False))
    upload(alice, "bloqueo.txt", b"base")
    row = file_row(app, "bloqueo.txt")

    page = _editor(alice, row["id"])
    assert page.status_code == 200
    row = file_row(app, "bloqueo.txt")
    assert row["lock_user"] == "alice"

    page = _editor(bob, row["id"])
    assert page.status_code == 200
    body = page.get_data(as_text=True)
    assert "alice" in body
    assert "tiene el archivo bloqueado" in body
    assert "Solo lectura" in body

    rejected = bob.post(
        f"/files/{row['id']}/save",
        data={"text": "bob", "ver": "1"},
    )
    assert rejected.status_code == 409
    assert file_row(app, "bloqueo.txt")["ver"] == 1

    saved = alice.post(
        f"/files/{row['id']}/save",
        data={"text": "alice", "ver": "1"},
    )
    assert saved.status_code == 302
    row = file_row(app, "bloqueo.txt")
    assert row["ver"] == 2
    assert row["lock_user"] == "alice"


def test_heartbeat_and_force_unlock(app):
    set_mode(app, "bloqueo")
    alice = make_user(app, "alice", perms=(True, True, False))
    bob = make_user(app, "bob", perms=(True, True, False))
    upload(alice, "latido.txt", b"base")
    row = file_row(app, "latido.txt")
    _editor(alice, row["id"])

    beat = alice.post(f"/files/{row['id']}/lock/heartbeat")
    assert beat.status_code == 200
    assert beat.get_json()["ok"] is True
    assert beat.get_json()["owner"] == "alice"
    assert beat.get_json()["remaining"] > 0

    not_owner = bob.post(f"/files/{row['id']}/lock/heartbeat")
    assert not_owner.status_code == 200
    assert not_owner.get_json()["ok"] is False

    from conftest import admin_login

    admin = admin_login(app)
    unlocked = admin.post(f"/admin/files/{row['id']}/unlock")
    assert unlocked.status_code == 302
    assert file_row(app, "latido.txt")["lock_user"] is None

    _editor(bob, row["id"])
    assert file_row(app, "latido.txt")["lock_user"] == "bob"


def test_expired_lock_can_be_taken_and_blocks_stale_save(app):
    set_mode(app, "bloqueo")
    alice = make_user(app, "alice", perms=(True, True, False))
    bob = make_user(app, "bob", perms=(True, True, False))
    upload(alice, "caducado.txt", b"base")
    row = file_row(app, "caducado.txt")
    _editor(alice, row["id"])

    old = time.time() - app.config["LOCK_TTL"] - 5
    from app.db import connect_db

    conn = connect_db(app.config["DB_PATH"])
    try:
        conn.execute("UPDATE files SET lock_ts=? WHERE id=?", (old, row["id"]))
    finally:
        conn.close()

    stale = alice.post(
        f"/files/{row['id']}/save",
        data={"text": "tarde", "ver": "1"},
    )
    assert stale.status_code == 409

    _editor(bob, row["id"])
    row = file_row(app, "caducado.txt")
    assert row["lock_user"] == "bob"
    assert row["ver"] == 1


def test_locked_file_cannot_be_deleted_by_other_user(app):
    set_mode(app, "bloqueo")
    alice = make_user(app, "alice", perms=(True, True, True))
    bob = make_user(app, "bob", perms=(True, True, True))
    upload(alice, "protegido.txt", b"base")
    row = file_row(app, "protegido.txt")
    _editor(alice, row["id"])

    response = bob.post(f"/files/{row['id']}/delete")
    assert response.status_code == 302
    assert file_row(app, "protegido.txt") is not None
