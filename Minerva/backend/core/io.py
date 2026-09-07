#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
I/O helpers y utilidades de seguridad para el backend Minerva.

Provee:
  - emit() / emit_error()          → comunicación JSON con el QML
  - is_safe_path() / classify_cmd() → seguridad de filesystem y comandos
"""
import json
import os
import pathlib
import queue
import re
import sys
import threading

from .config import HOME


_SAFE_SESSION_ENV_KEYS = {
    "COLORTERM",
    "DBUS_SESSION_BUS_ADDRESS",
    "DISPLAY",
    "GDK_BACKEND",
    "HOME",
    "HYPRLAND_INSTANCE_SIGNATURE",
    "LANG",
    "LC_ALL",
    "LOGNAME",
    "PATH",
    "QT_QPA_PLATFORM",
    "SHELL",
    "TERM",
    "USER",
    "WAYLAND_DISPLAY",
    "XAUTHORITY",
    "XDG_CURRENT_DESKTOP",
    "XDG_DATA_DIRS",
    "XDG_RUNTIME_DIR",
    "XDG_SESSION_TYPE",
}

# ─────────────────────────────────────────────────────────────────────────────
# Patrones de seguridad para comandos
# ─────────────────────────────────────────────────────────────────────────────
DESTRUCTIVE_RE = re.compile(
    r"\brm\b"             # cualquier rm
    r"|\bdd\b"            # disk destroyer
    r"|\bmkfs\b"          # formatear sistema de archivos
    r"|\bshred\b"         # borrado seguro
    r"|\btruncate\b"      # truncar archivo
    r"|\bwipe\b"          # borrado de disco
    r"|\bmv\s+.*\s+/"     # mover a ruta absoluta
    r"|>\s*/(?!dev/null)" # redirigir a archivo del sistema
    r"|>>\s*/"            # añadir a archivo del sistema
    r"|\byay\s+-[SRU]"    # instalacion de AUR
    r"|\bparu\s+-[SRU]",  # instalacion de AUR
    re.IGNORECASE
)
SUDO_RE = re.compile(
    r"\bsudo\b"
    r"|\bpkexec\b"
    r"|\bpacman\s+-[SRU][a-zA-Z]*\b"
    r"|\bsystemctl\s+(start|stop|restart|enable|disable|daemon-reload)\b",
    re.IGNORECASE
)


# ─────────────────────────────────────────────────────────────────────────────
# I/O — comunicación con QML vía stdout (JSON Lines)
# ─────────────────────────────────────────────────────────────────────────────
_OUTPUT_QUEUE: queue.Queue[str | None] = queue.Queue(maxsize=4096)
_WRITER_STARTED = threading.Event()
_WRITER_LOCK = threading.Lock()


def _stdout_writer() -> None:
    """Serializa eventos para impedir que dos hilos mezclen líneas JSON."""
    while True:
        line = _OUTPUT_QUEUE.get()
        try:
            if line is None:
                return
            sys.stdout.write(line)
            sys.stdout.flush()
        except BrokenPipeError:
            # El proceso padre desapareció; continuar dejaría workers huérfanos.
            import os

            os._exit(0)
        finally:
            _OUTPUT_QUEUE.task_done()


def _ensure_writer() -> None:
    if _WRITER_STARTED.is_set():
        return
    with _WRITER_LOCK:
        if _WRITER_STARTED.is_set():
            return
        threading.Thread(
            target=_stdout_writer,
            name="minerva-stdout",
            daemon=True,
        ).start()
        _WRITER_STARTED.set()


def emit(obj: dict) -> None:
    """Encola un objeto para enviarlo a QML como una línea JSON indivisible."""
    _ensure_writer()
    line = json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n"
    _OUTPUT_QUEUE.put(line)


def emit_error(msg: str) -> None:
    emit({"type": "error", "message": msg})


def safe_session_environment() -> dict[str, str]:
    """Devuelve variables de escritorio sin secretos de APIs o base de datos."""
    environment = {
        key: value
        for key, value in os.environ.items()
        if key in _SAFE_SESSION_ENV_KEYS or key.startswith("LC_")
    }
    environment["HOME"] = HOME
    environment.setdefault("PATH", "/usr/local/bin:/usr/bin:/bin")
    return environment


# ─────────────────────────────────────────────────────────────────────────────
# Seguridad
# ─────────────────────────────────────────────────────────────────────────────
def is_safe_path(p: str) -> bool:
    """Verifica que la ruta esté dentro de $HOME."""
    try:
        root = pathlib.Path(HOME).resolve()
        candidate = pathlib.Path(p).expanduser().resolve()
        return candidate == root or candidate.is_relative_to(root)
    except (OSError, RuntimeError, ValueError):
        return False


def classify_cmd(cmd: str) -> str:
    """Clasifica el aviso requerido; ningún comando se autoejecuta."""
    if SUDO_RE.search(cmd):
        return "sudo"
    if DESTRUCTIVE_RE.search(cmd):
        return "destructive"
    return "safe"
