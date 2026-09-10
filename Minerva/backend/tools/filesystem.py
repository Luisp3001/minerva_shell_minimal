#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Herramientas de sistema de archivos para Minerva.

Todas las funciones reciben rutas y retornan strings (resultado o error).
La validación de seguridad (is_safe_path) se aplica en todas las operaciones.
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import zipfile

from ..core.config import HOME, MAX_DIR
from ..core.io import is_safe_path, safe_session_environment


MAX_TEXT_BYTES = 8 * 1024 * 1024
MAX_DOCUMENT_BYTES = 25 * 1024 * 1024
MAX_EXTRACTED_CHARS = 512 * 1024
MAX_READ_LINES = 200
MAX_ARCHIVE_ENTRIES = 5_000
MAX_ARCHIVE_EXPANDED_BYTES = 100 * 1024 * 1024
MAX_PANDOC_AST_BYTES = 16 * 1024 * 1024

_DOCUMENT_EXTENSIONS = {".doc", ".docx"}
_PRESENTATION_EXTENSIONS = {".ppt", ".pptx"}
_SPREADSHEET_EXTENSIONS = {".csv", ".xls", ".xlsx"}
_RAG_SUPPORTED_EXTENSIONS = (
    _DOCUMENT_EXTENSIONS | _PRESENTATION_EXTENSIONS | {".pdf"}
)
_OOXML_REQUIRED_ENTRIES = {
    ".docx": "word/document.xml",
    ".pptx": "ppt/presentation.xml",
    ".xlsx": "xl/workbook.xml",
}


def _document_environment() -> dict[str, str]:
    """Entorno de sesión sin secretos de APIs para procesadores de documentos.

    Usa safe_session_environment() como base (incluye XDG_DATA_DIRS, DBUS, etc.
    que pandoc y otros procesadores necesitan) pero excluye variables que
    podrían exponer credenciales de Minerva.
    """
    excluded = {
        "GEMINI_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY",
        "FISH_API_KEY", "GOOGLE_API_KEY",
    }
    environment = {
        key: value
        for key, value in safe_session_environment().items()
        if key not in excluded
    }
    environment["HOME"] = HOME
    environment.setdefault("PATH", "/usr/local/bin:/usr/bin:/bin")
    return environment


def _safe_path(path: str) -> pathlib.Path:
    candidate = pathlib.Path(path).expanduser()
    if not is_safe_path(str(candidate)):
        raise ValueError(f"Acceso denegado: solo se permite dentro de {HOME}")
    return candidate.resolve()


def _validate_document_container(path: pathlib.Path) -> str | None:
    """Rechaza firmas falsas y contenedores OOXML con expansión peligrosa."""
    suffix = path.suffix.lower()
    if suffix == ".pdf":
        with path.open("rb") as document:
            if not document.read(5).startswith(b"%PDF-"):
                return "el archivo no contiene una firma PDF válida"
        return None

    required_entry = _OOXML_REQUIRED_ENTRIES.get(suffix)
    if required_entry is None:
        return None
    try:
        with zipfile.ZipFile(path) as archive:
            entries = archive.infolist()
            if len(entries) > MAX_ARCHIVE_ENTRIES:
                return "el documento contiene demasiadas entradas internas"
            names = {entry.filename for entry in entries}
            if required_entry not in names or "[Content_Types].xml" not in names:
                return "el contenedor OOXML no corresponde con su extensión"
            expanded_size = 0
            for entry in entries:
                parts = pathlib.PurePosixPath(entry.filename).parts
                if entry.filename.startswith("/") or ".." in parts:
                    return "el documento contiene rutas internas inseguras"
                if entry.flag_bits & 0x1:
                    return "los documentos OOXML cifrados no están soportados"
                expanded_size += entry.file_size
                if expanded_size > MAX_ARCHIVE_EXPANDED_BYTES:
                    return "el documento se expande por encima del límite seguro"
                if (
                    entry.file_size > 1024 * 1024
                    and entry.file_size / max(1, entry.compress_size) > 1000
                ):
                    return "el documento tiene una relación de compresión insegura"
    except (OSError, zipfile.BadZipFile):
        return "el archivo no es un contenedor OOXML válido"
    return None


def _sanitize_pandoc_ast(value):
    """Elimina nodos que podrían cargar archivos o inyectar formatos raw."""
    if isinstance(value, list):
        return [_sanitize_pandoc_ast(item) for item in value]
    if not isinstance(value, dict):
        return value

    node_type = value.get("t")
    contents = value.get("c")
    if node_type == "Image":
        alternative = (
            contents[1]
            if isinstance(contents, list)
            and len(contents) > 1
            and isinstance(contents[1], list)
            else [{"t": "Str", "c": "[imagen omitida]"}]
        )
        return {
            "t": "Span",
            "c": [["", [], []], _sanitize_pandoc_ast(alternative)],
        }
    if node_type == "RawInline":
        return {"t": "Str", "c": "[contenido raw omitido]"}
    if node_type == "RawBlock":
        return {
            "t": "Para",
            "c": [{"t": "Str", "c": "[contenido raw omitido]"}],
        }
    return {
        key: _sanitize_pandoc_ast(item)
        for key, item in value.items()
    }


def _atomic_write_text(path: pathlib.Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not is_safe_path(str(path.parent)):
        raise ValueError(f"Acceso denegado: solo se permite dentro de {HOME}")
    temp_name = ""
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            delete=False,
        ) as temp_file:
            temp_file.write(content)
            temp_file.flush()
            temp_name = temp_file.name
        pathlib.Path(temp_name).chmod(0o600)
        pathlib.Path(temp_name).replace(path)
    finally:
        if temp_name:
            pathlib.Path(temp_name).unlink(missing_ok=True)


def tool_list_dir(path: str) -> str:
    try:
        directory = _safe_path(path)
        if not directory.is_dir():
            return f"Error: no es un directorio: {directory}"
        lines = [f"Directorio: {directory}"]
        with os.scandir(directory) as entries:
            for index, entry in enumerate(entries):
                if index >= 200:
                    lines.append("… listado limitado a 200 entradas")
                    break
                try:
                    kind = "d" if entry.is_dir(follow_symlinks=False) else "f"
                    size = entry.stat(follow_symlinks=False).st_size
                except OSError:
                    kind, size = "?", 0
                lines.append(f"{kind} {size:>10} {entry.name}")
                if sum(map(len, lines)) >= MAX_DIR:
                    lines.append("… salida truncada")
                    break
        return "\n".join(lines)[:MAX_DIR]
    except (OSError, ValueError) as e:
        return f"Error al listar directorio: {e}"


def tool_file_info(path: str) -> str:
    """Devuelve metadatos del archivo: total de líneas y tamaño.
    Usar antes de read_file para decidir qué rango de líneas pedir."""
    try:
        p = _safe_path(path)
        exp = str(p)
        if not p.exists():
            return f"No existe: {exp}"
        if p.is_dir():
            return "Es un directorio, no un archivo"
        if not p.is_file():
            return "No es un archivo regular"
        size_bytes = p.stat().st_size
        if size_bytes >= 1_048_576:
            size_str = f"{size_bytes / 1_048_576:.1f} MB"
        elif size_bytes >= 1_024:
            size_str = f"{size_bytes / 1_024:.1f} KB"
        else:
            size_str = f"{size_bytes} B"
        if size_bytes > MAX_TEXT_BYTES:
            total_lines = "no contado (archivo demasiado grande)"
        else:
            with p.open("r", encoding="utf-8", errors="replace") as file:
                total_lines = sum(1 for _ in file)
        return (
            f"Archivo: {exp}\n"
            f"Líneas totales: {total_lines}\n"
            f"Tamaño: {size_str}\n"
            "Sugerencia: usa read_file con start_line y end_line para leer "
            "en bloques de hasta 200 líneas."
        )
    except (OSError, ValueError) as e:
        return f"Error obteniendo info del archivo: {e}"


def tool_read_file(path: str, start_line: int = 1, end_line: int = None) -> str:
    """Lee un archivo de texto en un rango de líneas específico.

    Args:
        path:       Ruta absoluta del archivo.
        start_line: Primera línea a leer (1-indexado). Por defecto 1.
        end_line:   Última línea a leer (1-indexado, inclusivo).
                    Por defecto start_line + 199 (chunk de 200 líneas).
    """
    try:
        p = _safe_path(path)
        exp = str(p)
        if not p.exists():
            return f"No existe: {exp}"
        if p.is_dir():
            return "Es un directorio; usa list_dir en su lugar"
        if not p.is_file():
            return "No es un archivo regular"
        if p.stat().st_size > MAX_TEXT_BYTES:
            return f"Error: el archivo supera el límite de {MAX_TEXT_BYTES} bytes"

        # Normalizar parámetros
        start_line = max(1, int(start_line))
        if end_line is None:
            end_line = start_line + MAX_READ_LINES - 1
        else:
            end_line = max(start_line, int(end_line))
            end_line = min(end_line, start_line + MAX_READ_LINES - 1)

        lines_out = []
        total_lines = 0

        with p.open("r", encoding="utf-8", errors="replace") as f:
            for lineno, line in enumerate(f, start=1):
                total_lines = lineno
                if lineno < start_line:
                    continue
                if lineno > end_line:
                    break
                lines_out.append(f"{lineno}: {line.rstrip()}")
            else:
                pass

        # EOF: start_line supera el total del archivo
        if start_line > total_lines:
            return (
                f"[EOF] El archivo tiene {total_lines} líneas. "
                f"start_line={start_line} supera el total."
            )

        # Encabezado con metadatos
        shown_end = min(end_line, total_lines)
        header = (
            f"Archivo: {exp} | Mostrando líneas {start_line}–{shown_end}\n"
            f"{'─' * 60}"
        )

        body = "\n".join(lines_out)

        footer = (
            f"\n[Continúa en línea {end_line + 1}]"
            if total_lines > end_line
            else f"\n[EOF alcanzado en línea {total_lines}]"
        )

        return f"{header}\n{body}{footer}"

    except (OSError, TypeError, ValueError) as e:
        return f"Error leyendo archivo: {e}"


def _read_with_markitdown(
    path: str,
    file_type: str,
    allowed_extensions: set[str] | None = None,
) -> str:
    try:
        p = _safe_path(path)
        exp = str(p)
        if not p.exists() or not p.is_file():
            return f"Archivo inválido o no existe: {exp}"
        if allowed_extensions and p.suffix.lower() not in allowed_extensions:
            expected = ", ".join(sorted(allowed_extensions))
            return f"Error leyendo {file_type}: extensión permitida: {expected}"
        if p.stat().st_size > MAX_DOCUMENT_BYTES:
            return f"Error: el documento supera el límite de {MAX_DOCUMENT_BYTES} bytes"
        container_error = _validate_document_container(p)
        if container_error:
            return f"Error leyendo {file_type}: {container_error}"

        with (
            tempfile.TemporaryFile() as stdout_file,
            tempfile.TemporaryFile() as stderr_file,
        ):
            result = subprocess.run(
                [sys.executable, "-m", "markitdown", exp],
                stdout=stdout_file,
                stderr=stderr_file,
                timeout=45,
                check=False,
                env=_document_environment(),
                start_new_session=True,
            )
            if result.returncode != 0:
                stderr_file.seek(0)
                error_text = stderr_file.read(1000).decode(
                    "utf-8",
                    errors="replace",
                )
                return f"Error leyendo {file_type}: {error_text}"
            stdout_file.seek(0)
            raw_text = stdout_file.read(MAX_EXTRACTED_CHARS + 1)
        text = raw_text[:MAX_EXTRACTED_CHARS].decode("utf-8", errors="replace")
        if len(raw_text) > MAX_EXTRACTED_CHARS:
            text += "\n[Contenido extraído truncado]"
        return text or (
            f"[El archivo {file_type} está vacío o no se pudo extraer texto]"
        )
    except subprocess.TimeoutExpired:
        return f"Error leyendo {file_type}: tiempo máximo excedido"
    except (OSError, ValueError) as e:
        return f"Error leyendo {file_type}: {e}"


def tool_read_pdf(path: str) -> str:
    return _read_with_markitdown(path, "PDF", {".pdf"})


def _read_docx_with_pandoc(path: str) -> str:
    """Convierte .docx a Markdown usando pandoc (mismo ejecutable que create_docx)."""
    try:
        p = _safe_path(path)
        exp = str(p)
        if not p.exists() or not p.is_file():
            return f"Archivo inválido o no existe: {exp}"
        if p.suffix.lower() not in _DOCUMENT_EXTENSIONS:
            expected = ", ".join(sorted(_DOCUMENT_EXTENSIONS))
            return f"Error leyendo DOCX: extensión permitida: {expected}"
        if p.stat().st_size > MAX_DOCUMENT_BYTES:
            return f"Error: el documento supera el límite de {MAX_DOCUMENT_BYTES} bytes"
        container_error = _validate_document_container(p)
        if container_error:
            return f"Error leyendo DOCX: {container_error}"

        if not shutil.which("pandoc"):
            # Fallback a markitdown si pandoc no está disponible
            return _read_with_markitdown(path, "DOCX", _DOCUMENT_EXTENSIONS)

        with (
            tempfile.TemporaryDirectory(
                prefix=".minerva-pandoc-home-",
            ) as pandoc_home,
            tempfile.TemporaryFile() as stdout_file,
            tempfile.TemporaryFile() as stderr_file,
        ):
            pandoc_env = _document_environment()
            pandoc_env["HOME"] = pandoc_home
            result = subprocess.run(
                [
                    "pandoc",
                    "--sandbox",
                    "--from=docx",
                    "--to=markdown",
                    exp,
                ],
                stdout=stdout_file,
                stderr=stderr_file,
                timeout=45,
                check=False,
                env=pandoc_env,
                start_new_session=True,
            )
            if result.returncode != 0:
                stderr_file.seek(0)
                error_text = stderr_file.read(1000).decode("utf-8", errors="replace").strip()
                return f"Error leyendo DOCX: {error_text}"
            stdout_file.seek(0)
            raw_text = stdout_file.read(MAX_EXTRACTED_CHARS + 1)
        text = raw_text[:MAX_EXTRACTED_CHARS].decode("utf-8", errors="replace")
        if len(raw_text) > MAX_EXTRACTED_CHARS:
            text += "\n[Contenido extraído truncado]"
        return text or "[El archivo DOCX está vacío o no se pudo extraer texto]"
    except subprocess.TimeoutExpired:
        return "Error leyendo DOCX: tiempo máximo excedido"
    except (OSError, ValueError) as e:
        return f"Error leyendo DOCX: {e}"


def tool_read_docx(path: str) -> str:
    return _read_docx_with_pandoc(path)


def tool_read_pptx(path: str) -> str:
    return _read_with_markitdown(path, "PPTX", _PRESENTATION_EXTENSIONS)


def tool_read_excel(path: str) -> str:
    return _read_with_markitdown(
        path,
        "EXCEL/CSV",
        _SPREADSHEET_EXTENSIONS,
    )


# ─────────────────────────────────────────────────────────────────────────────
# RAG Efímero
# ─────────────────────────────────────────────────────────────────────────────

def _chunk_text(text: str, chunk_size: int = 1000, overlap: int = 200) -> list[str]:
    """Divide texto en chunks de tamaño fijo con solapamiento.

    Intenta respetar párrafos (doble newline) antes de cortar por caracteres.
    El solapamiento asegura que ningún dato importante quede partido entre dos chunks.
    """
    if not text:
        return []

    # Normalizar saltos de línea excesivos para reducir ruido
    import re
    text = re.sub(r"\n{3,}", "\n\n", text).strip()

    if len(text) <= chunk_size:
        return [text]

    chunks: list[str] = []
    start = 0
    text_len = len(text)

    while start < text_len:
        end = min(start + chunk_size, text_len)

        # Si no llegamos al final, buscar un salto de párrafo limpio
        if end < text_len:
            # Buscar el último doble-newline dentro del chunk
            cut = text.rfind("\n\n", start, end)
            if cut != -1 and cut > start + overlap:
                end = cut + 2  # incluir el doble newline para no perder contexto
            else:
                # Si no hay párrafo, buscar el último espacio
                cut = text.rfind(" ", start, end)
                if cut != -1 and cut > start + overlap:
                    end = cut + 1

        chunks.append(text[start:end].strip())
        # Avanzar con solapamiento
        start = max(start + 1, end - overlap)

    return [c for c in chunks if c]


def tool_query_document(path: str, query: str, top_k: int = 5) -> str:
    """Busca respuestas semánticas dentro de un documento sin leerlo completo.

    Pipeline: archivo → MarkItDown → chunks → ChromaDB en memoria → top-K relevantes.
    Soporta PDF, DOCX y PPTX.
    NO soporta Excel/CSV (usa read_excel para esos).

    Args:
        path:  Ruta absoluta del documento a consultar.
        query: La pregunta o búsqueda semántica a resolver.
        top_k: Número de fragmentos más relevantes a retornar (por defecto 5).
    """
    try:
        p = _safe_path(path)
    except ValueError as e:
        return str(e)
    if not p.exists() or not p.is_file():
        return f"Archivo no encontrado: {p}"
    try:
        if p.stat().st_size > MAX_DOCUMENT_BYTES:
            return (
                "Error: el documento supera el límite de "
                f"{MAX_DOCUMENT_BYTES} bytes"
            )
    except OSError as exc:
        return f"Error inspeccionando documento: {exc}"

    ext = p.suffix.lower()
    if ext not in _RAG_SUPPORTED_EXTENSIONS:
        return (
            f"Formato '{ext}' no soportado por query_document. "
            "Para texto plano (MD, TXT, RST...) usa read_file con "
            "start_line/end_line. "
            f"Para Excel/CSV usa read_excel. "
            f"Formatos soportados: {', '.join(sorted(_RAG_SUPPORTED_EXTENSIONS))}"
        )

    # ── 1. Extraer texto ───────────────────────────────────────────────────────────
    if ext in _DOCUMENT_EXTENSIONS:
        # DOCX: usar pandoc (más robusto que markitdown para este formato)
        text = _read_docx_with_pandoc(str(p))
    else:
        text = _read_with_markitdown(
            str(p),
            "documento",
            _RAG_SUPPORTED_EXTENSIONS,
        )
    if text.startswith("Error"):
        return text

    if not text.strip():
        return f"El documento '{p.name}' no contiene texto extraíble."

    # ── 2. Chunking ───────────────────────────────────────────────────────────
    chunks = _chunk_text(text, chunk_size=1000, overlap=200)
    if not chunks:
        return "No se pudo dividir el documento en fragmentos."

    # ── 3. ChromaDB en memoria (efímero) ──────────────────────────────────────
    try:
        import chromadb
    except ImportError:
        return "Error: chromadb no está instalado (pip install chromadb)."

    try:
        client = chromadb.EphemeralClient()
        # Nombre de colección único por archivo para evitar colisiones
        collection_name = f"rag_{p.stem[:40].replace(' ', '_')}"
        collection = client.create_collection(name=collection_name)

        ids = [f"chunk_{i}" for i in range(len(chunks))]
        collection.add(documents=chunks, ids=ids)

        top_k = max(1, min(int(top_k), len(chunks)))
        results = collection.query(query_texts=[query], n_results=top_k)
    except Exception as e:
        return f"Error en RAG efímero: {e}"

    # ── 4. Formatear respuesta ────────────────────────────────────────────────
    docs = results.get("documents", [[]])[0]
    distances = results.get("distances", [[]])[0]

    if not docs:
        return f"No se encontraron fragmentos relevantes para: '{query}'"

    lines = [
        f"Resultados de búsqueda en '{p.name}' para: \"{query}\"",
        f"({len(docs)} fragmento(s) relevantes de {len(chunks)} totales)",
        "─" * 60,
    ]
    for i, (doc, dist) in enumerate(zip(docs, distances), 1):
        relevance = max(0.0, 1.0 - dist)
        lines.append(f"\n[Fragmento {i} — relevancia {relevance:.0%}]")
        lines.append(doc)

    return "\n".join(lines)


def tool_write_file(path: str, content: str, overwrite: bool = False) -> str:
    """Crea o sobreescribe un archivo con el contenido dado.

    Args:
        path:      Ruta absoluta del archivo a crear/sobreescribir.
        content:   Contenido completo a escribir.
        overwrite: Si False (defecto) y el archivo ya existe, retorna error.
                   Pasar True para sobreescribir intencionalmente.
    """
    try:
        if len(content.encode("utf-8")) > MAX_TEXT_BYTES:
            return f"Error: el contenido supera el límite de {MAX_TEXT_BYTES} bytes"
        p = _safe_path(path)
        exp = str(p)
        existed = p.exists()
        p.parent.mkdir(parents=True, exist_ok=True)
        if not is_safe_path(str(p.parent)):
            return f"Acceso denegado: solo se permite dentro de {HOME}"
        if overwrite:
            _atomic_write_text(p, content)
        else:
            try:
                with p.open("x", encoding="utf-8") as file:
                    file.write(content)
                p.chmod(0o600)
            except FileExistsError:
                return (
                    f"Error: el archivo ya existe en {exp}. "
                    "Usa overwrite=true para sobreescribirlo intencionalmente."
                )
        total_lines = content.count("\n") + (
            1 if content and not content.endswith("\n") else 0
        )
        action = "sobreescrito" if existed else "creado"
        return f"Archivo {action}: {exp} ({total_lines} líneas escritas)"
    except (OSError, ValueError) as e:
        return f"Error escribiendo archivo: {e}"


def tool_replace_lines(
    path: str,
    start_line: int,
    end_line: int,
    new_content: str,
) -> str:
    """Reemplaza un rango de líneas en un archivo existente.

    Equivalente a un patch quirúrgico: sustituye las líneas [start_line, end_line]
    (1-indexado, inclusivo) por new_content, sin tocar el resto del archivo.

    Args:
        path:        Ruta absoluta del archivo a modificar.
        start_line:  Primera línea a reemplazar (1-indexado).
        end_line:    Última línea a reemplazar (1-indexado, inclusivo).
        new_content: Texto de reemplazo. Puede ser una o varias líneas.
                     No necesita terminar con \\n; se añade automáticamente.
    """
    try:
        if len(new_content.encode("utf-8")) > MAX_TEXT_BYTES:
            return (
                "Error: el contenido nuevo supera el límite de "
                f"{MAX_TEXT_BYTES} bytes"
            )
        p = _safe_path(path)
        exp = str(p)
        if not p.exists():
            return f"No existe: {exp}"
        if not p.is_file():
            return "No es un archivo regular"
        if p.stat().st_size > MAX_TEXT_BYTES:
            return f"Error: el archivo supera el límite de {MAX_TEXT_BYTES} bytes"

        start_line = max(1, int(start_line))
        end_line   = max(start_line, int(end_line))

        with open(exp, "r", encoding="utf-8", errors="replace") as f:
            original_lines = f.readlines()

        total_original = len(original_lines)

        if start_line > total_original:
            return (
                f"[EOF] El archivo tiene {total_original} líneas. "
                f"start_line={start_line} supera el total."
            )

        # Asegurar que el nuevo contenido termina con \n
        replacement = new_content if new_content.endswith("\n") else new_content + "\n"
        replacement_lines = replacement.splitlines(keepends=True)

        # Splice: antes del rango + reemplazo + después del rango
        new_lines = (
            original_lines[:start_line - 1]
            + replacement_lines
            + original_lines[end_line:]
        )

        if len("".join(new_lines).encode("utf-8")) > MAX_TEXT_BYTES:
            return (
                "Error: el archivo resultante supera el límite de "
                f"{MAX_TEXT_BYTES} bytes"
            )

        _atomic_write_text(p, "".join(new_lines))

        removed  = end_line - start_line + 1
        added    = len(replacement_lines)
        total_new = len(new_lines)

        return (
            f"Reemplazo exitoso en {exp}\n"
            f"Líneas {start_line}–{end_line} reemplazadas "
            f"(-{removed} línea(s) → +{added} línea(s))\n"
            f"Total líneas: {total_original} → {total_new}"
        )
    except (OSError, TypeError, ValueError) as e:
        return f"Error reemplazando líneas: {e}"


def _set_docx_font(style, name: str, size, color: str | None = None) -> None:
    """Aplica una fuente también a los fallbacks tipográficos de Word."""
    from docx.oxml.ns import qn

    style.font.name = name
    style.font.size = size
    if color:
        from docx.shared import RGBColor

        style.font.color.rgb = RGBColor.from_string(color)
    fonts = style.element.get_or_add_rPr().get_or_add_rFonts()
    for attribute in ("ascii", "hAnsi", "eastAsia", "cs"):
        fonts.set(qn(f"w:{attribute}"), name)


def _set_keep_options(
    style,
    *,
    keep_next: bool = False,
    keep_lines: bool = False,
) -> None:
    """Evita títulos huérfanos y cortes tipográficos poco elegantes."""
    from docx.oxml import OxmlElement
    from docx.oxml.ns import qn

    paragraph_properties = style.element.get_or_add_pPr()
    options = [("widowControl", True)]
    if keep_next:
        options.append(("keepNext", True))
    if keep_lines:
        options.append(("keepLines", True))
    for tag, enabled in options:
        element = paragraph_properties.find(qn(f"w:{tag}"))
        if element is None:
            element = OxmlElement(f"w:{tag}")
            paragraph_properties.append(element)
        element.set(qn("w:val"), "1" if enabled else "0")


def _add_style_border(style, *, side: str, color: str, size: int) -> None:
    """Añade un borde discreto a un estilo de párrafo."""
    from docx.oxml import OxmlElement
    from docx.oxml.ns import qn

    paragraph_properties = style.element.get_or_add_pPr()
    borders = paragraph_properties.find(qn("w:pBdr"))
    if borders is None:
        borders = OxmlElement("w:pBdr")
        paragraph_properties.append(borders)
    border = OxmlElement(f"w:{side}")
    border.set(qn("w:val"), "single")
    border.set(qn("w:sz"), str(size))
    border.set(qn("w:space"), "4")
    border.set(qn("w:color"), color)
    borders.append(border)


def _create_elegant_docx_reference(path: pathlib.Path) -> None:
    """Genera el reference.docx sobrio que usa create_docx por defecto.

    Mantener la plantilla como código evita versionar un binario opaco y deja
    todos los criterios visuales auditables junto a la herramienta.
    """
    from docx import Document
    from docx.enum.style import WD_STYLE_TYPE
    from docx.enum.text import WD_ALIGN_PARAGRAPH
    from docx.oxml import OxmlElement
    from docx.oxml.ns import qn
    from docx.shared import Cm, Pt

    document = Document()
    section = document.sections[0]
    # Carta (8.5 × 11 in): se fija explícitamente para que OnlyOffice no
    # sustituya el tamaño por A4 al abrir documentos nuevos.
    section.page_width = Cm(21.59)
    section.page_height = Cm(27.94)
    section.top_margin = Cm(2.35)
    section.bottom_margin = Cm(2.25)
    section.left_margin = Cm(2.45)
    section.right_margin = Cm(2.45)
    section.header_distance = Cm(1.1)
    section.footer_distance = Cm(1.15)

    styles = document.styles

    def paragraph_style(name: str, base: str | None = None):
        try:
            style = styles[name]
        except KeyError:
            style = styles.add_style(name, WD_STYLE_TYPE.PARAGRAPH)
        if base:
            style.base_style = styles[base]
        return style

    normal = styles["Normal"]
    _set_docx_font(normal, "Noto Serif", Pt(10.5), "2F3437")
    normal.paragraph_format.alignment = WD_ALIGN_PARAGRAPH.JUSTIFY
    normal.paragraph_format.line_spacing = 1.18
    normal.paragraph_format.space_after = Pt(7)
    _set_keep_options(normal)

    for name in ("Body Text", "First Paragraph"):
        style = paragraph_style(name, "Normal")
        _set_docx_font(style, "Noto Serif", Pt(10.5), "2F3437")
        style.paragraph_format.alignment = WD_ALIGN_PARAGRAPH.JUSTIFY
        style.paragraph_format.line_spacing = 1.18
        style.paragraph_format.space_after = Pt(7)
        _set_keep_options(style)

    compact = paragraph_style("Compact", "Normal")
    _set_docx_font(compact, "Noto Serif", Pt(10), "2F3437")
    compact.paragraph_format.alignment = WD_ALIGN_PARAGRAPH.LEFT
    compact.paragraph_format.line_spacing = 1.1
    compact.paragraph_format.space_after = Pt(3)
    _set_keep_options(compact)

    title = styles["Title"]
    _set_docx_font(title, "Noto Serif Display", Pt(30), "243447")
    title.font.bold = True
    title.paragraph_format.alignment = WD_ALIGN_PARAGRAPH.LEFT
    title.paragraph_format.space_before = Pt(20)
    title.paragraph_format.space_after = Pt(8)
    _set_keep_options(title, keep_next=True, keep_lines=True)

    subtitle = styles["Subtitle"]
    _set_docx_font(subtitle, "Noto Serif", Pt(12), "6B7074")
    subtitle.font.italic = True
    subtitle.paragraph_format.alignment = WD_ALIGN_PARAGRAPH.LEFT
    subtitle.paragraph_format.space_after = Pt(16)
    _set_keep_options(subtitle, keep_next=True)

    heading_specs = {
        "Heading 1": (20, "243447", 22, 8),
        "Heading 2": (14, "9A5F3A", 17, 6),
        "Heading 3": (11.5, "3E4A50", 13, 4),
        "Heading 4": (10.5, "3E4A50", 10, 3),
    }
    for name, (size, color, before, after) in heading_specs.items():
        style = styles[name]
        _set_docx_font(style, "Noto Sans", Pt(size), color)
        style.font.bold = True
        style.paragraph_format.alignment = WD_ALIGN_PARAGRAPH.LEFT
        style.paragraph_format.space_before = Pt(before)
        style.paragraph_format.space_after = Pt(after)
        style.paragraph_format.keep_with_next = True
        style.paragraph_format.keep_together = True
        _set_keep_options(style, keep_next=True, keep_lines=True)
    _add_style_border(styles["Heading 1"], side="bottom", color="C9A27E", size=8)

    list_paragraph = styles["List Paragraph"]
    _set_docx_font(list_paragraph, "Noto Serif", Pt(10.5), "2F3437")
    list_paragraph.paragraph_format.line_spacing = 1.12
    list_paragraph.paragraph_format.space_after = Pt(4)
    _set_keep_options(list_paragraph)

    for name in ("Quote", "Block Text"):
        style = paragraph_style(name, "Normal")
        _set_docx_font(style, "Noto Serif", Pt(10.5), "596166")
        style.font.italic = True
        style.paragraph_format.alignment = WD_ALIGN_PARAGRAPH.JUSTIFY
        style.paragraph_format.left_indent = Cm(0.65)
        style.paragraph_format.right_indent = Cm(0.25)
        style.paragraph_format.space_before = Pt(6)
        style.paragraph_format.space_after = Pt(9)
        _add_style_border(style, side="left", color="C9A27E", size=12)
        _set_keep_options(style)

    for name in ("Caption", "Table Caption"):
        style = paragraph_style(name, "Normal")
        _set_docx_font(style, "Noto Serif", Pt(8.5), "6B7074")
        style.font.italic = True
        style.paragraph_format.alignment = WD_ALIGN_PARAGRAPH.CENTER
        style.paragraph_format.space_before = Pt(4)
        style.paragraph_format.space_after = Pt(8)
        _set_keep_options(style, keep_next=name == "Table Caption")

    try:
        hyperlink = styles["Hyperlink"]
    except KeyError:
        hyperlink = styles.add_style("Hyperlink", WD_STYLE_TYPE.CHARACTER)
    _set_docx_font(hyperlink, "Noto Serif", Pt(10.5), "8A5737")
    hyperlink.font.underline = True

    table_style = styles.add_style("Table", WD_STYLE_TYPE.TABLE)
    _set_docx_font(table_style, "Noto Serif", Pt(9.5), "2F3437")
    table_properties = OxmlElement("w:tblPr")
    table_cell_margin = OxmlElement("w:tblCellMar")
    for side, width in (("top", 90), ("left", 120), ("bottom", 90), ("right", 120)):
        margin = OxmlElement(f"w:{side}")
        margin.set(qn("w:w"), str(width))
        margin.set(qn("w:type"), "dxa")
        table_cell_margin.append(margin)
    table_properties.append(table_cell_margin)
    borders = OxmlElement("w:tblBorders")
    for side, color, size in (
        ("top", "243447", 8),
        ("bottom", "243447", 8),
        ("insideH", "D8D3CC", 4),
        ("insideV", "E7E3DE", 4),
    ):
        border = OxmlElement(f"w:{side}")
        border.set(qn("w:val"), "single")
        border.set(qn("w:sz"), str(size))
        border.set(qn("w:color"), color)
        borders.append(border)
    table_properties.append(borders)
    table_style.element.append(table_properties)

    first_row = OxmlElement("w:tblStylePr")
    first_row.set(qn("w:type"), "firstRow")
    row_cell_properties = OxmlElement("w:tcPr")
    row_shading = OxmlElement("w:shd")
    row_shading.set(qn("w:val"), "clear")
    row_shading.set(qn("w:fill"), "243447")
    row_cell_properties.append(row_shading)
    first_row.append(row_cell_properties)
    row_run_properties = OxmlElement("w:rPr")
    row_bold = OxmlElement("w:b")
    row_color = OxmlElement("w:color")
    row_color.set(qn("w:val"), "FFFFFF")
    row_run_properties.extend((row_bold, row_color))
    first_row.append(row_run_properties)
    table_style.element.append(first_row)

    banded_row = OxmlElement("w:tblStylePr")
    banded_row.set(qn("w:type"), "band1Horz")
    banded_cell_properties = OxmlElement("w:tcPr")
    banded_shading = OxmlElement("w:shd")
    banded_shading.set(qn("w:val"), "clear")
    banded_shading.set(qn("w:fill"), "F3F0EB")
    banded_cell_properties.append(banded_shading)
    banded_row.append(banded_cell_properties)
    table_style.element.append(banded_row)

    footer = section.footer.paragraphs[0]
    footer.alignment = WD_ALIGN_PARAGRAPH.RIGHT
    footer.paragraph_format.space_before = Pt(4)
    footer_run = footer.add_run()
    footer_run.font.name = "Noto Serif"
    footer_run.font.size = Pt(8.5)
    from docx.shared import RGBColor

    footer_run.font.color.rgb = RGBColor.from_string("777777")
    field_begin = OxmlElement("w:fldChar")
    field_begin.set(qn("w:fldCharType"), "begin")
    field_instruction = OxmlElement("w:instrText")
    field_instruction.set(qn("xml:space"), "preserve")
    field_instruction.text = " PAGE "
    field_end = OxmlElement("w:fldChar")
    field_end.set(qn("w:fldCharType"), "end")
    footer_run._r.extend((field_begin, field_instruction, field_end))
    _add_style_border(styles["Footer"], side="top", color="D8D3CC", size=4)

    document.save(path)


def tool_create_docx(
    path: str,
    markdown_content: str,
    overwrite: bool = False,
) -> str:
    """Crea un DOCX desde Markdown con una plantilla editorial propia."""
    try:
        p = _safe_path(path)
    except ValueError as e:
        return str(e)
    exp = str(p)
    if p.suffix.lower() != ".docx":
        return "Error: create_docx requiere una ruta terminada en .docx"
    if p.exists() and not overwrite:
        return "Error: el archivo ya existe; usa overwrite=true para reemplazarlo"

    if not shutil.which("pandoc"):
        return (
            "Error: pandoc no está instalado en el sistema. "
            "Instálalo con 'sudo pacman -S pandoc'."
        )
    try:
        markdown_bytes = markdown_content.encode("utf-8")
    except (AttributeError, UnicodeError):
        return "Error: markdown_content debe ser texto UTF-8 válido"
    if len(markdown_bytes) > MAX_TEXT_BYTES:
        return (
            "Error: el contenido Markdown supera el límite de "
            f"{MAX_TEXT_BYTES} bytes"
        )

    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(
            suffix=".docx",
            dir=p.parent,
            delete=False,
        ) as temporary:
            temp_path = pathlib.Path(temporary.name)
        try:
            with tempfile.TemporaryDirectory(
                dir=p.parent,
                prefix=".minerva-pandoc-home-",
            ) as pandoc_home:
                pandoc_environment = _document_environment()
                pandoc_environment["HOME"] = pandoc_home
                reference_path = pathlib.Path(pandoc_home) / "reference.docx"
                try:
                    _create_elegant_docx_reference(reference_path)
                except ImportError:
                    return (
                        "Error: python-docx no está instalado; se necesita para "
                        "crear la plantilla visual de Word."
                    )
                with (
                    tempfile.TemporaryFile() as ast_file,
                    tempfile.TemporaryFile() as parser_error,
                ):
                    parse_result = subprocess.run(
                        [
                            "pandoc",
                            "--sandbox",
                            "--from=markdown",
                            "--to=json",
                        ],
                        input=markdown_bytes,
                        stdout=ast_file,
                        stderr=parser_error,
                        timeout=30,
                        check=False,
                        env=pandoc_environment,
                        start_new_session=True,
                    )
                    if parse_result.returncode != 0:
                        parser_error.seek(0)
                        detail = parser_error.read(1000).decode(
                            "utf-8",
                            errors="replace",
                        ).strip()
                        return (
                            "Error interpretando Markdown con pandoc: "
                            f"{detail or f'código {parse_result.returncode}'}"
                        )
                    ast_file.seek(0)
                    raw_ast = ast_file.read(MAX_PANDOC_AST_BYTES + 1)
                if len(raw_ast) > MAX_PANDOC_AST_BYTES:
                    return "Error: el AST generado por pandoc es demasiado grande."
                try:
                    ast = json.loads(raw_ast.decode("utf-8"))
                    safe_ast = json.dumps(
                        _sanitize_pandoc_ast(ast),
                        ensure_ascii=False,
                        separators=(",", ":"),
                    ).encode("utf-8")
                except (json.JSONDecodeError, UnicodeDecodeError, ValueError):
                    return "Error: pandoc produjo un AST JSON inválido."
                if len(safe_ast) > MAX_PANDOC_AST_BYTES:
                    return "Error: el AST saneado de pandoc es demasiado grande."

                with tempfile.TemporaryFile() as writer_error:
                    result = subprocess.run(
                        [
                            "pandoc",
                            "--from=json",
                            "--to=docx",
                            f"--reference-doc={reference_path}",
                            "--output",
                            str(temp_path),
                        ],
                        input=safe_ast,
                        stdout=subprocess.DEVNULL,
                        stderr=writer_error,
                        timeout=45,
                        check=False,
                        env=pandoc_environment,
                        start_new_session=True,
                    )
                    if result.returncode != 0:
                        writer_error.seek(0)
                        detail = writer_error.read(1000).decode(
                            "utf-8",
                            errors="replace",
                        ).strip()
                        return (
                            "Error creando archivo Word con pandoc: "
                            f"{detail or f'código {result.returncode}'}"
                        )
            if temp_path.stat().st_size > MAX_DOCUMENT_BYTES:
                return (
                    "Error: el documento generado supera el límite de "
                    f"{MAX_DOCUMENT_BYTES} bytes"
                )
            temp_path.chmod(0o600)
            if overwrite:
                temp_path.replace(p)
            else:
                try:
                    os.link(temp_path, p)
                except FileExistsError:
                    return (
                        "Error: el archivo apareció durante la conversión; "
                        "usa overwrite=true para reemplazarlo"
                    )
                temp_path.unlink()
        finally:
            temp_path.unlink(missing_ok=True)
        return f"Archivo Word creado exitosamente en: {exp}"
    except subprocess.TimeoutExpired:
        return "Error creando archivo Word: pandoc excedió 45 segundos."
    except (OSError, TypeError, ValueError) as exc:
        return f"Error creando archivo Word: {type(exc).__name__}"


def tool_modify_docx(path: str, instruction: str) -> str:
    """Añade texto al final de un archivo .docx existente usando pandoc.

    Pipeline: docx → markdown → agregar texto → docx. El documento original se
    usa como referencia para conservar sus estilos, márgenes y encabezados.
    """
    try:
        p = _safe_path(path)
    except ValueError as e:
        return str(e)
    exp = str(p)
    if p.suffix.lower() != ".docx":
        return "Error: modify_docx requiere una ruta terminada en .docx"
    if not shutil.which("pandoc"):
        return (
            "Error: pandoc no está instalado en el sistema. "
            "Instálalo con 'sudo pacman -S pandoc'."
        )
    try:
        if not p.exists():
            return f"No existe: {exp}"
        if not p.is_file():
            return "No es un archivo regular"
        if p.stat().st_size > MAX_DOCUMENT_BYTES:
            return (
                "Error: el documento supera el límite de "
                f"{MAX_DOCUMENT_BYTES} bytes"
            )
        container_error = _validate_document_container(p)
        if container_error:
            return f"Error modificando DOCX: {container_error}"
        instruction_bytes = instruction.encode("utf-8", errors="replace")
        if len(instruction_bytes) > MAX_TEXT_BYTES:
            return (
                "Error: la instrucción supera el límite de "
                f"{MAX_TEXT_BYTES} bytes"
            )
    except (OSError, ValueError) as e:
        return f"Error validando DOCX: {e}"

    try:
        with tempfile.TemporaryDirectory(
            prefix=".minerva-pandoc-home-",
        ) as pandoc_home:
            pandoc_env = _document_environment()
            pandoc_env["HOME"] = pandoc_home

            # Paso 1: docx → markdown
            with (
                tempfile.TemporaryFile() as md_file,
                tempfile.TemporaryFile() as err_file,
            ):
                r1 = subprocess.run(
                    [
                        "pandoc",
                        "--sandbox",
                        "--from=docx",
                        "--to=markdown",
                        exp,
                    ],
                    stdout=md_file,
                    stderr=err_file,
                    timeout=45,
                    check=False,
                    env=pandoc_env,
                    start_new_session=True,
                )
                if r1.returncode != 0:
                    err_file.seek(0)
                    detail = err_file.read(1000).decode("utf-8", errors="replace").strip()
                    return f"Error leyendo DOCX para modificar: {detail}"
                md_file.seek(0)
                existing_md = md_file.read(MAX_PANDOC_AST_BYTES)

            if len(existing_md) >= MAX_PANDOC_AST_BYTES:
                return "Error: el documento es demasiado grande para modificar."

            # Paso 2: agregar el nuevo texto al markdown
            appended_md = existing_md + b"\n\n" + instruction_bytes
            if len(appended_md) > MAX_TEXT_BYTES:
                return "Error: el documento resultante supera el límite de tamaño."

            # Paso 3: markdown → AST JSON (saneado)
            with (
                tempfile.TemporaryFile() as ast_file,
                tempfile.TemporaryFile() as err_file,
            ):
                r2 = subprocess.run(
                    ["pandoc", "--sandbox", "--from=markdown", "--to=json"],
                    input=appended_md,
                    stdout=ast_file,
                    stderr=err_file,
                    timeout=30,
                    check=False,
                    env=pandoc_env,
                    start_new_session=True,
                )
                if r2.returncode != 0:
                    err_file.seek(0)
                    detail = err_file.read(1000).decode("utf-8", errors="replace").strip()
                    return f"Error interpretando Markdown con pandoc: {detail}"
                ast_file.seek(0)
                raw_ast = ast_file.read(MAX_PANDOC_AST_BYTES + 1)

            if len(raw_ast) > MAX_PANDOC_AST_BYTES:
                return "Error: el AST generado por pandoc es demasiado grande."
            try:
                ast = json.loads(raw_ast.decode("utf-8"))
                safe_ast = json.dumps(
                    _sanitize_pandoc_ast(ast),
                    ensure_ascii=False,
                    separators=(",", ":"),
                ).encode("utf-8")
            except (json.JSONDecodeError, UnicodeDecodeError, ValueError):
                return "Error: pandoc produjo un AST JSON inválido."

            # Paso 4: AST JSON → docx (en archivo temporal)
            with tempfile.NamedTemporaryFile(
                suffix=".docx",
                dir=p.parent,
                delete=False,
            ) as tmp:
                temp_path = pathlib.Path(tmp.name)
            try:
                with tempfile.TemporaryFile() as err_file:
                    r3 = subprocess.run(
                        [
                            "pandoc",
                            "--from=json",
                            "--to=docx",
                            f"--reference-doc={p}",
                            "--output",
                            str(temp_path),
                        ],
                        input=safe_ast,
                        stdout=subprocess.DEVNULL,
                        stderr=err_file,
                        timeout=45,
                        check=False,
                        env=pandoc_env,
                        start_new_session=True,
                    )
                    if r3.returncode != 0:
                        err_file.seek(0)
                        detail = err_file.read(1000).decode("utf-8", errors="replace").strip()
                        return f"Error creando archivo Word modificado: {detail}"
                if temp_path.stat().st_size > MAX_DOCUMENT_BYTES:
                    return "Error: el documento modificado supera el límite de tamaño."
                temp_path.chmod(0o600)
                temp_path.replace(p)
            finally:
                temp_path.unlink(missing_ok=True)

        return f"Archivo Word modificado exitosamente (texto añadido al final): {exp}"
    except subprocess.TimeoutExpired:
        return "Error modificando archivo Word: pandoc excedió el tiempo máximo."
    except (OSError, ValueError) as e:
        return f"Error modificando archivo Word: {type(e).__name__}: {e}"
