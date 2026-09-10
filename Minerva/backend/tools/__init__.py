#!/usr/bin/env python3
"""Registro público, selección semántica y despacho de tools de Minerva."""

from __future__ import annotations

import re
import sys
import threading
from typing import Any

from ..core.config import HOME
from ..core.io import classify_cmd, emit
from ..core.job_manager import CommandJob, job_mgr
from .definitions import FISH_AUDIO_EMOTION_PROMPT, SYSTEM_PROMPT, TOOL_DEFINITIONS
from .filesystem import (
    tool_create_docx,
    tool_file_info,
    tool_list_dir,
    tool_modify_docx,
    tool_query_document,
    tool_read_docx,
    tool_read_excel,
    tool_read_file,
    tool_read_pdf,
    tool_read_pptx,
    tool_replace_lines,
    tool_write_file,
)
from .memory_tool import tool_update_memory
from .registry import ToolRegistry
from .screen import ScreenCapture, tool_capture_screen
from .spotify import tool_spotify_music
from .system import (
    tool_check_job_status,
    tool_hyprland_control,
    tool_launch_app,
    tool_web_search,
)
from .tasks import tool_manage_tasks


# El cliente debe conservarse mientras viva la colección de ChromaDB.
_tool_client = None
_tool_collection = None
_tool_collection_initialized = False
_tool_collection_lock = threading.Lock()

# Siempre disponibles porque forman parte del control del agente. Las demás se
# recuperan semánticamente para no inflar cada petición a Gemini.
_ALWAYS_INCLUDE = {"manage_tasks", "run_command", "check_job_status"}
_DOCX_REQUEST = re.compile(r"\b(?:word|docx)\b", re.IGNORECASE)


def _ensure_tool_collection():
    """Inicializa los embeddings bajo demanda, nunca durante el arranque."""
    global _tool_client, _tool_collection, _tool_collection_initialized
    if _tool_collection_initialized:
        return _tool_collection
    with _tool_collection_lock:
        if _tool_collection_initialized:
            return _tool_collection
        _tool_collection_initialized = True
        try:
            import chromadb

            _tool_client = chromadb.EphemeralClient()
            _tool_collection = _tool_client.get_or_create_collection(
                name="minerva_tools"
            )
            _tool_collection.upsert(
                documents=[
                    tool["function"]["description"]
                    for tool in TOOL_DEFINITIONS
                ],
                ids=[
                    tool["function"]["name"]
                    for tool in TOOL_DEFINITIONS
                ],
            )
        except Exception as exc:
            print(
                "Error inicializando selección de tools: "
                f"{type(exc).__name__}",
                file=sys.stderr,
            )
        return _tool_collection


def get_relevant_tools(prompt: str, top_k: int = 8) -> list[dict]:
    """Selecciona capacidades relevantes; ante un fallo devuelve todas."""
    collection = _ensure_tool_collection() if prompt.strip() else None
    if collection is None:
        return TOOL_DEFINITIONS
    try:
        results = collection.query(
            query_texts=[prompt],
            n_results=min(top_k, len(TOOL_DEFINITIONS)),
        )
        if not results["ids"] or not results["ids"][0]:
            return TOOL_DEFINITIONS
        names = set(results["ids"][0]) | _ALWAYS_INCLUDE
        if _DOCX_REQUEST.search(prompt):
            # run_command siempre está disponible; garantiza que su alternativa
            # segura y especializada también lo esté para solicitudes de Word.
            names.update({"create_docx", "modify_docx"})
        return [
            tool
            for tool in TOOL_DEFINITIONS
            if tool["function"]["name"] in names
        ]
    except Exception as exc:
        print(
            f"Error consultando ChromaDB: {type(exc).__name__}",
            file=sys.stderr,
        )
        return TOOL_DEFINITIONS


# Conservado únicamente para compatibilidad con importadores antiguos.
class _RunCommandPending:
    pass


RUN_COMMAND_PENDING = _RunCommandPending()


ToolContext = dict[str, Any]
_registry = ToolRegistry(TOOL_DEFINITIONS)


def _emit_tool_event(context: ToolContext, event: dict) -> None:
    request_id = context.get("request_id", "")
    if request_id:
        event["request_id"] = request_id
    emit(event)


@_registry.register("generate_image")
def _generate_image(args: dict, context: ToolContext):
    from .imagen import tool_generate_image

    return tool_generate_image(
        prompt=args.get("prompt", ""),
        resolution=args.get("resolution", "1K"),
        api_key=context.get("api_key", ""),
    )


@_registry.register("list_dir")
def _list_dir(args: dict, _context: ToolContext):
    return tool_list_dir(args.get("path", HOME))


@_registry.register("read_file")
def _read_file(args: dict, _context: ToolContext):
    return tool_read_file(
        args.get("path", ""),
        start_line=args.get("start_line", 1),
        end_line=args.get("end_line"),
    )


@_registry.register("file_info")
def _file_info(args: dict, _context: ToolContext):
    return tool_file_info(args.get("path", ""))


@_registry.register("write_file")
def _write_file(args: dict, _context: ToolContext):
    return tool_write_file(
        path=args.get("path", ""),
        content=args.get("content", ""),
        overwrite=args.get("overwrite", False),
    )


@_registry.register("replace_lines")
def _replace_lines(args: dict, _context: ToolContext):
    return tool_replace_lines(
        path=args.get("path", ""),
        start_line=args.get("start_line", 1),
        end_line=args.get("end_line", 1),
        new_content=args.get("new_content", ""),
    )


@_registry.register("read_pdf")
def _read_pdf(args: dict, _context: ToolContext):
    return tool_read_pdf(args.get("path", ""))


@_registry.register("read_docx")
def _read_docx(args: dict, _context: ToolContext):
    return tool_read_docx(args.get("path", ""))


@_registry.register("read_pptx")
def _read_pptx(args: dict, _context: ToolContext):
    return tool_read_pptx(args.get("path", ""))


@_registry.register("read_excel")
def _read_excel(args: dict, _context: ToolContext):
    return tool_read_excel(args.get("path", ""))


@_registry.register("create_docx")
def _create_docx(args: dict, _context: ToolContext):
    return tool_create_docx(
        args.get("path", ""),
        args.get("markdown_content", ""),
        overwrite=args.get("overwrite", False),
    )


@_registry.register("modify_docx")
def _modify_docx(args: dict, _context: ToolContext):
    return tool_modify_docx(
        args.get("path", ""),
        args.get("instruction", ""),
    )


@_registry.register("query_document")
def _query_document(args: dict, _context: ToolContext):
    return tool_query_document(
        path=args.get("path", ""),
        query=args.get("query", ""),
        top_k=args.get("top_k", 5),
    )


@_registry.register("web_search")
def _web_search(args: dict, _context: ToolContext):
    return tool_web_search(args.get("query", ""), args.get("max_results", 5))


@_registry.register("update_memory")
def _update_memory(args: dict, _context: ToolContext):
    return tool_update_memory(
        file_key=args.get("file_key", "profile"),
        section=args.get("section", ""),
        content=args.get("content", ""),
    )


@_registry.register("launch_app")
def _launch_app(args: dict, _context: ToolContext):
    return tool_launch_app(args.get("query", ""))


@_registry.register("spotify_music")
def _spotify_music(args: dict, _context: ToolContext):
    return tool_spotify_music(
        action=args.get("action", ""),
        query=args.get("query", ""),
        uri=args.get("uri", ""),
        search_type=args.get("search_type", "track"),
        volume=args.get("volume", 50),
    )


@_registry.register("run_command")
def _run_command(args: dict, context: ToolContext):
    command = args.get("command", "").strip()
    if not command:
        return "Error: el comando está vacío."

    classification = classify_cmd(command)
    is_sudo = classification == "sudo"
    clean_command = (
        re.sub(r"^\s*sudo\s+", "", command) if is_sudo else command
    )
    display_command = f"sudo {clean_command}" if is_sudo else clean_command
    job = job_mgr.create(
        context.get("tool_call_id", ""),
        display_command,
        is_sudo=is_sudo,
    )
    if context.get("register_turn") and not job_mgr.add_turn_job(
        job.job_id,
        context.get("request_id"),
    ):
        job_mgr.cancel(job.job_id)
        return "Error: el turno alcanzó el límite de comandos permitidos."

    if is_sudo:
        _emit_tool_event(
            context,
            {
                "type": "sudo_required",
                "job_id": job.job_id,
                "command": clean_command,
            },
        )
        return job

    reason = (
        "Este comando parece destructivo y puede modificar datos de forma "
        "irreversible"
        if classification == "destructive"
        else "Los comandos de shell siempre requieren aprobación explícita"
    )
    _emit_tool_event(
        context,
        {
            "type": "confirm_required",
            "job_id": job.job_id,
            "command": command,
            "reason": reason,
        },
    )
    return job


@_registry.register("manage_tasks")
def _manage_tasks(args: dict, _context: ToolContext):
    return tool_manage_tasks(
        action=args.get("action", ""),
        description=args.get("description", ""),
        task_id=args.get("task_id"),
        due_date=args.get("due_date"),
        recurrence=args.get("recurrence"),
        recurrence_day=args.get("recurrence_day"),
        recurrence_month=args.get("recurrence_month"),
        confirm=args.get("confirm", False),
    )


@_registry.register("capture_screen")
def _capture_screen(args: dict, _context: ToolContext):
    return tool_capture_screen(output=args.get("output", ""))


@_registry.register("hyprland_control")
def _hyprland_control(args: dict, _context: ToolContext):
    return tool_hyprland_control(
        action=args.get("action", ""),
        workspace=args.get("workspace"),
        window_query=args.get("window_query", "") or None,
    )


@_registry.register("check_job_status")
def _check_job_status(args: dict, _context: ToolContext):
    return tool_check_job_status(job_id=args.get("job_id", ""))


_registry.assert_complete()


def dispatch_tool(
    tool_name: str,
    args: dict,
    tool_call_id: str = "",
    **kwargs,
) -> str | CommandJob | ScreenCapture:
    """Valida y ejecuta una tool registrada usando una interfaz uniforme."""
    context = dict(kwargs)
    context["tool_call_id"] = tool_call_id
    return _registry.dispatch(tool_name, args, context)
