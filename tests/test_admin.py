from __future__ import annotations

from conftest import admin_login, file_row, make_user, set_mode, upload


def test_admin_changes_mode_and_clients_see_it(app):
    client = make_user(app, "alice", perms=(True, True, False))
    admin = admin_login(app)
    response = admin.post("/admin/mode", data={"mode": "versiones"})
    assert response.status_code == 302

    body = client.get("/").get_data(as_text=True)
    assert "Por versiones" in body

    from app.db import connect_db

    conn = connect_db(app.config["DB_PATH"])
    try:
        mode = conn.execute("SELECT v FROM cfg WHERE k='mode'").fetchone()["v"]
    finally:
        conn.close()
    assert mode == "versiones"

    invalid = admin.post("/admin/mode", data={"mode": "inventado"})
    assert invalid.status_code == 400


def test_admin_updates_permissions(app):
    client = make_user(app, "alice", perms=(True, False, False))
    assert client.post(
        "/files",
        data={"files": (__import__("io").BytesIO(b"x"), "x.txt")},
        content_type="multipart/form-data",
    ).status_code == 403

    admin = admin_login(app)
    response = admin.post(
        "/admin/users/alice/perms",
        data={"r": "on", "w": "on"},
    )
    assert response.status_code == 302

    assert upload(client, "x.txt", b"x").status_code == 200


def test_admin_status_json(app):
    make_user(app, "alice", perms=(True, True, False))
    admin = admin_login(app)
    response = admin.get("/admin/status")
    assert response.status_code == 200
    payload = response.get_json()
    assert payload["stats"]["users"] == 1
    assert payload["users"][0]["name"] == "alice"
    assert "files" in payload


def test_admin_can_delete_locked_file(app):
    set_mode(app, "bloqueo")
    alice = make_user(app, "alice", perms=(True, True, False))
    upload(alice, "bloqueado.txt", b"x")
    row = file_row(app, "bloqueado.txt")
    alice.get(f"/files/{row['id']}")

    admin = admin_login(app)
    response = admin.post(f"/admin/files/{row['id']}/delete")
    assert response.status_code == 302
    assert file_row(app, "bloqueado.txt") is None


def test_admin_can_use_file_space(app):
    admin = admin_login(app)
    page = admin.get("/")
    assert page.status_code == 200
    assert "Subir archivos" in page.get_data(as_text=True)
    assert upload(admin, "admin.txt", b"contenido").status_code == 200
    assert file_row(app, "admin.txt") is not None


def test_logs_filtering(app):
    make_user(app, "alice", perms=(True, True, False))
    upload(app.test_client(), "nada.txt", b"x")
    admin = admin_login(app)
    page = admin.get("/admin?op=REGISTER")
    body = page.get_data(as_text=True)
    assert "REGISTER" in body
    assert "LOGIN" not in body.split("<tbody>")[1].split("</tbody>")[0]


def test_admin_password_is_not_in_users_table(app):
    make_user(app, "alice", perms=(True, True, False))
    from app.db import connect_db

    conn = connect_db(app.config["DB_PATH"])
    try:
        row = conn.execute(
            "SELECT * FROM users WHERE name='coordinador'"
        ).fetchone()
    finally:
        conn.close()
    assert row is None
