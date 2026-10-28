from __future__ import annotations

import io
import time

import pytest
from werkzeug.security import generate_password_hash

from app import create_app

ADMIN_PASSWORD = "admin-test-pass"


@pytest.fixture
def app(tmp_path):
    config = {
        "TESTING": True,
        "SECRET_KEY": "test-secret-" + ("x" * 48),
        "ADMIN_USER": "coordinador",
        "ADMIN_PASS_HASH": generate_password_hash(ADMIN_PASSWORD),
        "DB_PATH": str(tmp_path / "data" / "sad.db"),
        "STORAGE_DIR": str(tmp_path / "storage"),
        "WTF_CSRF_ENABLED": False,
        "MAX_UPLOAD_MB": 1,
        "MAX_TEXT_BYTES": 10_000,
        "MAX_VERSIONS": 5,
        "LOCK_TTL": 90,
        "ONLINE_WINDOW": 30,
        "LOGIN_MAX_ATTEMPTS": 5,
        "LOGIN_WINDOW": 900,
        "SESSION_LIFETIME_H": 8,
        "PASSWORD_MIN_LENGTH": 8,
    }
    application = create_app(config)
    yield application


@pytest.fixture
def client(app):
    return app.test_client()


def register(client, name="alice", password="password123"):
    return client.post(
        "/register",
        data={"name": name, "password": password, "confirm": password},
    )


def login(client, name="alice", password="password123"):
    return client.post(
        "/login",
        data={"name": name, "password": password},
    )


def admin_login(app):
    admin = app.test_client()
    response = admin.post(
        "/login",
        data={"name": "coordinador", "password": ADMIN_PASSWORD},
    )
    assert response.status_code == 302
    return admin


def grant(app, name, r=True, w=True, d=False):
    admin = admin_login(app)
    data = {}
    if r:
        data["r"] = "on"
    if w:
        data["w"] = "on"
    if d:
        data["d"] = "on"
    response = admin.post(f"/admin/users/{name}/perms", data=data)
    assert response.status_code == 302
    return admin


def make_user(app, name="alice", password="password123", perms=(True, True, False)):
    client = app.test_client()
    response = register(client, name, password)
    assert response.status_code == 302
    if perms != (True, False, False):
        grant(app, name, *perms)
    return client


def upload(client, name="nota.txt", content=b"hola mundo", field="files"):
    return client.post(
        "/files",
        data={field: (io.BytesIO(content), name)},
        content_type="multipart/form-data",
        headers={"X-Requested-With": "XMLHttpRequest"},
    )


def set_mode(app, mode):
    admin = admin_login(app)
    return admin.post("/admin/mode", data={"mode": mode})


def db_execute(app, sql, params=()):
    from app.db import connect_db

    conn = connect_db(app.config["DB_PATH"])
    try:
        cur = conn.execute(sql, params)
        conn.execute("COMMIT") if conn.in_transaction else None
        return cur
    finally:
        conn.close()


def file_row(app, name="nota.txt"):
    from app.db import connect_db

    conn = connect_db(app.config["DB_PATH"])
    try:
        return conn.execute(
            "SELECT * FROM files WHERE name=?", (name,)
        ).fetchone()
    finally:
        conn.close()


def file_id(client, name="nota.txt"):
    response = client.get("/")
    text = response.get_data(as_text=True)
    marker = f"/files/"
    # Se busca el enlace cuyo texto es el nombre; los ids son uuid hex.
    import re

    match = re.search(
        r'href="/files/([0-9a-f]{32})"[^>]*>' + re.escape(name), text
    )
    if match:
        return match.group(1)
    # Fallback: primera fila de la tabla.
    match = re.search(r'href="/files/([0-9a-f]{32})"', text)
    assert match, f"No se encontró el archivo {name}"
    return match.group(1)
