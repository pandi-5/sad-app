from __future__ import annotations

import base64
import io
from pathlib import Path

from conftest import file_id, file_row, make_user, upload

PNG_1PX = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk"
    "+A8AAQUBAScY42YAAAAASUVORK5CYII="
)


def test_upload_download_and_metadata(app):
    client = make_user(app, "alice", perms=(True, True, False))
    response = upload(client, "nota.txt", b"hola mundo")
    assert response.status_code == 200, response.get_data(as_text=True)
    payload = response.get_json()
    assert payload["ok"] is True
    assert payload["uploaded"] == ["nota.txt"]

    row = file_row(app, "nota.txt")
    assert row["is_text"] == 1
    assert row["size"] == len(b"hola mundo")
    assert row["ver"] == 1

    download = client.get(f"/files/{row['id']}/download")
    assert download.status_code == 200
    assert download.data == b"hola mundo"
    assert "attachment" in download.headers["Content-Disposition"]
    assert download.headers["X-Content-Type-Options"] == "nosniff"


def test_upload_sanitizes_path_traversal(app):
    client = make_user(app, "alice", perms=(True, True, False))
    response = upload(client, "../../evil.txt", b"peligro")
    assert response.status_code == 200
    row = file_row(app, "evil.txt")
    assert row is not None
    assert "/" not in row["stored_name"]
    stored = app.config["FILES_DIR"]
    assert (Path(stored) / row["stored_name"]).exists()


def test_text_and_binary_detection(app):
    client = make_user(app, "alice", perms=(True, True, False))
    assert upload(client, "texto.md", "# Hola\n".encode()).status_code == 200
    assert upload(client, "binario.bin", b"\x00\x01\x02\x03").status_code == 200

    text_row = file_row(app, "texto.md")
    binary_row = file_row(app, "binario.bin")
    assert text_row["is_text"] == 1
    assert binary_row["is_text"] == 0

    editor = client.get(f"/files/{text_row['id']}")
    assert editor.status_code == 200
    assert "editor-text" in editor.get_data(as_text=True)

    detail = client.get(f"/files/{binary_row['id']}")
    assert detail.status_code == 200
    assert "Vista previa no disponible" in detail.get_data(as_text=True)

    rejected = client.post(
        f"/files/{binary_row['id']}/save",
        data={"text": "no", "ver": "1"},
    )
    assert rejected.status_code == 400


def test_image_preview(app):
    client = make_user(app, "alice", perms=(True, True, False))
    assert upload(client, "pixel.png", PNG_1PX).status_code == 200
    row = file_row(app, "pixel.png")
    assert row["mime"] == "image/png"
    detail = client.get(f"/files/{row['id']}")
    assert "Vista previa" in detail.get_data(as_text=True)
    preview = client.get(f"/files/{row['id']}/preview")
    assert preview.status_code == 200
    assert preview.mimetype == "image/png"
    assert preview.data.startswith(b"\x89PNG")


def test_upload_limit_returns_413(app):
    client = make_user(app, "alice", perms=(True, True, False))
    big = b"x" * (app.config["MAX_UPLOAD_MB"] * 1024 * 1024 + 10)
    response = upload(client, "grande.txt", big)
    assert response.status_code == 413
    assert "demasiado grande" in response.get_data(as_text=True).lower()


def test_reader_cannot_upload_or_delete(app):
    reader = make_user(app, "lector", perms=(True, False, False))
    assert upload(reader, "x.txt", b"x").status_code == 403

    writer = make_user(app, "autor", perms=(True, True, False))
    upload(writer, "x.txt", b"x")
    row = file_row(app, "x.txt")
    assert reader.post(f"/files/{row['id']}/delete").status_code == 403
    assert file_row(app, "x.txt") is not None


def test_rename_and_delete_with_permissions(app):
    client = make_user(app, "alice", perms=(True, True, True))
    upload(client, "viejo.txt", b"contenido")
    row = file_row(app, "viejo.txt")
    renamed = client.post(
        f"/files/{row['id']}/rename", data={"name": "nuevo.txt"}
    )
    assert renamed.status_code == 302
    assert file_row(app, "nuevo.txt") is not None

    row = file_row(app, "nuevo.txt")
    deleted = client.post(f"/files/{row['id']}/delete")
    assert deleted.status_code == 302
    assert file_row(app, "nuevo.txt") is None


def test_versions_history_and_restore(app):
    client = make_user(app, "alice", perms=(True, True, False))
    upload(client, "historia.txt", b"version uno")
    row = file_row(app, "historia.txt")

    assert client.post(
        f"/files/{row['id']}/save",
        data={"text": "version dos", "ver": "1"},
    ).status_code == 302
    assert client.post(
        f"/files/{row['id']}/save",
        data={"text": "version tres", "ver": "2"},
    ).status_code == 302
    row = file_row(app, "historia.txt")
    assert row["ver"] == 3

    old = client.get(f"/files/{row['id']}/versions/1/download")
    assert old.status_code == 200
    assert old.data == b"version uno"

    restored = client.post(
        f"/files/{row['id']}/versions/1/restore", data={"ver": "3"}
    )
    assert restored.status_code == 302
    row = file_row(app, "historia.txt")
    assert row["ver"] == 4
    current = client.get(f"/files/{row['id']}/download")
    assert current.data == b"version uno"


def test_replace_file_creates_version(app):
    client = make_user(app, "alice", perms=(True, True, False))
    upload(client, "reemplazo.txt", b"original")
    row = file_row(app, "reemplazo.txt")
    response = client.post(
        f"/files/{row['id']}/replace",
        data={
            "file": (io.BytesIO(b"nuevo contenido"), "otro.txt"),
            "ver": "1",
        },
        content_type="multipart/form-data",
    )
    assert response.status_code == 302
    row = file_row(app, "reemplazo.txt")
    assert row["ver"] == 2
    assert client.get(f"/files/{row['id']}/download").data == b"nuevo contenido"


def test_search_and_filter(app):
    client = make_user(app, "alice", perms=(True, True, False))
    upload(client, "informe.txt", b"datos")
    upload(client, "foto.png", PNG_1PX)

    found = client.get("/?q=informe")
    assert "informe.txt" in found.get_data(as_text=True)
    assert "foto.png" not in found.get_data(as_text=True)

    images = client.get("/?kind=image")
    body = images.get_data(as_text=True)
    assert "foto.png" in body
    assert "informe.txt" not in body


def test_duplicate_names_get_suffix(app):
    client = make_user(app, "alice", perms=(True, True, False))
    assert upload(client, "igual.txt", b"uno").status_code == 200
    assert upload(client, "igual.txt", b"dos").status_code == 200
    assert file_row(app, "igual (2).txt") is not None


def test_upload_requires_files(app):
    client = make_user(app, "alice", perms=(True, True, False))
    response = client.post(
        "/files",
        data={},
        headers={"X-Requested-With": "XMLHttpRequest"},
    )
    assert response.status_code == 400
    assert response.get_json()["ok"] is False
