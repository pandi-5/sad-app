"""Acceso a SQLite, esquema y transacciones."""
from __future__ import annotations

import shutil
import sqlite3
import time
from contextlib import contextmanager
from pathlib import Path

from flask import current_app, g

SCHEMA_VERSION = 2

SCHEMA = """
CREATE TABLE IF NOT EXISTS users(
    name TEXT PRIMARY KEY,
    password_hash TEXT NOT NULL,
    r INTEGER NOT NULL DEFAULT 1,
    w INTEGER NOT NULL DEFAULT 0,
    d INTEGER NOT NULL DEFAULT 0,
    active INTEGER NOT NULL DEFAULT 1,
    session_epoch INTEGER NOT NULL DEFAULT 0,
    ip TEXT,
    seen REAL NOT NULL DEFAULT 0,
    created_at REAL NOT NULL,
    last_login REAL
);

CREATE TABLE IF NOT EXISTS files(
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    stored_name TEXT NOT NULL UNIQUE,
    mime TEXT,
    size INTEGER NOT NULL DEFAULT 0,
    hash TEXT,
    is_text INTEGER NOT NULL DEFAULT 0,
    ver INTEGER NOT NULL DEFAULT 1,
    author TEXT,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL,
    lock_user TEXT,
    lock_ts REAL NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_files_updated ON files(updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_files_lock ON files(lock_user, lock_ts);

CREATE TABLE IF NOT EXISTS file_versions(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    file_id TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    ver INTEGER NOT NULL,
    author TEXT,
    ts REAL NOT NULL,
    size INTEGER NOT NULL DEFAULT 0,
    hash TEXT,
    mime TEXT,
    is_text INTEGER NOT NULL DEFAULT 0,
    stored_name TEXT NOT NULL,
    op TEXT NOT NULL,
    note TEXT,
    UNIQUE(file_id, ver)
);

CREATE INDEX IF NOT EXISTS idx_versions_file ON file_versions(file_id, ver DESC);

CREATE TABLE IF NOT EXISTS log(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts REAL NOT NULL,
    usr TEXT,
    ip TEXT,
    op TEXT NOT NULL,
    file TEXT,
    info TEXT
);

CREATE INDEX IF NOT EXISTS idx_log_ts ON log(ts DESC);
CREATE INDEX IF NOT EXISTS idx_log_op ON log(op);

CREATE TABLE IF NOT EXISTS login_attempts(
    key TEXT PRIMARY KEY,
    count INTEGER NOT NULL DEFAULT 0,
    first_ts REAL NOT NULL,
    last_ts REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS cfg(
    k TEXT PRIMARY KEY,
    v TEXT
);

INSERT OR IGNORE INTO cfg(k, v) VALUES('mode', 'libre');
"""


def connect_db(path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(path, timeout=10, isolation_level=None)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("PRAGMA busy_timeout=5000")
    conn.execute("PRAGMA synchronous=NORMAL")
    return conn


def get_db() -> sqlite3.Connection:
    if "db" not in g:
        g.db = connect_db(current_app.config["DB_PATH"])
    return g.db


def close_db(_error=None) -> None:
    conn = g.pop("db", None)
    if conn is not None:
        conn.close()


def _has_table(conn: sqlite3.Connection, name: str) -> bool:
    row = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)
    ).fetchone()
    return row is not None


def _backup_and_reset(db_path: Path) -> Path | None:
    """La versión 1 no tenía contraseñas ni identificadores seguros.

    Se conserva una copia y se crea una base limpia. El coordinador vive en el
    entorno, así que no hay usuarios que migrar (decisión del proyecto).
    """
    backup = db_path.with_name(
        f"{db_path.name}.bak-{time.strftime('%Y%m%d-%H%M%S')}"
    )
    shutil.copy2(db_path, backup)
    for suffix in ("-wal", "-shm"):
        sidecar = Path(str(db_path) + suffix)
        if sidecar.exists():
            sidecar.unlink()
    db_path.unlink()
    return backup


def init_db() -> None:
    db_path = Path(current_app.config["DB_PATH"])
    db_path.parent.mkdir(parents=True, exist_ok=True)

    reset_from = None
    if db_path.exists() and db_path.stat().st_size > 0:
        conn = sqlite3.connect(db_path)
        try:
            version = conn.execute("PRAGMA user_version").fetchone()[0]
            old_schema = version < SCHEMA_VERSION and _has_table(conn, "users")
            old_without_passwords = False
            if _has_table(conn, "users"):
                columns = {
                    row[1] for row in conn.execute("PRAGMA table_info(users)")
                }
                old_without_passwords = "password_hash" not in columns
        finally:
            conn.close()
        if old_schema or old_without_passwords:
            reset_from = _backup_and_reset(db_path)

    conn = connect_db(str(db_path))
    try:
        conn.executescript(SCHEMA)
        conn.execute(f"PRAGMA user_version={SCHEMA_VERSION}")
        conn.execute("DELETE FROM login_attempts WHERE last_ts < ?", (time.time() - 86400,))
    finally:
        conn.close()

    storage = Path(current_app.config["STORAGE_DIR"])
    for folder in (
        storage,
        Path(current_app.config["FILES_DIR"]),
        Path(current_app.config["TMP_DIR"]),
        Path(current_app.config["VERSIONS_DIR"]),
    ):
        folder.mkdir(parents=True, exist_ok=True)

    if reset_from is not None:
        current_app.logger.warning(
            "Base de datos anterior copiada en %s y reiniciada limpia.", reset_from
        )


@contextmanager
def write_tx():
    """Transacción de escritura explícita (BEGIN IMMEDIATE)."""
    db = get_db()
    if db.in_transaction:
        # Ya estamos dentro de una transacción: participamos en ella.
        yield db
        return
    db.execute("BEGIN IMMEDIATE")
    try:
        yield db
    except BaseException:
        if db.in_transaction:
            db.execute("ROLLBACK")
        raise
    else:
        if db.in_transaction:
            db.execute("COMMIT")


def get_mode() -> str:
    row = get_db().execute("SELECT v FROM cfg WHERE k='mode'").fetchone()
    mode = row["v"] if row else "libre"
    return mode if mode in {"libre", "versiones", "bloqueo"} else "libre"


def set_mode(mode: str) -> None:
    with write_tx() as db:
        db.execute("UPDATE cfg SET v=? WHERE k='mode'", (mode,))


def init_app(app) -> None:
    app.teardown_appcontext(close_db)
    with app.app_context():
        init_db()
