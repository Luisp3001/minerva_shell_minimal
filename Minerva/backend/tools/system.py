#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Búsqueda web, lanzamiento de aplicaciones y control de Hyprland."""
import json
import os
import pathlib
import re
import subprocess

from ..core.config import WEB_SEARCH_AVAILABLE
from ..core.io import safe_session_environment
from ..core.job_manager import job_mgr


def tool_web_search(query: str, max_results: int = 5) -> str:
    """Busca en internet usando DuckDuckGo (sin API key)."""
    if not WEB_SEARCH_AVAILABLE:
        return "Error: el módulo 'ddgs' no está instalado en el entorno del plugin."
    max_results = max(1, min(10, int(max_results)))
    try:
        from ddgs import DDGS
        results = []
        with DDGS(timeout=8) as ddgs:
            for r in ddgs.text(query, max_results=max_results):
                results.append(r)
        if not results:
            return f"No se encontraron resultados para: {query}"
        lines = [f"Resultados de búsqueda para: '{query}'\n"]
        for i, r in enumerate(results, 1):
            title   = r.get("title",  "Sin título")
            href    = r.get("href",   "")
            snippet = r.get("body",   r.get("description", "Sin descripción"))
            lines.append(f"[{i}] {title}")
            lines.append(f"    URL: {href}")
            lines.append(f"    {snippet}")
            lines.append("")
        return "\n".join(lines).strip()
    except Exception as e:
        return f"Error al realizar la búsqueda web: {e}"


def tool_launch_app(query: str) -> str:
    """Busca una aplicación por nombre o sinónimo y la abre en segundo plano."""
    query = query.lower().strip()
    synonyms = {
        "navegador": [
            "firefox", "brave", "chrome", "chromium", "browser", "thorium"
        ],
        "musica": ["spotify", "youtube", "music"],
        "discord": ["vesktop", "discord", "webcord", "armcord"],
        "archivos": [
            "dolphin", "nautilus", "thunar", "files", "explorador"
        ],
        "terminal": ["kitty", "alacritty", "konsole", "wezterm"],
    }

    search_terms = [query]
    for key, vals in synonyms.items():
        if key in query:
            search_terms.extend(vals)

    desktop_dirs = [
        "/usr/share/applications",
        os.path.expanduser("~/.local/share/applications"),
        "/var/lib/flatpak/exports/share/applications",
    ]

    best_match = None
    best_score = 0
    best_exec = None
    best_name = None

    for d in desktop_dirs:
        if not os.path.isdir(d):
            continue
        for path in pathlib.Path(d).rglob("*.desktop"):
            try:
                content = path.read_text(encoding="utf-8")
                if "NoDisplay=true" in content:
                    continue

                name, exec_cmd, keywords, generic_name = "", "", "", ""
                in_desktop_entry = False
                for line in content.splitlines():
                    line = line.strip()
                    if line == "[Desktop Entry]":
                        in_desktop_entry = True
                        continue
                    elif line.startswith("[") and in_desktop_entry:
                        in_desktop_entry = False

                    if in_desktop_entry:
                        if line.startswith("Name=") and not name:
                            name = line[5:]
                        elif line.startswith("Exec=") and not exec_cmd:
                            exec_cmd = line[5:]
                        elif line.startswith("Keywords="):
                            keywords = line[9:].lower()
                        elif line.startswith("GenericName="):
                            generic_name = line[12:].lower()

                if not exec_cmd or not name:
                    continue

                score = 0
                name_lower = name.lower()
                generic_lower = generic_name.lower()

                for term in search_terms:
                    term = term.lower()
                    if not term:
                        continue
                    if term == name_lower:
                        score += 100
                    elif term in name_lower:
                        score += 50
                    elif term in generic_lower:
                        score += 30
                    elif term in keywords:
                        score += 20
                    elif term in path.name.lower():
                        score += 10

                if score > best_score:
                    best_score = score
                    best_match = path
                    best_exec = exec_cmd
                    best_name = name

            except Exception:
                continue

    if best_score > 0 and best_exec:
        try:
            subprocess.Popen(
                ["gio", "launch", str(best_match)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
                env=safe_session_environment(),
            )
            return (
                f"Aplicación abierta: {best_name}. IMPORTANTE: Responde "
                "brevemente al usuario confirmando que la abriste."
            )
        except Exception as e:
            return (
                f"Error abriendo aplicación: {e}. "
                "IMPORTANTE: Informa al usuario del error."
            )

    return (
        f"No se encontró ninguna aplicación gráfica para: {query}. "
        "IMPORTANTE: Informa al usuario que no la encontraste."
    )


def tool_hyprland_control(
    action: str,
    workspace: int | None = None,
    window_query: str | None = None,
) -> str:
    """
    Controla Hyprland: navega a un workspace o mueve una ventana entre workspaces.
    Usa la API Lua de Hyprland 0.56 (hyprctl eval / hyprctl dispatch).

    Parámetros:
      action        : 'switch_workspace'  → ir al workspace indicado
                    | 'move_window'       → mover una ventana al workspace indicado
                    | 'list_windows'      → listar ventanas abiertas con su workspace
      workspace     : número de workspace destino (requerido para switch/move)
      window_query  : clase o título de la ventana a mover
                      Ejemplos: 'Spotify', 'firefox', 'kitty'
    """
    action = action.strip().lower()

    # ── list_windows ────────────────────────────────────────────────────────
    if action == "list_windows":
        try:
            result = subprocess.run(
                ["hyprctl", "clients", "-j"],
                capture_output=True,
                text=True,
                timeout=5,
                env=safe_session_environment(),
            )
            if result.returncode != 0:
                return f"Error listando ventanas: {result.stderr[:500]}"
            clients = json.loads(result.stdout)
            if not isinstance(clients, list):
                return "Error: Hyprland devolvió una lista de ventanas inválida."
            if not clients:
                return "No hay ventanas abiertas en este momento."
            lines = ["Ventanas abiertas:"]
            for c in clients:
                cls = c.get("class", "desconocida")
                title = c.get("title", "")[:50]
                ws_id = c.get("workspace", {}).get("id", "?")
                lines.append(f"  - {cls} | '{title}' | workspace {ws_id}")
            return "\n".join(lines)
        except Exception as e:
            return f"Error listando ventanas: {e}"

    # ── switch_workspace ────────────────────────────────────────────────────
    if action == "switch_workspace":
        if workspace is None or not 1 <= workspace <= 10:
            return "Error: workspace debe ser un número entre 1 y 10."
        try:
            result = subprocess.run(
                [
                    "hyprctl",
                    "dispatch",
                    f'hl.dsp.focus({{ workspace = "{workspace}" }})',
                ],
                capture_output=True,
                text=True,
                timeout=5,
                env=safe_session_environment(),
            )
            if result.returncode != 0:
                return f"Error al cambiar de workspace: {result.stderr[:500]}"
            return (
                f"Me moví al workspace {workspace}. "
                "IMPORTANTE: Confirma brevemente al usuario."
            )
        except Exception as e:
            return f"Error al cambiar de workspace: {e}"

    # ── move_window ─────────────────────────────────────────────────────────
    if action == "move_window":
        if workspace is None or not 1 <= workspace <= 10:
            return "Error: workspace debe ser un número entre 1 y 10."
        if not window_query:
            return (
                "Error: debes indicar el nombre de la ventana "
                "(clase o título) que quieres mover."
            )

        # Buscar la mejor coincidencia en la lista de clientes.
        try:
            result = subprocess.run(
                ["hyprctl", "clients", "-j"],
                capture_output=True,
                text=True,
                timeout=5,
                env=safe_session_environment(),
            )
            if result.returncode != 0:
                return f"Error obteniendo lista de ventanas: {result.stderr[:500]}"
            clients = json.loads(result.stdout)
            if not isinstance(clients, list):
                return "Error: Hyprland devolvió una lista de ventanas inválida."
        except Exception as e:
            return f"Error obteniendo lista de ventanas: {e}"

        query_lower = window_query.lower()
        matched = None
        for c in clients:
            cls = c.get("class", "").lower()
            title = c.get("title", "").lower()
            if query_lower in cls:
                matched = c
                break
            if query_lower in title:
                matched = c

        if not matched:
            return (
                f"No encontré ninguna ventana que coincida con '{window_query}'.\n"
                "Usa la acción 'list_windows' para ver las ventanas abiertas."
            )

        matched_class = matched.get("class", "")
        matched_title = matched.get("title", "")
        matched_address = matched.get("address", "")
        current_ws = matched.get("workspace", {}).get("id", "?")

        # Los títulos son controlables desde aplicaciones y páginas web. Usar
        # únicamente la dirección hexadecimal evita interpolarlos en Lua.
        if not re.fullmatch(r"0x[0-9a-fA-F]+", matched_address):
            return "Error: Hyprland devolvió una dirección de ventana inválida."
        window_id = f"address:{matched_address}"

        # Dispatch usando la nueva API Lua 0.56
        dispatch_cmd = (
            "hl.dsp.window.move({ "
            f'workspace = {workspace}, window = "{window_id}"'
            " })"
        )
        try:
            result = subprocess.run(
                ["hyprctl", "dispatch", dispatch_cmd],
                capture_output=True,
                text=True,
                timeout=5,
                env=safe_session_environment(),
            )
            if result.returncode != 0:
                return f"Error moviendo la ventana: {result.stderr[:500]}"
            display_name = matched_class or matched_title
            return (
                f"Moví '{display_name}' del workspace {current_ws} "
                f"al workspace {workspace}. "
                "IMPORTANTE: Confirma brevemente al usuario."
            )
        except Exception as e:
            return f"Error moviendo la ventana: {e}"

    return (
        f"Acción desconocida: '{action}'. Usa 'switch_workspace', "
        "'move_window' o 'list_windows'."
    )


def tool_check_job_status(job_id: str = "") -> str:
    """
    Consulta el estado de comandos en segundo plano registrados en el JobManager.

    - Si se indica job_id, devuelve info detallada de ese job específico.
    - Si no se indica (o job_id == ""), lista todos los jobs registrados.
    """
    if job_id:
        job = job_mgr.get(job_id)
        if not job:
            return (
                f"No se encontró ningún comando con job_id '{job_id}'. "
                "Puede haber sido eliminado del registro."
            )
        lines = [
            f"Job ID:      {job.job_id}",
            f"Comando:     {job.command}",
            f"Estado:      {job.status}",
            f"Código ret.: {job.returncode}",
        ]
        if job.output:
            truncated = job.output[:1500]
            lines.append(f"Salida:\n{truncated}")
            if len(job.output) > 1500:
                lines.append(
                    "... (salida truncada, "
                    f"{len(job.output)} caracteres totales)"
                )
        else:
            lines.append("Salida:      (vacía aún)")
        return "\n".join(lines)

    # Listar todos los jobs
    all_jobs = job_mgr.get_all_jobs()
    if not all_jobs:
        return (
            "No hay comandos registrados. Ningún comando ha sido ejecutado "
            "en esta sesión todavía."
        )

    lines = [f"Comandos en segundo plano registrados ({len(all_jobs)} total):\n"]
    for j in all_jobs:
        in_turn = " [turno activo]" if j["in_turn"] else ""
        lines.append(
            f"  • [{j['status'].upper()}]{in_turn} "
            f"job_id={j['job_id']} → {j['command']}"
        )
        if j["status"] in ("completed", "failed"):
            rc_str = f"  returncode={j['returncode']}"
            out_preview = (
                j["output"][:200].replace("\n", " ")
                if j["output"]
                else "(sin salida)"
            )
            lines.append(f"    {rc_str}")
            lines.append(f"    Salida: {out_preview}")
        lines.append("")
    return "\n".join(lines).strip()
