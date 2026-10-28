from __future__ import annotations

import io

import pytest

from conftest import file_row, make_user, upload
from app import create_app


def test_anonymous_is_sent_to_login(client):
    response = client.get("/")
    assert response.status_code == 200
    assert "Crear cuenta" in response.get_data(as_text=True)

    response = client.get("/files/abc")
    assert response.status_code == 302
    assert response.headers["Location"].endswith("/")


def test_security_headers(client):
    response = client.get("/")
    assert "default-src 'self'" in response.headers["Content-Security-Policy"]
    assert response.headers["X-Frame-Options"] == "DENY"
    assert response.headers["X-Content-Type-Options"] == "nosniff"
    assert response.headers["Referrer-Policy"] == "same-origin"


def test_client_cannot_open_admin_panel(app):
    client = make_user(app, "alice", perms=(True, True, False))
    response = client.get("/admin")
    assert response.status_code == 403


def test_permission_denied_returns_403_and_logs(app):
    client = make_user(app, "lector", perms=(True, False, False))
    response = client.post(
        "/files",
        data={"files": (io.BytesIO(b"x"), "x.txt")},
        content_type="multipart/form-data",
    )
    assert response.status_code == 403

    from app.db import connect_db

    conn = connect_db(app.config["DB_PATH"])
    try:
        entry = conn.execute(
            "SELECT * FROM log WHERE op='DENEGADO' AND usr='lector'"
        ).fetchone()
    finally:
        conn.close()
    assert entry is not None


def test_csrf_is_required_when_enabled(tmp_path):
    application = create_app(
        {
            "TESTING": True,
            "SECRET_KEY": "csrf-test-" + ("y" * 48),
            "ADMIN_USER": "coordinador",
            "ADMIN_PASS_HASH": "scrypt:32768:8:1$placeholder$placeholder",
            "DB_PATH": str(tmp_path / "data" / "sad.db"),
            "STORAGE_DIR": str(tmp_path / "storage"),
            "WTF_CSRF_ENABLED": True,
            "MAX_UPLOAD_MB": 1,
        }
    )
    client = application.test_client()
    response = client.post(
        "/register",
        data={"name": "alice", "password": "password123", "confirm": "password123"},
    )
    assert response.status_code == 400
    assert "token de seguridad" in response.get_data(as_text=True)


def test_filename_is_escaped_in_html(app):
    client = make_user(app, "alice", perms=(True, True, False))
    dangerous = "<img src=x onerror=alert(1)>.txt"
    assert upload(client, dangerous, b"x").status_code == 200
    page = client.get("/")
    body = page.get_data(as_text=True)
    assert "<img src=x onerror=alert(1)>" not in body
    assert "&lt;img" in body


def test_inactive_session_is_revoked(app):
    from conftest import admin_login

    client = make_user(app, "alice", perms=(True, True, False))
    assert client.get("/").status_code == 200
    admin = admin_login(app)
    assert admin.post("/admin/users/alice/active").status_code == 302

    client.get("/")
    with client.session_transaction() as sess:
        assert "u" not in sess


def test_app_rejects_insecure_secret(tmp_path):
    with pytest.raises(RuntimeError):
        create_app(
            {
                "SECRET_KEY": "cambia-esto",
                "ADMIN_USER": "coordinador",
                "ADMIN_PASS_HASH": "",
                "DB_PATH": str(tmp_path / "data" / "sad.db"),
                "STORAGE_DIR": str(tmp_path / "storage"),
            }
        )


def test_app_rejects_placeholder_secret(tmp_path):
    with pytest.raises(RuntimeError):
        create_app(
            {
                "SECRET_KEY": (
                    "cambia-este-secreto-por-uno-aleatorio-de-64-caracteres"
                ),
                "ADMIN_USER": "coordinador",
                "ADMIN_PASS_HASH": "scrypt:32768:8:1$placeholder$placeholder",
                "DB_PATH": str(tmp_path / "data" / "sad.db"),
                "STORAGE_DIR": str(tmp_path / "storage"),
            }
        )


def test_app_rejects_placeholder_admin_password(tmp_path, monkeypatch):
    monkeypatch.setenv("ADMIN_PASS", "cambia-esto-por-una-contraseña-fuerte")
    with pytest.raises(RuntimeError):
        create_app(
            {
                "SECRET_KEY": "x" * 64,
                "ADMIN_USER": "coordinador",
                "ADMIN_PASS_HASH": "scrypt:32768:8:1$placeholder$placeholder",
                "DB_PATH": str(tmp_path / "data" / "sad.db"),
                "STORAGE_DIR": str(tmp_path / "storage"),
            }
        )


def test_healthz(client):
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.get_json()["status"] == "ok"
