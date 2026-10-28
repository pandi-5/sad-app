"""Registro de auditoría de operaciones."""
from __future__ import annotations

import time

from flask import request, session

from .db import get_db


def log_event(op: str, file: str = "", info: str = "") -> None:
    db = get_db()
    user = session.get("u", "-")
    ip = request.remote_addr or "-"
    db.execute(
        "INSERT INTO log(ts, usr, ip, op, file, info) VALUES(?,?,?,?,?,?)",
        (time.time(), user, ip, op, file, info),
    )
