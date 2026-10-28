"""Autenticación de sesión, permisos, CSRF y cabeceras de seguridad."""
from __future__ import annotations

import time
from functools import wraps

from flask import (
    abort,
    current_app,
    g,
    redirect,
    render_template,
    request,
    session,
    url_for,
)
from flask_wtf.csrf import CSRFError, CSRFProtect

from .audit import log_event
from .db import get_db, write_tx

csrf = CSRFProtect()


def current_user():
    """Usuario cliente de la sesión, o None. Actualiza presencia."""
    if "user_loaded" in g:
        return g.current_user
    g.user_loaded = True
    g.current_user = None

    name = session.get("u")
    if not name:
        return None
    if session.get("is_admin"):
        if name == current_app.config["ADMIN_USER"]:
            # El coordinador no vive en la tabla users, pero puede usar el
            # espacio de archivos con todos los permisos.
            g.current_user = {
                "name": name,
                "r": 1,
                "w": 1,
                "d": 1,
                "active": 1,
                "session_epoch": 0,
                "last_login": 0,
                "seen": time.time(),
            }
        return g.current_user

    row = get_db().execute(
        "SELECT * FROM users WHERE name=?", (name,)
    ).fetchone()
    if row is None or not row["active"]:
        if row is not None:
            log_event("SESION_INVALIDA", "", "cuenta desactivada")
        session.clear()
        return None

    if int(session.get("epoch", 0)) != int(row["session_epoch"]):
        log_event("SESION_INVALIDA", "", "sesión revocada")
        session.clear()
        return None

    now = time.time()
    if now - (row["seen"] or 0) > 5:
        get_db().execute(
            "UPDATE users SET seen=?, ip=? WHERE name=?",
            (now, request.remote_addr, name),
        )
        row = get_db().execute(
            "SELECT * FROM users WHERE name=?", (name,)
        ).fetchone()
    g.current_user = row
    return row


def is_admin_session() -> bool:
    return bool(
        session.get("is_admin")
        and session.get("u") == current_app.config["ADMIN_USER"]
    )


def login_required(view):
    @wraps(view)
    def wrapper(*args, **kwargs):
        if not current_user() and not is_admin_session():
            return redirect(url_for("files.index"))
        return view(*args, **kwargs)

    return wrapper


def client_required(flag: str | None = None):
    def decorator(view):
        @wraps(view)
        def wrapper(*args, **kwargs):
            user = current_user()
            if user is None:
                if is_admin_session():
                    return redirect(url_for("admin.panel"))
                return redirect(url_for("files.index"))
            if flag and not user[flag]:
                log_event(
                    "DENEGADO",
                    request.path,
                    f"requiere permiso {flag.upper()}",
                )
                abort(
                    403,
                    description=(
                        "Tu usuario no tiene permiso para esa operación. "
                        "Pídeselo al coordinador."
                    ),
                )
            return view(user, *args, **kwargs)

        return wrapper

    return decorator


def admin_required(view):
    @wraps(view)
    def wrapper(*args, **kwargs):
        if not is_admin_session():
            if session.get("u"):
                abort(403, description="Solo el coordinador puede entrar aquí.")
            return redirect(url_for("files.index"))
        return view(*args, **kwargs)

    return wrapper


def attempt_key(name: str) -> str:
    return f"{request.remote_addr or '-'}|{name}"


def login_retry_after(key: str) -> int:
    row = get_db().execute(
        "SELECT * FROM login_attempts WHERE key=?", (key,)
    ).fetchone()
    if row is None:
        return 0
    window = current_app.config["LOGIN_WINDOW"]
    now = time.time()
    if now - row["first_ts"] >= window:
        return 0
    if row["count"] < current_app.config["LOGIN_MAX_ATTEMPTS"]:
        return 0
    return max(1, int(window - (now - row["first_ts"])))


def record_login_failure(key: str) -> None:
    now = time.time()
    window = current_app.config["LOGIN_WINDOW"]
    with write_tx() as db:
        row = db.execute(
            "SELECT * FROM login_attempts WHERE key=?", (key,)
        ).fetchone()
        if row is None or now - row["first_ts"] >= window:
            db.execute(
                "INSERT INTO login_attempts(key, count, first_ts, last_ts) "
                "VALUES(?,?,?,?) ON CONFLICT(key) DO UPDATE SET "
                "count=1, first_ts=excluded.first_ts, last_ts=excluded.last_ts",
                (key, 1, now, now),
            )
        else:
            db.execute(
                "UPDATE login_attempts SET count=count+1, last_ts=? WHERE key=?",
                (now, key),
            )


def clear_login_failures(key: str) -> None:
    get_db().execute("DELETE FROM login_attempts WHERE key=?", (key,))


def _security_headers(response):
    response.headers.setdefault(
        "Content-Security-Policy",
        "default-src 'self'; img-src 'self' data:; style-src 'self'; "
        "script-src 'self'; font-src 'self'; connect-src 'self'; "
        "form-action 'self'; base-uri 'self'; frame-ancestors 'none'",
    )
    response.headers.setdefault("X-Frame-Options", "DENY")
    response.headers.setdefault("X-Content-Type-Options", "nosniff")
    response.headers.setdefault("Referrer-Policy", "same-origin")
    response.headers.setdefault(
        "Permissions-Policy", "camera=(), microphone=(), geolocation=()"
    )
    if response.mimetype == "text/html":
        response.headers.setdefault("Cache-Control", "no-store")
    return response


def _touch_session():
    if request.endpoint == "static":
        return
    if session.get("u"):
        session.permanent = True
        session.modified = True


def install_security(app) -> None:
    csrf.init_app(app)
    app.before_request(_touch_session)
    app.after_request(_security_headers)

    @app.errorhandler(CSRFError)
    def handle_csrf(error):
        try:
            log_event("CSRF", request.path, error.description[:200])
        except Exception:
            pass
        return (
            render_template(
                "errors/400.html",
                message=(
                    "La solicitud no incluía un token de seguridad válido. "
                    "Recarga la página e inténtalo de nuevo."
                ),
            ),
            400,
        )

    @app.errorhandler(400)
    def handle_400(error):
        return (
            render_template(
                "errors/400.html", message=getattr(error, "description", None)
            ),
            400,
        )

    @app.errorhandler(403)
    def handle_403(error):
        return (
            render_template(
                "errors/403.html",
                message=getattr(error, "description", None),
            ),
            403,
        )

    @app.errorhandler(404)
    def handle_404(error):
        return render_template("errors/404.html"), 404

    @app.errorhandler(413)
    def handle_413(error):
        limit = current_app.config["MAX_UPLOAD_MB"]
        return (
            render_template(
                "errors/413.html",
                message=f"El envío supera el límite de {limit} MB.",
            ),
            413,
        )

    @app.errorhandler(500)
    def handle_500(error):
        current_app.logger.exception("Error interno", exc_info=error)
        return render_template("errors/500.html"), 500
