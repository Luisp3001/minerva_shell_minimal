#!/usr/bin/env python3
"""
Búsqueda y activación dinámica de herramientas (Tool Search) para Minerva.
Permite a la IA descubrir y cargar herramientas locales y de servidores MCP
bajo demanda en lugar de saturar el contexto desde el primer turno.
"""

from __future__ import annotations

import re
import sys
import threading
from typing import Any

from .definitions import CORE_TOOL_NAMES, TOOL_DEFINITIONS

_tool_client = None
_tool_collection = None
_tool_collection_lock = threading.Lock()
_indexed_tool_names: set[str] = set()

# Reglas de co-activación de herramientas vinculadas
_LINKED_TOOLS: dict[str, set[str]] = {
    "run_command": {"check_job_status"},
    "create_docx": {"modify_docx"},
    "modify_docx": {"create_docx"},
}

# Palabras clave explícitas para acelerar y garantizar coincidencias obvias
_KEYWORD_HINTS: dict[str, list[str]] = {
    "run_command": ["bash", "terminal", "comando", "shell", "ejecutar", "consola", "cmd", "run_command"],
    "check_job_status": ["estado", "job", "proceso", "segundo plano", "check_job_status"],
    "spotify_music": ["spotify", "musica", "música", "cancion", "canción", "playlist", "reproducir", "pausar", "volumen"],
    "hyprland_control": ["hyprland", "workspace", "ventana", "escritorio", "mover", "cambiar", "window"],
    "capture_screen": ["captura", "pantalla", "screenshot", "screen", "ver pantalla", "monitor"],
    "generate_image": ["imagen", "dibujo", "generar imagen", "dibujar", "foto", "crear imagen", "image"],
    "create_docx": ["word", "docx", "documento", "crear docx", "crear word"],
    "modify_docx": ["word", "docx", "modificar docx", "editar word"],
    "query_document": ["rag", "preguntar documento", "buscar en pdf", "buscar en docx", "consultar documento"],
    "read_pdf": ["pdf", "leer pdf"],
    "read_docx": ["leer word", "leer docx"],
    "read_pptx": ["powerpoint", "pptx", "diapositivas", "presentacion"],
    "read_excel": ["excel", "xlsx", "csv", "hoja de calculo", "tabla"],
    "launch_app": ["abrir app", "lanzar aplicacion", "ejecutar programa", "desktop app", "launcher", "juego", "game"],
}


def _get_all_tools_map() -> dict[str, dict[str, Any]]:
    """Devuelve un mapa de todas las herramientas locales y MCP activas por nombre."""
    tools_map = {t["function"]["name"]: t for t in TOOL_DEFINITIONS}
    try:
        from ..core.mcp_manager import mcp_mgr
        for t in mcp_mgr.get_tool_definitions():
            tools_map[t["function"]["name"]] = t
    except Exception:
        pass
    return tools_map


def _ensure_collection():
    """Inicializa ChromaDB para indexar las herramientas bajo demanda."""
    global _tool_client, _tool_collection, _indexed_tool_names
    if _tool_collection is not None:
        return _tool_collection

    with _tool_collection_lock:
        if _tool_collection is not None:
            return _tool_collection
        try:
            import chromadb

            _tool_client = chromadb.EphemeralClient()
            _tool_collection = _tool_client.get_or_create_collection(
                name="minerva_tool_catalog"
            )
            tools_map = _get_all_tools_map()
            docs = []
            ids = []
            for name, tool in tools_map.items():
                func = tool.get("function", {})
                desc = func.get("description", "")
                params = list(func.get("parameters", {}).get("properties", {}).keys())
                docs.append(f"Herramienta: {name}. Descripción: {desc}. Parámetros: {', '.join(params)}")
                ids.append(name)
            if ids:
                _tool_collection.upsert(documents=docs, ids=ids)
                _indexed_tool_names = set(ids)
        except Exception as exc:
            print(
                f"Minerva: Error inicializando ChromaDB para tool search: {type(exc).__name__}",
                file=sys.stderr,
            )
            _tool_collection = None
        return _tool_collection


def _sync_mcp_tools_if_needed():
    """Sincroniza en ChromaDB nuevas herramientas MCP que se hayan activado."""
    global _indexed_tool_names
    collection = _ensure_collection()
    if collection is None:
        return
    try:
        from ..core.mcp_manager import mcp_mgr
        mcp_tools = mcp_mgr.get_tool_definitions()
        new_tools = [t for t in mcp_tools if t["function"]["name"] not in _indexed_tool_names]
        if new_tools:
            docs = []
            ids = []
            for tool in new_tools:
                name = tool["function"]["name"]
                desc = tool["function"].get("description", "")
                params = list(tool["function"].get("parameters", {}).get("properties", {}).keys())
                docs.append(f"Herramienta MCP: {name}. Descripción: {desc}. Parámetros: {', '.join(params)}")
                ids.append(name)
            with _tool_collection_lock:
                collection.upsert(documents=docs, ids=ids)
                _indexed_tool_names.update(ids)
    except Exception:
        pass


def _keyword_matches(query: str, tools_map: dict[str, dict[str, Any]]) -> list[str]:
    """Búsqueda determinista basada en palabras clave para complementar ChromaDB."""
    q_lower = query.lower()
    q_tokens = set(re.findall(r"\w+", q_lower))
    matches: list[tuple[int, str]] = []

    for name, tool in tools_map.items():
        score = 0
        hints = _KEYWORD_HINTS.get(name, [])
        for hint in hints:
            if hint in q_lower:
                score += 3
            elif hint in q_tokens:
                score += 2

        # Comprobar si el nombre de la tool o tokens de su descripción coinciden
        if name.lower() in q_lower:
            score += 4

        # Para herramientas MCP (ej: mcp__github__create_issue)
        if name.startswith("mcp__"):
            parts = name.split("__")
            for part in parts[1:]:
                if part.lower() in q_lower or part.lower() in q_tokens:
                    score += 2
            desc = tool.get("function", {}).get("description", "").lower()
            for token in q_tokens:
                if len(token) >= 3 and token in desc:
                    score += 1

        if score > 0:
            matches.append((score, name))

    matches.sort(key=lambda x: x[0], reverse=True)
    return [name for _, name in matches[:6]]


def search_and_activate_tools(
    query: str,
    active_tool_names: set[str] | None = None,
    limit: int = 5,
) -> tuple[str, list[dict[str, Any]]]:
    """
    Busca herramientas que coincidan con la consulta semántica o por palabras clave.
    Devuelve (texto_descriptivo_para_el_modelo, lista_de_definiciones_de_herramientas).
    """
    active_tool_names = active_tool_names or set()
    tools_map = _get_all_tools_map()
    candidate_names: list[str] = []

    # 1. Búsqueda por palabras clave rápidas
    keyword_results = _keyword_matches(query, tools_map)
    candidate_names.extend(keyword_results)

    # 2. Búsqueda semántica en ChromaDB
    _sync_mcp_tools_if_needed()
    collection = _ensure_collection()
    if collection is not None and query.strip():
        try:
            results = collection.query(
                query_texts=[query],
                n_results=min(limit + 3, len(tools_map)),
            )
            if results and results.get("ids") and results["ids"][0]:
                for tool_id in results["ids"][0]:
                    if tool_id not in candidate_names:
                        candidate_names.append(tool_id)
        except Exception as exc:
            print(
                f"Minerva: Error en query a ChromaDB: {type(exc).__name__}",
                file=sys.stderr,
            )

    # 3. Incluir herramientas vinculadas (ej. check_job_status con run_command)
    final_names: list[str] = []
    seen: set[str] = set()

    for name in candidate_names:
        if name in tools_map and name not in seen:
            seen.add(name)
            final_names.append(name)
            for linked in _LINKED_TOOLS.get(name, set()):
                if linked in tools_map and linked not in seen:
                    seen.add(linked)
                    final_names.append(linked)

    # Limitar el total de herramientas sugeridas
    final_names = final_names[:limit + 2]

    # Separar entre las que ya estaban activas y las que se activan ahora
    newly_activated: list[dict[str, Any]] = []
    already_active: list[str] = []

    for name in final_names:
        tool_def = tools_map[name]
        if name in active_tool_names:
            already_active.append(name)
        else:
            newly_activated.append(tool_def)

    if not newly_activated and not already_active:
        return (
            f"No se encontraron herramientas específicas para la búsqueda '{query}'. "
            "Revisa si la acción puede realizarse con tus herramientas actuales o reformula la búsqueda.",
            [],
        )

    lines = []
    if newly_activated:
        lines.append("Herramientas encontradas y activadas para este turno:")
        for t in newly_activated:
            fn = t.get("function", {})
            name = fn.get("name", "")
            desc = fn.get("description", "").split("\n")[0][:140]
            lines.append(f"- {name}: {desc}")
        lines.append("Ya están disponibles en tus herramientas. Invócalas directamente en tu siguiente paso.")

    if already_active:
        lines.append(f"Herramientas ya activas anteriormente: {', '.join(already_active)}.")

    return "\n".join(lines), newly_activated


def get_initial_tools(history: list[dict] | None = None) -> list[dict[str, Any]]:
    """
    Devuelve las herramientas con las que inicia el modelo en un turno:
    - Las herramientas Core (search_tools, filesystem básico, tareas, memoria, web_search).
    - Cualquier herramienta que ya haya sido invocada previamente en el historial de la conversación.
    """
    tools_map = _get_all_tools_map()
    initial_names = set(CORE_TOOL_NAMES)

    if history:
        for msg in history:
            # Herramientas llamadas por el asistente
            tool_calls = msg.get("tool_calls") or []
            for tc in tool_calls:
                fn_name = tc.get("function", {}).get("name", "")
                if fn_name and fn_name in tools_map:
                    initial_names.add(fn_name)
                    for linked in _LINKED_TOOLS.get(fn_name, set()):
                        if linked in tools_map:
                            initial_names.add(linked)

            # Respuestas de herramientas en el historial
            if msg.get("role") == "tool":
                tool_name = msg.get("name", "")
                if tool_name and tool_name in tools_map:
                    initial_names.add(tool_name)
                    for linked in _LINKED_TOOLS.get(tool_name, set()):
                        if linked in tools_map:
                            initial_names.add(linked)

    return [tools_map[name] for name in initial_names if name in tools_map]
