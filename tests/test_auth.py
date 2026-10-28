from __future__ import annotations

import re

from conftest import ADMIN_PASSWORD, admin_login, login, register


def test_register_creates_read_only_user(app):
    client = app.test_client()
    response = register(client, "alice")
    assert response.status_code == 302

    page = client.get("/")
    assert page.status_code == 200
    body = page.get_data(as_text=True)
    assert "alice" in body
    assert "solo lectura" in body

    with client.session_transaction() as sess:
        assert sess["u"] == "alice"
        assert sess["is_admin"] is False


def test_duplicate_registration_is_rejected(app):
    client = app.test_client()
    register(client, "alice")
    response = register(app.test_client(), "alice")
    assert response.status_code == 400
    assert "ya existe" in response.get_data(as_text=True)


def test_login_and_logout(app):
    register(app.test_client(), "alice")
    client = app.test_client()

    wrong = login(client, "alice", "incorrecta")
    assert wrong.status_code == 401

    ok = login(client, "alice")
    assert ok.status_code == 302
    assert client.get("/").status_code == 200

    out = client.post("/logout")
    assert out.status_code == 302
    with client.session_transaction() as sess:
        assert "u" not in sess


def test_admin_login(app):
    client = app.test_client()
    wrong = client.post(
        "/login", data={"name": "coordinador", "password": "mala"}
    )
    assert wrong.status_code == 401

    response = client.post(
        "/login", data={"name": "coordinador", "password": ADMIN_PASSWORD}
    )
    assert response.status_code == 302
    assert response.headers["Location"].endswith("/admin")

    with client.session_transaction() as sess:
        assert sess["is_admin"] is True

    assert client.get("/admin").status_code == 200


def test_login_rate_limit(app):
    client = app.test_client()
    register(app.test_client(), "alice")
    for _ in range(5):
        assert login(client, "alice", "mala").status_code == 401
    blocked = login(client, "alice", "mala")
    assert blocked.status_code == 429
    assert "Demasiados intentos" in blocked.get_data(as_text=True)


def test_change_password_and_revoke_other_sessions(app):
    client = app.test_client()
    register(client, "alice")
    other = app.test_client()
    login(other, "alice")

    response = client.post(
        "/account/password",
        data={
            "current": "password123",
            "password": "nueva-clave-123",
            "confirm": "nueva-clave-123",
        },
    )
    assert response.status_code == 302

    assert login(app.test_client(), "alice", "password123").status_code == 401
    assert login(app.test_client(), "alice", "nueva-clave-123").status_code == 302

    # La otra sesión queda revocada por el cambio de epoch.
    other.get("/")
    with other.session_transaction() as sess:
        assert "u" not in sess


def test_admin_reset_password_and_deactivate(app):
    alice = app.test_client()
    register(alice, "alice")
    admin = admin_login(app)

    response = admin.post("/admin/users/alice/reset-password")
    assert response.status_code == 302
    with admin.session_transaction() as sess:
        flashes = sess.get("_flashes") or []
    text = " ".join(message for _, message in flashes)
    match = re.search(r"Contraseña temporal de alice: (\S+)", text)
    assert match, text
    temporary = match.group(1)

    assert login(app.test_client(), "alice", temporary).status_code == 302

    alice.get("/")
    with alice.session_transaction() as sess:
        assert "u" not in sess

    admin = admin_login(app)
    assert admin.post("/admin/users/alice/active").status_code == 302
    assert login(app.test_client(), "alice", temporary).status_code == 401


def test_username_sanitization(app):
    client = app.test_client()
    response = register(client, "  José Pérez!!  ")
    assert response.status_code == 302
    with client.session_transaction() as sess:
        assert sess["u"] == "joseperez"
