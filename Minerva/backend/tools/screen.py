#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
backend/tools/screen.py — Herramienta de captura de pantalla para Minerva.

Usa `grim` (Wayland) para capturar la pantalla completa, la codifica en
base64 y la devuelve junto con metadatos de resolución para que el engine
la inyecte en el historial como imagen multimodal.
"""
import base64
import os
import shutil
import subprocess
import tempfile
from datetime import datetime

from ..core.io import safe_session_environment

# ─────────────────────────────────────────────────────────────────────────────
# Sentinel especial: indica que el resultado ES una imagen, no texto.
# El despachador lo detecta y lo trata de forma distinta al texto plano.
# ─────────────────────────────────────────────────────────────────────────────
MAX_SCREENSHOT_BYTES = 25 * 1024 * 1024


class ScreenCapture:
    """Contenedor de resultado de captura de pantalla."""
    def __init__(self, b64: str, width: int, height: int, timestamp: str):
        self.b64       = b64
        self.width     = width
        self.height    = height
        self.timestamp = timestamp

    def summary_text(self) -> str:
        return (
            f"[Captura de pantalla adjunta — {self.width}×{self.height}px — "
            f"{self.timestamp}]"
        )


def tool_capture_screen(output: str = "") -> "ScreenCapture | str":
    """
    Captura la pantalla completa (o una salida específica) con grim.

    Parámetros:
        output: Nombre del monitor Wayland (ej. "DP-1", "HDMI-A-1").
                Vacío = captura toda la pantalla/compositor.

    Retorna:
        ScreenCapture con imagen en base64, o str con mensaje de error.
    """
    # Verificar que grim está disponible
    if not shutil.which("grim"):
        return "Error: grim no está instalado. Instálalo con: paru -S grim"

    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
        tmp_path = tmp.name

    try:
        cmd = ["grim"]
        if output:
            cmd += ["-o", output]
        cmd.append(tmp_path)

        result = subprocess.run(
            cmd,
            capture_output=True,
            timeout=10,
            env=safe_session_environment(),
        )

        if result.returncode != 0:
            err = result.stderr.decode("utf-8", errors="replace").strip()
            detail = err or "código " + str(result.returncode)
            return f"Error al capturar pantalla: {detail[:500]}"

        # Leer y codificar en base64
        if os.path.getsize(tmp_path) > MAX_SCREENSHOT_BYTES:
            return "Error: la captura de pantalla es demasiado grande."
        with open(tmp_path, "rb") as f:
            raw = f.read(MAX_SCREENSHOT_BYTES + 1)
        if not raw.startswith(b"\x89PNG\r\n\x1a\n"):
            return "Error: grim no produjo una imagen PNG válida."

        b64 = base64.b64encode(raw).decode("utf-8")

        # Obtener resolución con identify (ImageMagick) si está disponible,
        # o con un fallback a python-pillow, o simplemente "desconocida".
        width, height = _get_image_size(tmp_path)

        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        return ScreenCapture(
            b64=b64,
            width=width,
            height=height,
            timestamp=timestamp,
        )
    except subprocess.TimeoutExpired:
        return "Error al capturar pantalla: tiempo máximo excedido."
    except OSError as exc:
        return f"Error al capturar pantalla: {type(exc).__name__}"
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


def _get_image_size(path: str) -> tuple[int, int]:
    """Intenta obtener las dimensiones de un PNG sin dependencias extra."""
    try:
        # PNG: bytes 16-24 contienen anchura y altura en big-endian
        with open(path, "rb") as f:
            f.seek(16)
            w = int.from_bytes(f.read(4), "big")
            h = int.from_bytes(f.read(4), "big")
        return w, h
    except Exception:
        return 0, 0
