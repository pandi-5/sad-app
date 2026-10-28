"""Utilidades de nombres, archivos, hashing y diferencias."""
from __future__ import annotations

import difflib
import hashlib
import mimetypes
import os
import re
import shutil
import unicodedata
import uuid
from pathlib import Path

from flask import current_app

TEXT_EXTENSIONS = {
    ".txt", ".md", ".markdown", ".rst", ".log", ".csv", ".tsv",
    ".json", ".jsonl", ".xml", ".yaml", ".yml", ".toml", ".ini", ".cfg",
    ".conf", ".env", ".sql", ".py", ".js", ".mjs", ".cjs", ".ts", ".tsx",
    ".jsx", ".css", ".scss", ".html", ".htm", ".sh", ".bash", ".zsh",
    ".c", ".h", ".cpp", ".hpp", ".java", ".go", ".rs", ".rb", ".php",
    ".pl", ".lua", ".r", ".kt", ".swift", ".tex", ".bat", ".ps1",
}

IMAGE_PREVIEW_MIMES = {
    "image/png", "image/jpeg", "image/gif", "image/webp", "image/bmp",
    "image/tiff", "image/x-icon",
}

USERNAME_RE = re.compile(r"^[a-z0-9_-]{2,20}$")
EXTENSION_RE = re.compile(r"^\.[a-z0-9]{1,10}$")


def normalize_username(raw: str) -> str:
    text = unicodedata.normalize("NFKD", (raw or "").strip().lower())
    text = text.encode("ascii", "ignore").decode("ascii")
    text = re.sub(r"[^a-z0-9_-]+", "", text)
    return text[:20]


def valid_username(name: str) -> bool:
    return bool(USERNAME_RE.fullmatch(name or ""))


def clean_display_name(raw: str) -> str:
    raw = (raw or "").replace("\\", "/").split("/")[-1]
    raw = unicodedata.normalize("NFC", raw)
    cleaned = "".join(
        ch for ch in raw if ch.isprintable() and ch not in "\x00\r\n\t"
    )
    cleaned = cleaned.strip().strip(".")
    if not cleaned:
        cleaned = "archivo"
    if len(cleaned) > 120:
        stem, ext = os.path.splitext(cleaned)
        cleaned = stem[: max(1, 120 - len(ext))] + ext[:20]
    return cleaned


def safe_extension(name: str) -> str:
    ext = Path(name).suffix.lower()
    return ext if EXTENSION_RE.fullmatch(ext) else ""


def guess_mime(name: str) -> str:
    mime, _ = mimetypes.guess_type(name)
    return mime or "application/octet-stream"


def unique_display_name(db, name: str, exclude_id: str | None = None) -> str:
    candidate = clean_display_name(name)
    stem, ext = os.path.splitext(candidate)
    counter = 1
    while True:
        if exclude_id:
            row = db.execute(
                "SELECT id FROM files WHERE lower(name)=lower(?) AND id<>?",
                (candidate, exclude_id),
            ).fetchone()
        else:
            row = db.execute(
                "SELECT id FROM files WHERE lower(name)=lower(?)", (candidate,)
            ).fetchone()
        if row is None:
            return candidate
        counter += 1
        candidate = f"{stem} ({counter}){ext}"
        if len(candidate) > 120:
            candidate = f"{stem[:80]} ({counter}){ext}"


def files_dir() -> Path:
    return Path(current_app.config["FILES_DIR"])


def tmp_dir() -> Path:
    return Path(current_app.config["TMP_DIR"])


def versions_dir() -> Path:
    return Path(current_app.config["VERSIONS_DIR"])


def stored_path(stored_name: str) -> Path:
    path = (files_dir() / stored_name).resolve()
    base = files_dir().resolve()
    if base not in path.parents and path != base:
        raise ValueError("Ruta fuera del almacenamiento")
    return path


def version_dir(file_id: str) -> Path:
    path = (versions_dir() / file_id).resolve()
    base = versions_dir().resolve()
    if base not in path.parents and path != base:
        raise ValueError("Ruta fuera del almacenamiento")
    return path


def version_path(file_id: str, stored_name: str) -> Path:
    path = (version_dir(file_id) / stored_name).resolve()
    base = version_dir(file_id)
    if base not in path.parents and path != base:
        raise ValueError("Ruta fuera del almacenamiento")
    return path


def sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_temp_bytes(data: bytes) -> Path:
    tmp_dir().mkdir(parents=True, exist_ok=True)
    path = tmp_dir() / f"{uuid.uuid4().hex}.part"
    with open(path, "wb") as handle:
        handle.write(data)
    return path


def save_stream_to_temp(storage, max_bytes: int):
    """Guarda un FileStorage en temporal sin cargarlo entero en memoria.

    Devuelve (ruta, tamaño, sha256) o lanza ValueError si supera max_bytes.
    """
    tmp_dir().mkdir(parents=True, exist_ok=True)
    path = tmp_dir() / f"{uuid.uuid4().hex}.part"
    digest = hashlib.sha256()
    size = 0
    try:
        with open(path, "wb") as handle:
            while True:
                chunk = storage.stream.read(1024 * 1024)
                if not chunk:
                    break
                size += len(chunk)
                if size > max_bytes:
                    raise ValueError("El archivo supera el tamaño máximo permitido.")
                digest.update(chunk)
                handle.write(chunk)
    except Exception:
        path.unlink(missing_ok=True)
        raise
    return path, size, digest.hexdigest()


def detect_is_text(name: str, path: Path, size: int) -> bool:
    max_bytes = current_app.config["MAX_TEXT_BYTES"]
    if size > max_bytes:
        return False
    try:
        with open(path, "rb") as handle:
            sample = handle.read(65536)
        if b"\x00" in sample:
            return False
        sample.decode("utf-8")
        if size > len(sample):
            with open(path, "rb") as handle:
                handle.read().decode("utf-8")
        return True
    except UnicodeDecodeError:
        return False


def read_text_file(path: Path) -> str:
    max_bytes = current_app.config["MAX_TEXT_BYTES"]
    if path.stat().st_size > max_bytes:
        raise ValueError("El archivo es demasiado grande para editarlo.")
    return path.read_text(encoding="utf-8")


def snapshot_file(file_id: str, ver: int, source: Path) -> tuple[str, int]:
    target_dir = version_dir(file_id)
    target_dir.mkdir(parents=True, exist_ok=True)
    stored_name = f"{ver}.bin"
    target = target_dir / stored_name
    shutil.copy2(source, target)
    return stored_name, target.stat().st_size


def remove_quiet(path: Path) -> None:
    try:
        path.unlink(missing_ok=True)
    except OSError:
        current_app.logger.warning("No se pudo borrar %s", path, exc_info=True)


def remove_version_dir(file_id: str) -> None:
    try:
        shutil.rmtree(version_dir(file_id), ignore_errors=True)
    except OSError:
        current_app.logger.warning("No se pudo borrar versiones de %s", file_id)


def prune_versions(db, file_id: str, keep: int) -> list[Path]:
    """Elimina metadatos de versiones antiguas y devuelve sus rutas en disco.

    Las rutas se borran después del commit para no romper la transacción.
    """
    rows = db.execute(
        "SELECT id, stored_name FROM file_versions WHERE file_id=? "
        "ORDER BY ver DESC",
        (file_id,),
    ).fetchall()
    stale = rows[keep:]
    paths: list[Path] = []
    for row in stale:
        paths.append(version_path(file_id, row["stored_name"]))
        db.execute("DELETE FROM file_versions WHERE id=?", (row["id"],))
    return paths


def is_image(mime: str | None) -> bool:
    return bool(mime) and mime in IMAGE_PREVIEW_MIMES


def human_size(num: int | float | None) -> str:
    value = float(num or 0)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024 or unit == "TB":
            if unit == "B":
                return f"{int(value)} B"
            return f"{value:.1f} {unit}"
        value /= 1024
    return f"{value:.1f} TB"


def build_diff(server_text: str, client_text: str, limit: int = 1200):
    """Diff lado a lado por líneas: (tipo, nº servidor, nº cliente, izq, der)."""
    server = server_text.splitlines()
    client = client_text.splitlines()
    if len(server) + len(client) > 20000:
        return None
    matcher = difflib.SequenceMatcher(a=server, b=client)
    rows = []
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            for offset in range(i2 - i1):
                rows.append(
                    ("equal", i1 + offset + 1, j1 + offset + 1,
                     server[i1 + offset], client[j1 + offset])
                )
        elif tag == "replace":
            count = max(i2 - i1, j2 - j1)
            for offset in range(count):
                left = server[i1 + offset] if i1 + offset < i2 else None
                right = client[j1 + offset] if j1 + offset < j2 else None
                rows.append(
                    ("change",
                     i1 + offset + 1 if left is not None else None,
                     j1 + offset + 1 if right is not None else None,
                     left, right)
                )
        elif tag == "delete":
            for index in range(i1, i2):
                rows.append(("delete", index + 1, None, server[index], None))
        elif tag == "insert":
            for index in range(j1, j2):
                rows.append(("insert", None, index + 1, None, client[index]))
        if len(rows) >= limit:
            rows.append(("truncated", None, None, None, None))
            break
    return rows
