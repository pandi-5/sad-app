#!/usr/bin/env python3
"""Captura pantallas reales de la web de sad-app con Chromium sin interfaz.

Uso   python capturas_web.py URL_BASE CARPETA_SALIDA PREFIJO CLAVE_COORDINADOR

Recorre un guion corto: acceso, subida de un archivo, panel del coordinador, vista del
clúster, conflicto de versiones y bloqueo de edición. Necesita los usuarios cliente1 y
cliente2 creados por setup.sh, y  pip install playwright && playwright install chromium.
"""
from __future__ import annotations

import os
import sys
import tempfile
import time

from playwright.sync_api import sync_playwright

base, out, prefix, coord_pass = sys.argv[1].rstrip("/"), sys.argv[2], sys.argv[3], sys.argv[4]
USERS = {"cliente1": "ClaveCliente123", "cliente2": "ClaveCliente456"}
os.makedirs(out, exist_ok=True)


def shot(page, name):
    path = os.path.join(out, f"{prefix}-{name}.png")
    page.wait_for_timeout(500)
    page.screenshot(path=path)
    print("captura", path, flush=True)


def login(browser, name, password):
    ctx = browser.new_context(viewport={"width": 1280, "height": 800})
    page = ctx.new_page()
    page.goto(base + "/")
    form = 'form[action$="/login"]'
    page.fill(f'{form} input[name="name"]', name)
    page.fill(f'{form} input[name="password"]', password)
    page.click(f'{form} button[type="submit"]')
    page.wait_for_load_state("networkidle")
    return page


def set_mode(admin, label):
    admin.goto(base + "/admin")
    admin.click(f'label.mode-card:has-text("{label}")')
    admin.wait_for_load_state("networkidle")
    admin.wait_for_timeout(600)


with sync_playwright() as p:
    browser = p.chromium.launch()

    anon = browser.new_context(viewport={"width": 1280, "height": 800}).new_page()
    anon.goto(base + "/")
    shot(anon, "01-acceso")

    admin = login(browser, "coordinador", coord_pass)
    set_mode(admin, "Libre")

    c1 = login(browser, "cliente1", USERS["cliente1"])
    sample = os.path.join(tempfile.gettempdir(), "informe-sistemas-distribuidos.txt")
    with open(sample, "w", encoding="utf-8") as fh:
        fh.write("Informe del laboratorio de archivos distribuidos\nGrupo 4\n")
    c1.goto(base + "/")
    if c1.locator("a:has-text('informe-sistemas-distribuidos.txt')").count() == 0:
        c1.set_input_files("#file-input", sample)
        c1.click("[data-upload-submit]")
        c1.wait_for_load_state("networkidle")
        c1.wait_for_timeout(1200)
        c1.goto(base + "/")
    shot(c1, "02-archivos-cliente")

    admin.goto(base + "/admin")
    shot(admin, "03-panel-coordinador")
    admin.goto(base + "/cluster")
    admin.wait_for_timeout(1500)
    shot(admin, "04-cluster")

    # Conflicto de versiones
    set_mode(admin, "Por versiones")
    shot(admin, "05-modo-versiones")
    c1.goto(base + "/")
    c1.click("a:has-text('Editar') >> nth=0")
    c1.wait_for_load_state("networkidle")
    file_url = c1.url
    c2 = login(browser, "cliente2", USERS["cliente2"])
    c2.goto(file_url)
    c1.fill("#editor-text", "Informe del laboratorio\nCambio de cliente1\n")
    c2.fill("#editor-text", "Informe del laboratorio\nCambio de cliente2\n")
    c1.click("[data-save-button]")
    c1.wait_for_load_state("networkidle")
    c2.click("[data-save-button]")
    c2.wait_for_load_state("networkidle")
    shot(c2, "06-conflicto-versiones")

    # Bloqueo de edición
    set_mode(admin, "Con bloqueo")
    c1.goto(file_url)
    c2.goto(file_url)
    shot(c2, "07-bloqueo-solo-lectura")
    shot(c1, "08-bloqueo-propietario")

    # Auditoría
    admin.goto(base + "/admin")
    admin.click('[data-tab-button="registro"]')
    shot(admin, "09-auditoria")

    set_mode(admin, "Libre")
    browser.close()
print("listo")
