"""Panel del coordinador: modo, usuarios, archivos y auditoría."""
from __future__ import annotations

import secrets
import time

from flask import (
    Blueprint,
    abort,
    current_app,
    flash,
    jsonify,
    redirect,
    render_template,
    request,
    url_for,
)
from werkzeug.security import generate_password_hash

from .audit import log_event
from .config import MODES
from .db import get_db, get_mode, set_mode, write_tx
from .files import _delete_file_record, lock_owner, lock_remaining, stored_missing
from .security import admin_required
from .utils import is_image

bp = Blueprint("admin", __name__, url_prefix="/admin")

LOG_PER_PAGE = 50


def _online(seen: float | None) -> bool:
    return bool(seen) and time.time() - seen < current_app.config["ONLINE_WINDOW"]


def _users():
    rows = get_db().execute(
        "SELECT * FROM users ORDER BY seen DESC, name"
    ).fetchall()
    return [dict(row, online=_online(row["seen"])) for row in rows]


def _files():
    rows = get_db().execute(
        "SELECT f.*, (SELECT COUNT(*) FROM file_versions v WHERE v.file_id=f.id) "
        "AS versions FROM files f ORDER BY f.updated_at DESC"
    ).fetchall()
    return [
        dict(
            row,
            owner=lock_owner(row),
            remaining=lock_remaining(row),
            image=is_image(row["mime"]),
            missing=stored_missing(row),
        )
        for row in rows
    ]


def _log_query():
    op = request.args.get("op", "").strip()
    user = request.args.get("user", "").strip()
    q = request.args.get("q", "").strip()[:100]
    where, params = [], []
    if op:
        where.append("op=?")
        params.append(op)
    if user:
        where.append("usr=?")
        params.append(user)
    if q:
        escaped = q.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
        where.append("(file LIKE ? ESCAPE '\\' OR info LIKE ? ESCAPE '\\')")
        params.extend([f"%{escaped}%", f"%{escaped}%"])
    where_sql = f" WHERE {' AND '.join(where)}" if where else ""
    db = get_db()
    total = db.execute(
        f"SELECT COUNT(*) AS c FROM log{where_sql}", params
    ).fetchone()["c"]
    pages = max(1, (total + LOG_PER_PAGE - 1) // LOG_PER_PAGE)
    try:
        page = min(max(1, int(request.args.get("page", 1))), pages)
    except ValueError:
        page = 1
    rows = db.execute(
        f"SELECT * FROM log{where_sql} ORDER BY ts DESC, id DESC LIMIT ? OFFSET ?",
        params + [LOG_PER_PAGE, (page - 1) * LOG_PER_PAGE],
    ).fetchall()
    return rows, total, page, pages, op, user, q


@bp.get("")
@admin_required
def panel():
    users = _users()
    files = _files()
    logs, log_total, log_page, log_pages, op, user, q = _log_query()
    ops = [
        row["op"]
        for row in get_db().execute(
            "SELECT DISTINCT op FROM log ORDER BY op"
        ).fetchall()
    ]
    stats = {
        "files": len(files),
        "bytes": sum(row["size"] for row in files),
        "text": sum(1 for row in files if row["is_text"]),
        "images": sum(1 for row in files if row["image"]),
        "online": sum(1 for row in users if row["online"]),
        "users": len(users),
    }
    return render_template(
        "admin/panel.html",
        users=users,
        files=files,
        logs=logs,
        log_total=log_total,
        log_page=log_page,
        log_pages=log_pages,
        log_op=op,
        log_user=user,
        log_q=q,
        ops=ops,
        stats=stats,
        mode=get_mode(),
        modes=MODES,
    )


@bp.get("/status")
@admin_required
def status():
    users = _users()
    files = _files()
    now = time.time()
    return jsonify(
        now=now,
        online_window=current_app.config["ONLINE_WINDOW"],
        stats={
            "files": len(files),
            "bytes": sum(row["size"] for row in files),
            "text": sum(1 for row in files if row["is_text"]),
            "images": sum(1 for row in files if row["image"]),
            "online": sum(1 for row in users if row["online"]),
            "users": len(users),
        },
        users=[
            {
                "name": row["name"],
                "online": row["online"],
                "seen": row["seen"],
                "ip": row["ip"],
            }
            for row in users
        ],
        files=[
            {
                "id": row["id"],
                "owner": row["owner"],
                "remaining": row["remaining"],
                "ver": row["ver"],
                "author": row["author"],
                "versions": row["versions"],
            }
            for row in files
        ],
    )


@bp.post("/mode")
@admin_required
def change_mode():
    mode = request.form.get("mode", "")
    if mode not in MODES:
        abort(400, description="Modo de concurrencia desconocido.")
    set_mode(mode)
    log_event("MODO", "", mode)
    flash(f"Modo de concurrencia cambiado a «{MODES[mode]['label']}».", "success")
    return redirect(url_for("admin.panel"))


@bp.post("/users/<name>/perms")
@admin_required
def permissions(name):
    row = get_db().execute("SELECT * FROM users WHERE name=?", (name,)).fetchone()
    if row is None:
        abort(404)
    form = request.form
    r, w, d = ("r" in form), ("w" in form), ("d" in form)
    with write_tx() as db:
        db.execute(
            "UPDATE users SET r=?, w=?, d=? WHERE name=?",
            (int(r), int(w), int(d), name),
        )
        if not w:
            db.execute(
                "UPDATE files SET lock_user=NULL, lock_ts=0 WHERE lock_user=?",
                (name,),
            )
    log_event(
        "PERMISOS", name,
        f"leer={int(r)} escribir={int(w)} borrar={int(d)}",
    )
    flash(f"Permisos de {name} actualizados.", "success")
    return redirect(url_for("admin.panel") + "#usuarios")


@bp.post("/users/<name>/reset-password")
@admin_required
def reset_password(name):
    row = get_db().execute("SELECT * FROM users WHERE name=?", (name,)).fetchone()
    if row is None:
        abort(404)
    temporary = secrets.token_urlsafe(9)
    with write_tx() as db:
        db.execute(
            "UPDATE users SET password_hash=?, session_epoch=session_epoch+1 "
            "WHERE name=?",
            (generate_password_hash(temporary), name),
        )
        db.execute(
            "UPDATE files SET lock_user=NULL, lock_ts=0 WHERE lock_user=?", (name,)
        )
    log_event("RESET_PASS", name, "contraseña temporal generada")
    flash(
        f"Contraseña temporal de {name}: {temporary} — cópiala ahora, no se "
        "volverá a mostrar.",
        "warning",
    )
    return redirect(url_for("admin.panel") + "#usuarios")


@bp.post("/users/<name>/active")
@admin_required
def set_active(name):
    row = get_db().execute("SELECT * FROM users WHERE name=?", (name,)).fetchone()
    if row is None:
        abort(404)
    active = not bool(row["active"])
    with write_tx() as db:
        db.execute(
            "UPDATE users SET active=?, session_epoch=session_epoch+1 WHERE name=?",
            (int(active), name),
        )
        if not active:
            db.execute(
                "UPDATE files SET lock_user=NULL, lock_ts=0 WHERE lock_user=?",
                (name,),
            )
    log_event("CUENTA", name, "activada" if active else "desactivada")
    flash(
        f"Cuenta de {name} {'activada' if active else 'desactivada'}.",
        "success",
    )
    return redirect(url_for("admin.panel") + "#usuarios")


@bp.post("/files/<file_id>/unlock")
@admin_required
def force_unlock(file_id):
    row = get_db().execute("SELECT * FROM files WHERE id=?", (file_id,)).fetchone()
    if row is None:
        abort(404)
    owner = lock_owner(row)
    with write_tx() as db:
        db.execute(
            "UPDATE files SET lock_user=NULL, lock_ts=0 WHERE id=?", (file_id,)
        )
    log_event("FORCE_UNLOCK", row["name"], f"dueño anterior: {owner or '-'}")
    flash(f"Bloqueo de «{row['name']}» liberado.", "success")
    return redirect(url_for("admin.panel") + "#archivos")


@bp.post("/files/<file_id>/delete")
@admin_required
def delete_file(file_id):
    ok, message = _delete_file_record(
        file_id, current_app.config["ADMIN_USER"], bypass=True
    )
    flash(message, "success" if ok else "error")
    return redirect(url_for("admin.panel") + "#archivos")
