"""Configuración central de la aplicación.

Toda la configuración sensible se toma de variables de entorno. La aplicación
se niega a arrancar con secretos de ejemplo o con la contraseña histórica
"admin123", salvo que se active explícitamente ALLOW_INSECURE_DEFAULTS=1 en
un entorno de desarrollo.
"""
from __future__ import annotations

import os
from datetime import timedelta
from pathlib import Path

from werkzeug.security import generate_password_hash

BASE_DIR = Path(__file__).resolve().parent.parent

INSECURE_SECRETS = {"", "cambia-esto", "changeme", "secret", "dev", "test"}
INSECURE_PASSWORDS = {"", "admin123", "admin", "password", "cambia-esto"}
PLACEHOLDER_MARKERS = (
    "cambia",
    "changeme",
    "placeholder",
    "ejemplo",
    "example",
    "tu-contraseña",
    "tu-contrasena",
)


def looks_like_placeholder(value: str) -> bool:
    text = (value or "").strip().lower()
    return any(marker in text for marker in PLACEHOLDER_MARKERS)


MODES = {
    "libre": {
        "label": "Libre",
        "short": "Gana el último en guardar",
        "description": (
            "Sin control de concurrencia. Si dos personas editan a la vez, "
            "la última que guarda sobrescribe a la otra. La operación queda "
            "registrada como SOBRESCRITURA."
        ),
    },
    "versiones": {
        "label": "Por versiones",
        "short": "Detecta conflictos",
        "description": (
            "Control optimista. Cada guardado comprueba la versión que abriste. "
            "Si alguien guardó antes, se muestra un conflicto con tu texto y la "
            "versión del servidor para que decidas."
        ),
    },
    "bloqueo": {
        "label": "Con bloqueo",
        "short": "Un editor a la vez",
        "description": (
            "Control pesimista. Al abrir un archivo se reserva un bloqueo "
            "renovable mientras editas. Los demás pueden leerlo, pero no "
            "guardarlo hasta que lo sueltes o caduque."
        ),
    },
}


def env_bool(name: str, default: bool = False) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "si", "sí", "on"}


def env_int(name: str, default: int, minimum: int = 1) -> int:
    try:
        value = int(os.getenv(name, str(default)))
    except ValueError:
        value = default
    return max(minimum, value)


def build_config() -> dict:
    max_upload_mb = env_int("MAX_UPLOAD_MB", 25)
    max_text_kb = env_int("MAX_TEXT_KB", 512)
    session_hours = env_int("SESSION_LIFETIME_H", 8)
    allow_insecure = env_bool("ALLOW_INSECURE_DEFAULTS", False)

    admin_pass = os.getenv("ADMIN_PASS", "")
    admin_hash = os.getenv("ADMIN_PASS_HASH", "")
    if not admin_hash and admin_pass:
        admin_hash = generate_password_hash(admin_pass)

    db_path = os.getenv("DB_PATH", str(BASE_DIR / "data" / "sad.db"))
    storage_dir = os.getenv("STORAGE_DIR", str(BASE_DIR / "storage"))

    return {
        "SECRET_KEY": os.getenv("SECRET", ""),
        "ADMIN_USER": os.getenv("ADMIN_USER", "coordinador").strip().lower(),
        "ADMIN_PASS_HASH": admin_hash,
        "ALLOW_INSECURE_DEFAULTS": allow_insecure,
        # Archivos
        "MAX_UPLOAD_MB": max_upload_mb,
        "MAX_CONTENT_LENGTH": max_upload_mb * 1024 * 1024,
        "MAX_TEXT_BYTES": max_text_kb * 1024,
        "MAX_VERSIONS": env_int("MAX_VERSIONS", 10),
        "MAX_FILES_PER_UPLOAD": env_int("MAX_FILES_PER_UPLOAD", 20),
        # Concurrencia / presencia
        "LOCK_TTL": env_int("LOCK_TTL", 90),
        "ONLINE_WINDOW": env_int("ONLINE_WINDOW", 30),
        # Seguridad
        "SESSION_COOKIE_NAME": "sad_session",
        "SESSION_COOKIE_HTTPONLY": True,
        "SESSION_COOKIE_SAMESITE": "Lax",
        "SESSION_COOKIE_SECURE": env_bool("COOKIE_SECURE", False),
        "PERMANENT_SESSION_LIFETIME": timedelta(hours=session_hours),
        "WTF_CSRF_TIME_LIMIT": None,
        "WTF_CSRF_SSL_STRICT": False,
        "LOGIN_MAX_ATTEMPTS": env_int("LOGIN_MAX_ATTEMPTS", 5),
        "LOGIN_WINDOW": env_int("LOGIN_WINDOW", 900),
        "PASSWORD_MIN_LENGTH": env_int("PASSWORD_MIN_LENGTH", 8),
        # Rutas
        "DB_PATH": db_path,
        "STORAGE_DIR": storage_dir,
        "SEND_FILE_MAX_AGE_DEFAULT": 0,
        "JSON_SORT_KEYS": False,
    }


def apply_derived_config(config: dict) -> dict:
    """Recalcula rutas derivadas después de aplicar overrides (tests, etc.)."""
    storage = Path(config["STORAGE_DIR"])
    config["STORAGE_DIR"] = str(storage)
    config["FILES_DIR"] = str(storage / "files")
    config["TMP_DIR"] = str(storage / "tmp")
    config["VERSIONS_DIR"] = str(storage / "versions")
    config.setdefault("MAX_UPLOAD_MB", 25)
    config["MAX_CONTENT_LENGTH"] = int(config["MAX_UPLOAD_MB"]) * 1024 * 1024
    return config


def validate_config(config: dict) -> None:
    if config.get("TESTING"):
        return

    errors: list[str] = []
    secret = config.get("SECRET_KEY") or ""
    if (
        secret.strip().lower() in INSECURE_SECRETS
        or looks_like_placeholder(secret)
        or len(secret) < 24
    ):
        errors.append(
            "SECRET debe ser una cadena aleatoria de al menos 24 caracteres "
            "(por ejemplo: python -c \"import secrets; print(secrets.token_hex(32))\")."
        )

    if not config.get("ADMIN_PASS_HASH"):
        errors.append(
            "Falta ADMIN_PASS_HASH (o ADMIN_PASS) para la cuenta del coordinador."
        )

    if not config.get("ALLOW_INSECURE_DEFAULTS"):
        plain = os.getenv("ADMIN_PASS", "")
        if plain and (
            plain.strip().lower() in INSECURE_PASSWORDS
            or looks_like_placeholder(plain)
        ):
            errors.append(
                "ADMIN_PASS usa una contraseña de ejemplo. Cambiala o define "
                "ADMIN_PASS_HASH y elimina ADMIN_PASS."
            )
        if not config.get("ADMIN_USER"):
            errors.append("ADMIN_USER no puede estar vacío.")

    if errors:
        raise RuntimeError(
            "Configuración insegura o incompleta:\n - " + "\n - ".join(errors)
        )
