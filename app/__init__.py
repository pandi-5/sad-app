"""Fábrica de la aplicación Flask."""
from __future__ import annotations

import time

from dotenv import load_dotenv
from flask import Flask, jsonify

from .config import BASE_DIR, MODES, apply_derived_config, build_config, validate_config
from .db import get_db, get_mode, init_app as init_db_app
from .security import current_user, install_security, is_admin_session
from .utils import human_size

OP_CLASSES = {
    "CONFLICTO": "warn",
    "SOBRESCRITURA": "warn",
    "DENEGADO": "danger",
    "RECHAZADO": "danger",
    "LOGIN_FALLIDO": "danger",
    "LOGIN_BLOQUEADO": "danger",
    "CSRF": "danger",
    "SESION_INVALIDA": "warn",
    "DELETE": "danger",
    "FORCE_UNLOCK": "warn",
    "RESET_PASS": "warn",
    "PERMISOS": "warn",
    "MODO": "warn",
    "LOCK": "lock",
    "UNLOCK": "lock",
    "UPLOAD": "ok",
    "WRITE": "ok",
    "REPLACE": "ok",
    "RESTORE": "ok",
    "COPY": "ok",
    "REGISTER": "ok",
    "LOGIN": "ok",
}


def create_app(test_config: dict | None = None) -> Flask:
    load_dotenv(BASE_DIR / ".env")

    app = Flask(
        __name__,
        template_folder=str(BASE_DIR / "templates"),
        static_folder=str(BASE_DIR / "static"),
    )
    app.config.from_mapping(build_config())
    if test_config:
        app.config.update(test_config)
    apply_derived_config(app.config)
    validate_config(app.config)

    app.jinja_env.trim_blocks = True
    app.jinja_env.lstrip_blocks = True
    app.json.sort_keys = False

    init_db_app(app)
    install_security(app)

    from . import admin, auth, files

    app.register_blueprint(auth.bp)
    app.register_blueprint(files.bp)
    app.register_blueprint(admin.bp)

    @app.template_filter("hora")
    def hora_filter(ts):
        if not ts:
            return "—"
        return time.strftime("%H:%M:%S", time.gmtime(float(ts) - 5 * 3600))

    @app.template_filter("fecha")
    def fecha_filter(ts):
        if not ts:
            return "—"
        return time.strftime("%d/%m/%Y %H:%M", time.gmtime(float(ts) - 5 * 3600))

    @app.template_filter("tamano")
    def tamano_filter(value):
        return human_size(value)

    @app.template_filter("op_class")
    def op_class_filter(op):
        return OP_CLASSES.get(op, "")

    @app.context_processor
    def inject_globals():
        try:
            user = current_user()
            admin = is_admin_session()
            current_mode = get_mode()
        except Exception:  # una base caída no debe romper la página de error
            user, admin, current_mode = None, False, "libre"
        return {
            "u": user,
            "is_admin": admin,
            "mode": current_mode,
            "modes": MODES,
            "admin_user": app.config["ADMIN_USER"],
            "max_upload_mb": app.config["MAX_UPLOAD_MB"],
            "max_text_kb": app.config["MAX_TEXT_BYTES"] // 1024,
            "lock_ttl": app.config["LOCK_TTL"],
            "online_window": app.config["ONLINE_WINDOW"],
            "app_name": "Archivos compartidos",
        }

    @app.get("/healthz")
    def healthz():
        try:
            get_db().execute("SELECT 1").fetchone()
        except Exception:
            return jsonify(status="error"), 503
        return jsonify(status="ok", mode=get_mode())

    @app.get("/favicon.ico")
    def favicon():
        return app.send_static_file("favicon.svg")

    return app
