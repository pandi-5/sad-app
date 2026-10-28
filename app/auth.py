"""Registro, inicio de sesión y gestión de contraseñas."""
from __future__ import annotations

import time

from flask import (
    Blueprint,
    current_app,
    flash,
    redirect,
    render_template,
    request,
    session,
    url_for,
)
from werkzeug.security import check_password_hash, generate_password_hash

from .audit import log_event
from .db import get_db, write_tx
from .security import (
    attempt_key,
    clear_login_failures,
    current_user,
    is_admin_session,
    login_required,
    login_retry_after,
    record_login_failure,
)
from .utils import normalize_username, valid_username

bp = Blueprint("auth", __name__)


def _login_page(**kwargs):
    return render_template("auth/login.html", **kwargs)


@bp.post("/login")
def login():
    name = normalize_username(request.form.get("name", ""))
    password = request.form.get("password", "")

    if not name or not password:
        return _login_page(
            login_error="Escribe tu usuario y tu contraseña.", login_name=name
        )

    key = attempt_key(name)
    retry = login_retry_after(key)
    if retry:
        log_event("LOGIN_BLOQUEADO", "", f"usuario={name} reintento={retry}s")
        return (
            _login_page(
                login_error=(
                    "Demasiados intentos fallidos. Espera "
                    f"{retry} segundos antes de volver a probar."
                ),
                login_name=name,
            ),
            429,
        )

    if name == current_app.config["ADMIN_USER"]:
        expected = current_app.config.get("ADMIN_PASS_HASH", "")
        if expected and check_password_hash(expected, password):
            session.clear()
            session.permanent = True
            session["u"] = name
            session["is_admin"] = True
            clear_login_failures(key)
            log_event("ADMIN_LOGIN")
            return redirect(url_for("admin.panel"))
        record_login_failure(key)
        log_event("LOGIN_FALLIDO", "", f"usuario={name} rol=coordinador")
        return (
            _login_page(
                login_error="Usuario o contraseña incorrectos.", login_name=name
            ),
            401,
        )

    row = get_db().execute(
        "SELECT * FROM users WHERE name=?", (name,)
    ).fetchone()
    if row is None or not row["active"] or not check_password_hash(
        row["password_hash"], password
    ):
        record_login_failure(key)
        log_event("LOGIN_FALLIDO", "", f"usuario={name}")
        return (
            _login_page(
                login_error="Usuario o contraseña incorrectos.", login_name=name
            ),
            401,
        )

    now = time.time()
    session.clear()
    session.permanent = True
    session["u"] = name
    session["is_admin"] = False
    session["epoch"] = row["session_epoch"]
    clear_login_failures(key)
    get_db().execute(
        "UPDATE users SET last_login=?, seen=?, ip=? WHERE name=?",
        (now, now, request.remote_addr, name),
    )
    log_event("LOGIN")
    flash("Sesión iniciada.", "success")
    return redirect(url_for("files.index"))


@bp.post("/register")
def register():
    name = normalize_username(request.form.get("name", ""))
    password = request.form.get("password", "")
    confirm = request.form.get("confirm", "")
    min_length = current_app.config["PASSWORD_MIN_LENGTH"]

    errors = []
    if not valid_username(name):
        errors.append(
            "El usuario debe tener entre 2 y 20 caracteres: letras, números, "
            "guion o guion bajo."
        )
    if name == current_app.config["ADMIN_USER"]:
        errors.append("Ese nombre está reservado para el coordinador.")
    if len(password) < min_length:
        errors.append(f"La contraseña debe tener al menos {min_length} caracteres.")
    if len(password) > 128:
        errors.append("La contraseña es demasiado larga.")
    if password != confirm:
        errors.append("Las contraseñas no coinciden.")
    if not errors and get_db().execute(
        "SELECT 1 FROM users WHERE name=?", (name,)
    ).fetchone():
        errors.append("Ese usuario ya existe. Prueba a iniciar sesión.")

    if errors:
        return (
            _login_page(
                register_errors=errors,
                register_name=name,
                register_tab=True,
            ),
            400,
        )

    now = time.time()
    with write_tx() as db:
        db.execute(
            "INSERT INTO users(name, password_hash, r, w, d, active, "
            "created_at, seen, ip) VALUES(?,?,1,0,0,1,?,?,?)",
            (name, generate_password_hash(password), now, now, request.remote_addr),
        )
        db.execute(
            "INSERT INTO log(ts, usr, ip, op, file, info) VALUES(?,?,?,?,?,?)",
            (now, name, request.remote_addr, "REGISTER", "", "permisos iniciales: leer"),
        )

    session.clear()
    session.permanent = True
    session["u"] = name
    session["is_admin"] = False
    session["epoch"] = 0
    flash(
        "Cuenta creada. Ya puedes leer archivos; el coordinador debe darte "
        "permiso de escritura o borrado.",
        "success",
    )
    return redirect(url_for("files.index"))


@bp.post("/logout")
def logout():
    if session.get("u"):
        log_event("LOGOUT")
    session.clear()
    flash("Has cerrado la sesión.", "info")
    return redirect(url_for("files.index"))


@bp.route("/account/password", methods=["GET", "POST"])
@login_required
def change_password():
    if is_admin_session():
        flash(
            "La contraseña del coordinador se define con ADMIN_PASS_HASH en el "
            "entorno del servidor, no desde la web.",
            "warning",
        )
        return redirect(url_for("admin.panel"))

    user = current_user()
    if user is None:
        return redirect(url_for("files.index"))
    if request.method == "GET":
        return render_template("auth/password.html")

    current = request.form.get("current", "")
    new = request.form.get("password", "")
    confirm = request.form.get("confirm", "")
    min_length = current_app.config["PASSWORD_MIN_LENGTH"]
    errors = []
    if not check_password_hash(user["password_hash"], current):
        errors.append("La contraseña actual no es correcta.")
    if len(new) < min_length:
        errors.append(f"La nueva contraseña debe tener al menos {min_length} caracteres.")
    if len(new) > 128:
        errors.append("La nueva contraseña es demasiado larga.")
    if new != confirm:
        errors.append("Las contraseñas nuevas no coinciden.")
    if errors:
        return (
            render_template("auth/password.html", errors=errors),
            400,
        )

    with write_tx() as db:
        db.execute(
            "UPDATE users SET password_hash=?, "
            "session_epoch=session_epoch+1 WHERE name=?",
            (generate_password_hash(new), user["name"]),
        )
        epoch = db.execute(
            "SELECT session_epoch FROM users WHERE name=?", (user["name"],)
        ).fetchone()["session_epoch"]
    session["epoch"] = epoch
    log_event("PASSWORD", "", "cambio propio")
    flash("Contraseña actualizada.", "success")
    return redirect(url_for("files.index"))
