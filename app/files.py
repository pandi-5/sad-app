"""Gestión de archivos: subida, descarga, edición y versiones."""
from __future__ import annotations

import os
import shutil
import time
import uuid
from pathlib import Path

from flask import (
    Blueprint,
    abort,
    current_app,
    flash,
    jsonify,
    redirect,
    render_template,
    request,
    send_file,
    url_for,
)

from .audit import log_event
from .db import get_db, get_mode, write_tx
from .security import client_required, current_user
from .utils import (
    build_diff,
    clean_display_name,
    detect_is_text,
    guess_mime,
    human_size,
    is_image,
    prune_versions,
    read_text_file,
    remove_quiet,
    remove_version_dir,
    safe_extension,
    save_stream_to_temp,
    sha256_bytes,
    sha256_path,
    snapshot_file,
    stored_path,
    unique_display_name,
    version_path,
    write_temp_bytes,
)

bp = Blueprint("files", __name__)

PER_PAGE = 20


class VersionConflict(Exception):
    def __init__(self, row):
        super().__init__("conflicto de versión")
        self.row = row


class LockConflict(Exception):
    pass


# --------------------------------------------------------------------------- #
# Consultas y estado
# --------------------------------------------------------------------------- #

def file_or_404(file_id: str):
    row = get_db().execute("SELECT * FROM files WHERE id=?", (file_id,)).fetchone()
    if row is None:
        abort(404)
    return row


def lock_owner(row) -> str | None:
    if row is None:
        return None
    ttl = current_app.config["LOCK_TTL"]
    if row["lock_user"] and time.time() - row["lock_ts"] < ttl:
        return row["lock_user"]
    return None


def lock_remaining(row) -> int:
    if row is None or not row["lock_user"]:
        return 0
    ttl = current_app.config["LOCK_TTL"]
    return max(0, int(ttl - (time.time() - row["lock_ts"])))


def stored_missing(row) -> bool:
    """True si el archivo físico desapareció del almacenamiento."""
    try:
        return not stored_path(row["stored_name"]).exists()
    except (OSError, ValueError):
        return True


def _versions(file_id: str):
    return get_db().execute(
        "SELECT * FROM file_versions WHERE file_id=? ORDER BY ver DESC",
        (file_id,),
    ).fetchall()


def _stats() -> dict:
    db = get_db()
    row = db.execute(
        "SELECT COUNT(*) AS files, COALESCE(SUM(size),0) AS bytes, "
        "COALESCE(SUM(is_text),0) AS text FROM files"
    ).fetchone()
    images = db.execute(
        "SELECT COUNT(*) AS c FROM files WHERE mime LIKE 'image/%'"
    ).fetchone()["c"]
    locked = db.execute(
        "SELECT COUNT(*) AS c FROM files WHERE lock_user IS NOT NULL AND lock_ts > ?",
        (time.time() - current_app.config["LOCK_TTL"],),
    ).fetchone()["c"]
    return {
        "files": row["files"],
        "bytes": row["bytes"],
        "text": row["text"],
        "images": images,
        "locked": locked,
    }


def _wants_json() -> bool:
    return request.headers.get("X-Requested-With") == "XMLHttpRequest"


def _clean_int(value, default=0):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


# --------------------------------------------------------------------------- #
# Bloqueos
# --------------------------------------------------------------------------- #

def _acquire_lock(file_id: str, user_name: str) -> bool:
    now = time.time()
    ttl = current_app.config["LOCK_TTL"]
    with write_tx() as db:
        cur = db.execute(
            "UPDATE files SET lock_user=?, lock_ts=? WHERE id=? AND "
            "(lock_user IS NULL OR lock_user=? OR lock_ts < ?)",
            (user_name, now, file_id, user_name, now - ttl),
        )
        acquired = cur.rowcount == 1
        if acquired:
            log_event("LOCK", file_id, f"bloqueo de {user_name}")
    return acquired


def _touch_lock(file_id: str, user_name: str) -> bool:
    cur = get_db().execute(
        "UPDATE files SET lock_ts=? WHERE id=? AND lock_user=?",
        (time.time(), file_id, user_name),
    )
    return cur.rowcount == 1


def _valid_lock(row, user_name: str) -> bool:
    return (
        row["lock_user"] == user_name
        and time.time() - row["lock_ts"] < current_app.config["LOCK_TTL"]
    )


def _release_lock(file_id: str, user_name: str) -> bool:
    cur = get_db().execute(
        "UPDATE files SET lock_user=NULL, lock_ts=0 WHERE id=? AND lock_user=?",
        (file_id, user_name),
    )
    return cur.rowcount == 1


# --------------------------------------------------------------------------- #
# Creación y escritura de versiones
# --------------------------------------------------------------------------- #

def _register_new_file(
    db,
    user_name: str,
    display_name: str,
    temp_path: Path,
    size: int,
    digest: str,
    is_text: bool,
    mime: str,
    op: str,
    note: str = "",
):
    file_id = uuid.uuid4().hex
    stored_name = file_id + safe_extension(display_name)
    final = stored_path(stored_name)
    try:
        os.replace(temp_path, final)
        name = unique_display_name(db, display_name)
        now = time.time()
        db.execute(
            "INSERT INTO files(id, name, stored_name, mime, size, hash, is_text, "
            "ver, author, created_at, updated_at, lock_user, lock_ts) "
            "VALUES(?,?,?,?,?,?,?,1,?,?,?,NULL,0)",
            (
                file_id, name, stored_name, mime, size, digest,
                1 if is_text else 0, user_name, now, now,
            ),
        )
        snap_name, snap_size = snapshot_file(file_id, 1, final)
        db.execute(
            "INSERT INTO file_versions(file_id, ver, author, ts, size, hash, "
            "mime, is_text, stored_name, op, note) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
            (
                file_id, 1, user_name, now, snap_size, digest, mime,
                1 if is_text else 0, snap_name, op, note,
            ),
        )
        log_event(op, name, f"v1 · {human_size(size)}" + (f" · {note}" if note else ""))
        return file_id, name
    except Exception:
        remove_quiet(final)
        remove_version_dir(file_id)
        raise


def apply_new_version(
    file_id: str,
    user_name: str,
    temp_path: Path,
    size: int,
    digest: str,
    base_ver: int,
    op: str,
    *,
    mime: str | None = None,
    is_text: bool | None = None,
    note: str = "",
) -> int:
    """Escribe una nueva versión de forma atómica.

    Lanza VersionConflict o LockConflict antes de tocar el archivo final.
    """
    mode = get_mode()
    final = None
    backup = None
    new_ver = None
    prune_paths: list[Path] = []
    try:
        with write_tx() as db:
            fresh = db.execute(
                "SELECT * FROM files WHERE id=?", (file_id,)
            ).fetchone()
            if fresh is None:
                abort(404)
            if mode == "bloqueo" and not _valid_lock(fresh, user_name):
                raise LockConflict()
            if mode == "versiones" and fresh["ver"] != base_ver:
                raise VersionConflict(fresh)
            if mode == "libre" and fresh["ver"] != base_ver:
                db.execute(
                    "INSERT INTO log(ts, usr, ip, op, file, info) "
                    "VALUES(?,?,?,?,?,?)",
                    (
                        time.time(), user_name, request.remote_addr,
                        "SOBRESCRITURA", fresh["name"],
                        f"pisó la v{fresh['ver']} de {fresh['author']} "
                        f"(editó desde v{base_ver})",
                    ),
                )

            new_ver = fresh["ver"] + 1
            final = stored_path(fresh["stored_name"])
            if final.exists():
                backup = Path(current_app.config["TMP_DIR"]) / f"{uuid.uuid4().hex}.bak"
                shutil.copy2(final, backup)

            now = time.time()
            keep_lock = mode == "bloqueo"
            cur = db.execute(
                "UPDATE files SET ver=?, author=?, size=?, hash=?, mime=?, "
                "is_text=?, updated_at=?, lock_user=?, lock_ts=? "
                "WHERE id=? AND ver=?",
                (
                    new_ver, user_name, size, digest,
                    mime if mime is not None else fresh["mime"],
                    1 if (is_text if is_text is not None else fresh["is_text"]) else 0,
                    now,
                    user_name if keep_lock else None,
                    now if keep_lock else 0,
                    file_id, fresh["ver"],
                ),
            )
            if cur.rowcount != 1:
                raise VersionConflict(fresh)

            os.replace(temp_path, final)
            snap_name, snap_size = snapshot_file(file_id, new_ver, final)
            db.execute(
                "INSERT INTO file_versions(file_id, ver, author, ts, size, hash, "
                "mime, is_text, stored_name, op, note) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                (
                    file_id, new_ver, user_name, now, snap_size, digest,
                    mime if mime is not None else fresh["mime"],
                    1 if (is_text if is_text is not None else fresh["is_text"]) else 0,
                    snap_name, op, note,
                ),
            )
            prune_paths = prune_versions(
                db, file_id, current_app.config["MAX_VERSIONS"]
            )
            log_event(
                op, fresh["name"],
                f"v{new_ver}" + (f" · {note}" if note else ""),
            )
    except Exception:
        if final is not None and backup is not None and backup.exists():
            os.replace(backup, final)
        elif final is not None and backup is None:
            remove_quiet(final)
        remove_quiet(temp_path)
        if backup is not None:
            remove_quiet(backup)
        if new_ver is not None:
            remove_quiet(version_path(file_id, new_ver))
        raise
    else:
        remove_quiet(backup)
        for path in prune_paths:
            remove_quiet(path)
        return new_ver


def _delete_file_record(file_id: str, actor: str, *, bypass: bool = False):
    row = get_db().execute("SELECT * FROM files WHERE id=?", (file_id,)).fetchone()
    if row is None:
        return False, "El archivo no existe."
    owner = lock_owner(row)
    if not bypass and owner and owner != actor:
        return False, f"El archivo está bloqueado por {owner}."
    path = stored_path(row["stored_name"])
    with write_tx() as db:
        db.execute("DELETE FROM files WHERE id=?", (file_id,))
        log_event("DELETE", row["name"], f"por {actor}")
    remove_quiet(path)
    remove_version_dir(file_id)
    return True, f"Archivo «{row['name']}» eliminado."


# --------------------------------------------------------------------------- #
# Listado
# --------------------------------------------------------------------------- #

@bp.get("/")
def index():
    user = current_user()
    if user is None:
        return render_template("auth/login.html")

    q = request.args.get("q", "").strip()[:100]
    kind = request.args.get("kind", "")
    sort = request.args.get("sort", "updated")
    order = request.args.get("order", "desc")
    if sort not in {"name", "updated", "size", "ver"}:
        sort = "updated"
    if order not in {"asc", "desc"}:
        order = "desc"

    where, params = [], []
    if q:
        escaped = q.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
        where.append("name LIKE ? ESCAPE '\\'")
        params.append(f"%{escaped}%")
    if kind == "text":
        where.append("is_text=1")
    elif kind == "image":
        where.append("mime LIKE 'image/%'")
    elif kind == "other":
        where.append("(is_text=0 AND (mime IS NULL OR mime NOT LIKE 'image/%'))")
    where_sql = f" WHERE {' AND '.join(where)}" if where else ""

    db = get_db()
    total = db.execute(
        f"SELECT COUNT(*) AS c FROM files{where_sql}", params
    ).fetchone()["c"]
    pages = max(1, (total + PER_PAGE - 1) // PER_PAGE)
    page = min(max(1, _clean_int(request.args.get("page"), 1)), pages)
    sort_column = {
        "name": "name",
        "updated": "updated_at",
        "size": "size",
        "ver": "ver",
    }[sort]
    rows = db.execute(
        f"SELECT * FROM files{where_sql} ORDER BY {sort_column} {order}, name "
        "LIMIT ? OFFSET ?",
        params + [PER_PAGE, (page - 1) * PER_PAGE],
    ).fetchall()
    files = [
        dict(
            row,
            owner=lock_owner(row),
            image=is_image(row["mime"]),
            remaining=lock_remaining(row),
            missing=stored_missing(row),
        )
        for row in rows
    ]
    return render_template(
        "files/index.html",
        u=user,
        files=files,
        stats=_stats(),
        mode=get_mode(),
        q=q,
        kind=kind,
        sort=sort,
        order=order,
        page=page,
        pages=pages,
        total=total,
    )


# --------------------------------------------------------------------------- #
# Subida
# --------------------------------------------------------------------------- #

@bp.post("/files")
@client_required("w")
def upload(user):
    uploads = [item for item in request.files.getlist("files") if item.filename]
    errors: list[str] = []
    uploaded: list[str] = []
    max_bytes = current_app.config["MAX_UPLOAD_MB"] * 1024 * 1024

    if not uploads:
        errors.append("Selecciona al menos un archivo.")
    elif len(uploads) > current_app.config["MAX_FILES_PER_UPLOAD"]:
        errors.append(
            "Solo se pueden subir "
            f"{current_app.config['MAX_FILES_PER_UPLOAD']} archivos por vez."
        )
        uploads = []

    for storage in uploads:
        display = clean_display_name(storage.filename)
        try:
            temp, size, digest = save_stream_to_temp(storage, max_bytes)
        except ValueError as exc:
            errors.append(f"{display}: {exc}")
            continue
        except OSError:
            current_app.logger.exception("Error guardando temporal")
            errors.append(f"{display}: no se pudo leer el archivo.")
            continue

        try:
            is_text = detect_is_text(display, temp, size)
            mime = guess_mime(display)
            with write_tx() as db:
                _, name = _register_new_file(
                    db, user["name"], display, temp, size, digest, is_text, mime,
                    "UPLOAD",
                )
            uploaded.append(name)
        except Exception:
            current_app.logger.exception("Error registrando archivo")
            remove_quiet(temp)
            errors.append(f"{display}: no se pudo guardar.")
        finally:
            remove_quiet(temp)

    if _wants_json():
        status = 200 if uploaded and not errors else (207 if uploaded else 400)
        return (
            jsonify(
                ok=bool(uploaded),
                uploaded=uploaded,
                errors=errors,
                max_mb=current_app.config["MAX_UPLOAD_MB"],
            ),
            status,
        )

    for message in errors:
        flash(message, "error")
    if uploaded:
        flash(
            f"{len(uploaded)} archivo(s) subido(s): " + ", ".join(uploaded),
            "success",
        )
    return redirect(url_for("files.index"))


# --------------------------------------------------------------------------- #
# Ver, descargar y previsualizar
# --------------------------------------------------------------------------- #

@bp.get("/files/<file_id>")
@client_required("r")
def view(user, file_id):
    row = file_or_404(file_id)
    mode = get_mode()
    if row["is_text"]:
        if mode == "bloqueo" and user["w"]:
            if _acquire_lock(file_id, user["name"]):
                row = file_or_404(file_id)
        log_event("READ", row["name"], f"v{row['ver']}")
        return _render_editor(user, row)
    log_event("READ", row["name"], f"v{row['ver']}")
    return _render_detail(user, row)


def _render_editor(
    user,
    row,
    *,
    text: str | None = None,
    error: str | None = None,
    conflict: bool = False,
    server_text: str | None = None,
    diff_rows=None,
    status: int = 200,
    acquire_lock: bool = False,
):
    mode = get_mode()
    if acquire_lock and mode == "bloqueo" and user["w"]:
        if _acquire_lock(row["id"], user["name"]):
            row = file_or_404(row["id"])
    owner = lock_owner(row)
    can_edit = bool(user["w"]) and (
        mode != "bloqueo" or owner == user["name"]
    )
    if text is None:
        try:
            text = read_text_file(stored_path(row["stored_name"]))
        except (OSError, ValueError):
            text = ""
            error = error or "No se pudo leer el contenido del archivo."
    return (
        render_template(
            "files/edit.html",
            u=user,
            f=row,
            text=text,
            mode=mode,
            owner=owner,
            remaining=lock_remaining(row),
            can_edit=can_edit,
            versions=_versions(row["id"]),
            error=error,
            conflict=conflict,
            server_text=server_text,
            diff_rows=diff_rows,
        ),
        status,
    )


def _render_detail(user, row, *, error: str | None = None, status: int = 200):
    mode = get_mode()
    owner = lock_owner(row)
    return (
        render_template(
            "files/detail.html",
            u=user,
            f=row,
            mode=mode,
            owner=owner,
            remaining=lock_remaining(row),
            can_replace=bool(user["w"])
            and (mode != "bloqueo" or owner == user["name"]),
            image=is_image(row["mime"]),
            versions=_versions(row["id"]),
            error=error,
        ),
        status,
    )


@bp.get("/files/<file_id>/download")
@client_required("r")
def download(user, file_id):
    row = file_or_404(file_id)
    path = stored_path(row["stored_name"])
    if not path.exists():
        abort(404)
    log_event("DOWNLOAD", row["name"], f"v{row['ver']}")
    return send_file(
        path,
        mimetype=row["mime"] or "application/octet-stream",
        as_attachment=True,
        download_name=row["name"],
        conditional=True,
        max_age=0,
    )


@bp.get("/files/<file_id>/preview")
@client_required("r")
def preview(user, file_id):
    row = file_or_404(file_id)
    if not is_image(row["mime"]):
        abort(404)
    path = stored_path(row["stored_name"])
    if not path.exists():
        abort(404)
    response = send_file(
        path,
        mimetype=row["mime"],
        as_attachment=False,
        download_name=row["name"],
        conditional=True,
        max_age=0,
    )
    safe_name = row["name"].replace('"', "")
    response.headers["Content-Disposition"] = f'inline; filename="{safe_name}"'
    return response


@bp.get("/files/<file_id>/versions/<int:ver>/download")
@client_required("r")
def download_version(user, file_id, ver):
    row = file_or_404(file_id)
    version = get_db().execute(
        "SELECT * FROM file_versions WHERE file_id=? AND ver=?",
        (file_id, ver),
    ).fetchone()
    if version is None:
        abort(404)
    path = version_path(file_id, version["stored_name"])
    if not path.exists():
        abort(404)
    log_event("DOWNLOAD_VERSION", row["name"], f"v{ver}")
    return send_file(
        path,
        mimetype=version["mime"] or "application/octet-stream",
        as_attachment=True,
        download_name=f"{row['name']} (v{ver})",
        conditional=True,
        max_age=0,
    )


# --------------------------------------------------------------------------- #
# Escritura
# --------------------------------------------------------------------------- #

@bp.post("/files/<file_id>/save")
@client_required("w")
def save(user, file_id):
    row = file_or_404(file_id)
    if not row["is_text"]:
        abort(400, description="Este archivo no es de texto y no se puede editar.")

    text = request.form.get("text", "")
    base_ver = _clean_int(request.form.get("ver"), 0)
    data = text.encode("utf-8")
    if len(data) > current_app.config["MAX_TEXT_BYTES"]:
        return _render_editor(
            user,
            row,
            text=text,
            error=(
                "El texto supera el límite de "
                f"{current_app.config['MAX_TEXT_BYTES'] // 1024} KB."
            ),
            status=413,
        )

    temp = write_temp_bytes(data)
    try:
        new_ver = apply_new_version(
            file_id,
            user["name"],
            temp,
            len(data),
            sha256_bytes(data),
            base_ver,
            "WRITE",
        )
    except VersionConflict as conflict:
        server_text = read_text_file(stored_path(conflict.row["stored_name"]))
        return _render_editor(
            user,
            conflict.row,
            text=text,
            conflict=True,
            server_text=server_text,
            diff_rows=build_diff(server_text, text),
            error=(
                f"Conflicto: {conflict.row['author']} guardó la "
                f"v{conflict.row['ver']} mientras editabas. Elige qué hacer."
            ),
            status=409,
        )
    except LockConflict:
        log_event("RECHAZADO", row["name"], "no tenía el bloqueo")
        return _render_editor(
            user,
            row,
            text=text,
            error=(
                "No puedes guardar: otro usuario tiene el archivo bloqueado "
                "o tu bloqueo caducó. Vuelve a abrirlo."
            ),
            status=409,
        )

    flash(f"Cambios guardados en la versión {new_ver}.", "success")
    return redirect(url_for("files.view", file_id=file_id))


@bp.post("/files/<file_id>/save-copy")
@client_required("w")
def save_copy(user, file_id):
    row = file_or_404(file_id)
    if not row["is_text"]:
        abort(400)
    text = request.form.get("text", "")
    data = text.encode("utf-8")
    if len(data) > current_app.config["MAX_TEXT_BYTES"]:
        flash("El texto supera el límite permitido.", "error")
        return redirect(url_for("files.view", file_id=file_id))

    stem, ext = os.path.splitext(row["name"])
    display = f"{stem} (copia){ext}"
    temp = write_temp_bytes(data)
    try:
        with write_tx() as db:
            new_id, _ = _register_new_file(
                db, user["name"], display, temp, len(data), sha256_bytes(data),
                True, row["mime"] or "text/plain", "COPY",
                note=f"copia de {row['name']} v{row['ver']}",
            )
    except Exception:
        current_app.logger.exception("Error guardando copia")
        remove_quiet(temp)
        flash("No se pudo guardar la copia.", "error")
        return redirect(url_for("files.view", file_id=file_id))

    flash("Se guardó una copia independiente de tu texto.", "success")
    return redirect(url_for("files.view", file_id=new_id))


@bp.post("/files/<file_id>/replace")
@client_required("w")
def replace(user, file_id):
    row = file_or_404(file_id)
    storage = request.files.get("file")
    if storage is None or not storage.filename:
        flash("Selecciona un archivo para reemplazar.", "error")
        return redirect(url_for("files.view", file_id=file_id))
    base_ver = _clean_int(request.form.get("ver"), row["ver"])
    max_bytes = current_app.config["MAX_UPLOAD_MB"] * 1024 * 1024
    try:
        temp, size, digest = save_stream_to_temp(storage, max_bytes)
    except ValueError as exc:
        flash(str(exc), "error")
        return redirect(url_for("files.view", file_id=file_id))

    display = row["name"]
    try:
        is_text = detect_is_text(display, temp, size)
        mime = guess_mime(display)
        new_ver = apply_new_version(
            file_id,
            user["name"],
            temp,
            size,
            digest,
            base_ver,
            "REPLACE",
            mime=mime,
            is_text=is_text,
        )
    except VersionConflict as conflict:
        flash(
            f"Conflicto: el archivo ya iba por la v{conflict.row['ver']} de "
            f"{conflict.row['author']}. Vuelve a subir tu reemplazo.",
            "error",
        )
        return redirect(url_for("files.view", file_id=file_id))
    except LockConflict:
        flash(
            "No puedes reemplazar: el archivo está bloqueado por otro usuario.",
            "error",
        )
        return redirect(url_for("files.view", file_id=file_id))

    flash(f"Archivo reemplazado. Nueva versión: v{new_ver}.", "success")
    return redirect(url_for("files.view", file_id=file_id))


@bp.post("/files/<file_id>/versions/<int:ver>/restore")
@client_required("w")
def restore_version(user, file_id, ver):
    row = file_or_404(file_id)
    version = get_db().execute(
        "SELECT * FROM file_versions WHERE file_id=? AND ver=?",
        (file_id, ver),
    ).fetchone()
    if version is None:
        abort(404)
    path = version_path(file_id, version["stored_name"])
    if not path.exists():
        flash("La copia de esa versión ya no está disponible.", "error")
        return redirect(url_for("files.view", file_id=file_id))

    base_ver = _clean_int(request.form.get("ver"), row["ver"])
    temp = Path(current_app.config["TMP_DIR"]) / f"{uuid.uuid4().hex}.part"
    shutil.copy2(path, temp)
    size = temp.stat().st_size
    digest = sha256_path(temp)
    try:
        new_ver = apply_new_version(
            file_id,
            user["name"],
            temp,
            size,
            digest,
            base_ver,
            "RESTORE",
            mime=version["mime"],
            is_text=bool(version["is_text"]),
            note=f"restaurada desde v{ver}",
        )
    except VersionConflict as conflict:
        flash(
            f"Conflicto: el archivo ya iba por la v{conflict.row['ver']}.",
            "error",
        )
        return redirect(url_for("files.view", file_id=file_id))
    except LockConflict:
        flash("No puedes restaurar: el archivo está bloqueado.", "error")
        return redirect(url_for("files.view", file_id=file_id))

    flash(f"Versión {ver} restaurada como v{new_ver}.", "success")
    return redirect(url_for("files.view", file_id=file_id))


@bp.post("/files/<file_id>/rename")
@client_required("w")
def rename(user, file_id):
    row = file_or_404(file_id)
    owner = lock_owner(row)
    if owner and owner != user["name"]:
        flash(f"No puedes renombrar: el archivo está bloqueado por {owner}.", "error")
        return redirect(url_for("files.view", file_id=file_id))
    new_name = clean_display_name(request.form.get("name", ""))
    if not new_name:
        flash("El nombre no puede estar vacío.", "error")
        return redirect(url_for("files.view", file_id=file_id))
    with write_tx() as db:
        unique = unique_display_name(db, new_name, exclude_id=file_id)
        db.execute("UPDATE files SET name=? WHERE id=?", (unique, file_id))
        log_event("RENAME", row["name"], f"nuevo nombre: {unique}")
    flash(f"Archivo renombrado a «{unique}».", "success")
    return redirect(url_for("files.index"))


@bp.post("/files/<file_id>/delete")
@client_required("d")
def delete(user, file_id):
    ok, message = _delete_file_record(file_id, user["name"])
    flash(message, "success" if ok else "error")
    return redirect(url_for("files.index"))


# --------------------------------------------------------------------------- #
# API de bloqueo / estado
# --------------------------------------------------------------------------- #

@bp.post("/files/<file_id>/lock")
@client_required("w")
def lock(user, file_id):
    row = file_or_404(file_id)
    if get_mode() != "bloqueo":
        flash("El bloqueo solo se usa en el modo «Con bloqueo».", "warning")
        return redirect(url_for("files.view", file_id=file_id))
    if _acquire_lock(file_id, user["name"]):
        flash("Archivo reservado para ti.", "success")
    else:
        fresh = file_or_404(file_id)
        flash(f"Está bloqueado por {lock_owner(fresh) or 'otro usuario'}.", "error")
    return redirect(url_for("files.view", file_id=file_id))


@bp.post("/files/<file_id>/unlock")
@client_required("w")
def unlock(user, file_id):
    file_or_404(file_id)
    if _release_lock(file_id, user["name"]):
        log_event("UNLOCK", file_id, "liberado por su dueño")
        flash("Bloqueo liberado.", "success")
    return redirect(url_for("files.index"))


@bp.post("/files/<file_id>/lock/heartbeat")
@client_required("w")
def heartbeat(user, file_id):
    row = file_or_404(file_id)
    ok = _touch_lock(file_id, user["name"])
    fresh = file_or_404(file_id)
    return jsonify(
        ok=ok,
        owner=lock_owner(fresh),
        remaining=lock_remaining(fresh),
        ver=fresh["ver"],
        author=fresh["author"],
        mode=get_mode(),
    )


@bp.get("/api/files/<file_id>/status")
@client_required("r")
def status(user, file_id):
    row = file_or_404(file_id)
    owner = lock_owner(row)
    mode = get_mode()
    return jsonify(
        id=row["id"],
        ver=row["ver"],
        author=row["author"],
        mode=mode,
        owner=owner,
        remaining=lock_remaining(row),
        can_edit=bool(user["w"]) and (mode != "bloqueo" or owner == user["name"]),
    )
