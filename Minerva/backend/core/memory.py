"""Memoria Markdown privada y acotada de Minerva."""

from __future__ import annotations

import os
import pathlib
import re
import sys
import tempfile
import threading

from .config import HOME


MEMORY_DIR = os.path.join(HOME, ".config", "minerva", "memory")
USER_PROFILE_FILE = os.path.join(MEMORY_DIR, "user_profile.md")
PREFERENCES_FILE = os.path.join(MEMORY_DIR, "preferences.md")

# Nombres conservados por compatibilidad con importadores antiguos.
chroma_client = None
CHROMADB_AVAILABLE = False
MEMORY_AVAILABLE = True

MAX_MEMORY_FILE_BYTES = 256 * 1024
MAX_MEMORY_CONTENT_CHARS = 64 * 1024
_MEMORY_LOCK = threading.RLock()

_USER_PROFILE_TEMPLATE = """\
# Perfil del Usuario

## Información Personal
<!-- Nombre, alias, idioma preferido, zona horaria, etc. -->

## Entorno de Trabajo
<!-- Sistema operativo, shell, editor, hardware relevante, etc. -->

## Proyectos Activos
<!-- Proyectos en los que trabaja actualmente el usuario -->

## Contexto General
<!-- Cualquier otro dato estable del usuario que sea útil recordar -->
"""

_PREFERENCES_TEMPLATE = """\
# Preferencias del Usuario

## Lenguajes de Programación
<!-- Lenguajes favoritos, los que usa por defecto, etc. -->

## Herramientas y Software
<!-- Editores, terminales, apps preferidas, etc. -->

## Estilo de Comunicación
<!-- Cómo prefiere recibir las respuestas: concisas, detalladas, etc. -->

## Otras Preferencias
<!-- Cualquier otra preferencia relevante: música, temas visuales, etc. -->
"""


def _atomic_private_write(path: pathlib.Path, content: str) -> None:
    temp_name = ""
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            delete=False,
        ) as temporary:
            temporary.write(content)
            temporary.flush()
            temp_name = temporary.name
        os.chmod(temp_name, 0o600)
        os.replace(temp_name, path)
    finally:
        if temp_name:
            pathlib.Path(temp_name).unlink(missing_ok=True)


def _ensure_memory_files() -> None:
    """Crea de forma privada el directorio y las plantillas ausentes."""
    with _MEMORY_LOCK:
        try:
            directory = pathlib.Path(MEMORY_DIR)
            directory.mkdir(mode=0o700, parents=True, exist_ok=True)
            directory.chmod(0o700)
            for raw_path, template in (
                (USER_PROFILE_FILE, _USER_PROFILE_TEMPLATE),
                (PREFERENCES_FILE, _PREFERENCES_TEMPLATE),
            ):
                path = pathlib.Path(raw_path)
                try:
                    with path.open("x", encoding="utf-8") as memory_file:
                        memory_file.write(template)
                    path.chmod(0o600)
                except FileExistsError:
                    if path.is_file() and path.stat().st_mode & 0o077:
                        path.chmod(0o600)
        except OSError as exc:
            print(
                "[Minerva/memory] Error preparando memoria: "
                f"{type(exc).__name__}",
                file=sys.stderr,
            )


def _read_file_safe(path: str) -> str:
    """Lee como máximo 256 KiB; retorna una cadena vacía si falla."""
    try:
        memory_path = pathlib.Path(path)
        if not memory_path.is_file():
            return ""
        with memory_path.open("r", encoding="utf-8", errors="replace") as file:
            return file.read(MAX_MEMORY_FILE_BYTES + 1)[:MAX_MEMORY_FILE_BYTES].strip()
    except OSError:
        return ""


def get_memory_context(_text: str = "") -> str:
    """Combina el perfil y las preferencias para el system prompt."""
    del _text
    _ensure_memory_files()
    with _MEMORY_LOCK:
        parts = [
            content
            for content in (
                _read_file_safe(USER_PROFILE_FILE),
                _read_file_safe(PREFERENCES_FILE),
            )
            if content
        ]
    return "\n\n---\n\n".join(parts)


def update_memory_section(file_key: str, section: str, content: str) -> str:
    """Crea o reemplaza una sección Markdown de la memoria indicada."""
    targets = {
        "profile": pathlib.Path(USER_PROFILE_FILE),
        "preferences": pathlib.Path(PREFERENCES_FILE),
    }
    target = targets.get(file_key)
    if target is None:
        return (
            f"Error: file_key desconocido '{file_key}'. "
            "Usa 'profile' o 'preferences'."
        )

    section = section.strip()
    if not section or len(section) > 200 or "\n" in section or "\r" in section:
        return "Error: el nombre de sección es inválido."
    if len(content) > MAX_MEMORY_CONTENT_CHARS:
        return "Error: el contenido de memoria supera el límite permitido."

    _ensure_memory_files()
    heading = f"## {section}"
    replacement = f"{heading}\n{content.strip()}\n"
    pattern = rf"(?m)^{re.escape(heading)}\n.*?(?=^#{{1,2}}\s|\Z)"
    try:
        with _MEMORY_LOCK:
            current_text = _read_file_safe(str(target))
            if re.search(pattern, current_text, flags=re.DOTALL):
                new_text = re.sub(
                    pattern,
                    replacement,
                    current_text,
                    count=1,
                    flags=re.DOTALL,
                )
            else:
                new_text = current_text.rstrip() + f"\n\n{replacement}"
            if len(new_text.encode("utf-8")) > MAX_MEMORY_FILE_BYTES:
                return "Error: el archivo de memoria superaría el límite permitido."
            _atomic_private_write(target, new_text)
        return (
            f"Memoria actualizada en '{target.name}' → sección '{section}'."
        )
    except OSError as exc:
        return f"Error al actualizar memoria: {type(exc).__name__}"
