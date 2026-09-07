#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Engine de chat para Gemini (API compatible con OpenAI) — Minerva.

Maneja el loop agentic con streaming SSE, tool calls via delta chunks,
y re-invocación iterativa hasta obtener la respuesta final.
"""
import json
import re
import threading
import time
import urllib.error
import urllib.request

from ..tools import TOOL_DEFINITIONS, dispatch_tool, get_relevant_tools
from ..tools.screen import ScreenCapture
from .io import emit
from .job_manager import CommandJob, job_mgr
from .voice import (
    VOICE_AVAILABLE,
    StreamEmotionStripper,
    strip_emotion_tags,
    voice_mgr,
)

_GEMINI_URL = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
MAX_SSE_EVENT_CHARS = 2 * 1024 * 1024
MAX_STREAM_CHARS = 2 * 1024 * 1024
MAX_STREAM_SECONDS = 5 * 60
MAX_TOOL_CALLS_PER_RESPONSE = 32
MAX_TOOL_CONTENT_CHARS = 256 * 1024


class _StreamCancelled(Exception):
    """Interrumpe el lector SSE cuando se cancela la petición activa."""


class _StreamDeadlineExceeded(Exception):
    """Interrumpe una conexión SSE que superó su duración total."""


def _iter_bounded_lines(response):
    """Lee líneas sin permitir que una sola respuesta ocupe memoria ilimitada."""
    readline = getattr(response, "readline", None)
    if callable(readline):
        while raw_line := readline(MAX_SSE_EVENT_CHARS + 1):
            if len(raw_line) > MAX_SSE_EVENT_CHARS:
                raise ValueError("línea SSE demasiado grande")
            yield raw_line
        return

    for raw_line in response:
        if len(raw_line) > MAX_SSE_EVENT_CHARS:
            raise ValueError("línea SSE demasiado grande")
        yield raw_line


def _iter_sse_data(response, deadline=None, cancel_event=None):
    """Combina líneas ``data:`` hasta el separador vacío de cada evento SSE."""
    data_lines = []
    event_size = 0
    for raw_line in _iter_bounded_lines(response):
        if cancel_event is not None and cancel_event.is_set():
            raise _StreamCancelled
        if deadline is not None and time.monotonic() >= deadline:
            raise _StreamDeadlineExceeded
        line = raw_line.decode("utf-8", errors="replace").rstrip("\r\n")
        if not line:
            if data_lines:
                yield "\n".join(data_lines)
                data_lines = []
                event_size = 0
            continue
        if line.startswith(":"):
            continue
        if line.startswith("data:"):
            data = line[5:].lstrip()
            event_size += len(data)
            if event_size > MAX_SSE_EVENT_CHARS:
                raise ValueError("evento SSE demasiado grande")
            data_lines.append(data)
    if data_lines:
        yield "\n".join(data_lines)


def _sanitize_history(history: list) -> list:
    """
    Limpia el historial antes de enviarlo a la API de Gemini para evitar:
      - Error 400 'Name cannot be empty': mensajes role='tool' sin campo name.
      - Error 400 por respuestas huérfanas, sin el tool_call correspondiente.

    Reglas:
      1. Recopilar todos los tool_call_ids referenciados en mensajes role='assistant'.
      2. Eliminar mensajes role='tool' cuyo tool_call_id no esté en ese set (huérfanos).
      3. Completar el nombre ausente de una respuesta de herramienta.
    """
    # Paso 1: recopilar IDs válidos de tool_calls en mensajes assistant
    valid_tc_ids: set = set()
    for msg in history:
        if not isinstance(msg, dict):
            continue
        if msg.get("role") == "assistant":
            for tc in msg.get("tool_calls", []):
                if not isinstance(tc, dict):
                    continue
                tc_id = tc.get("id", "")
                if tc_id:
                    valid_tc_ids.add(tc_id)

    # Paso 2 y 3: filtrar y reparar mensajes role='tool'
    sanitized = []
    for msg in history:
        if not isinstance(msg, dict):
            continue
        if msg.get("role") == "tool":
            tc_id = msg.get("tool_call_id", "")
            # Una respuesta de tool sin su llamada assistant siempre es inválida.
            if not tc_id or tc_id not in valid_tc_ids:
                continue
            # Garantizar que 'name' no esté vacío
            if not msg.get("name"):
                msg = dict(msg)
                msg["name"] = "run_command"
        sanitized.append(msg)
    return sanitized


def _split_concatenated_calls(raw_name: str, raw_args: str, known_names: set) -> list:
    """
    Gemini 2.5-flash con thinking a veces fusiona múltiples tool_calls en uno solo,
    concatenando nombres ("run_commandrun_commandlist_dir") y argumentos
    ('{"command":"ls"}{"command":"df -h"}{"path":"/"}').

    Intenta separar en [(name1, args_dict1), (name2, args_dict2), ...].
    Devuelve [] si la función parece ser un tool_call normal (no concatenado).
    """
    # Si el nombre es exactamente uno de los conocidos, no hay concatenación
    if raw_name in known_names:
        return []

    # Separar usando nombres conocidos en orden greedy, primero el más largo.
    sorted_names = sorted(known_names, key=len, reverse=True)
    names_found = []
    remaining = raw_name
    while remaining:
        matched = False
        for n in sorted_names:
            if remaining.startswith(n):
                names_found.append(n)
                remaining = remaining[len(n):]
                matched = True
                break
        if not matched:
            return []  # no se pudo parsear, retornar vacío

    if len(names_found) <= 1:
        return []  # solo un nombre, no hay concatenación

    # Separar los argumentos JSON (múltiples objetos JSON concatenados)
    args_list = []
    decoder = json.JSONDecoder()
    pos = 0
    raw_args = raw_args.strip()
    while pos < len(raw_args):
        # Avanzar whitespace
        while pos < len(raw_args) and raw_args[pos] in " \t\n\r":
            pos += 1
        if pos >= len(raw_args):
            break
        try:
            obj, end_pos = decoder.raw_decode(raw_args, pos)
            args_list.append(obj)
            pos = end_pos
        except json.JSONDecodeError:
            return []  # no se pudo parsear, abandonar

    # Si el número de args coincide con el de nombres, emparejar
    if len(args_list) == len(names_found):
        return list(zip(names_found, args_list))

    # Si hay más nombres que args, rellenar los faltantes con {}
    if len(args_list) < len(names_found):
        args_list += [{}] * (len(names_found) - len(args_list))
        return list(zip(names_found, args_list))

    return []


def do_chat_gemini(
    history: list,
    max_iters: int = 12,
    model: str = "gemini-2.5-flash",
    api_key: str = "",
    temperature: float = 0.7,
    cancel_event: threading.Event | None = None,
    request_id: str = "",
    turn_ready_callback=None,
) -> None:
    """
    Ejecuta un turno de chat usando la API compatible con OpenAI de Gemini.
    Emite tokens en tiempo real al QML vía stdout.
    """
    cancel_event = cancel_event or threading.Event()

    def send(event: dict) -> None:
        if request_id:
            event["request_id"] = request_id
        emit(event)

    def send_error(message: str) -> None:
        send({"type": "error", "message": message})

    def cancelled() -> bool:
        if not cancel_event.is_set():
            return False
        send({"type": "cancelled"})
        return True

    if not api_key:
        send_error("API Key de Gemini no configurada en los ajustes del widget.")
        return

    voice_ready = VOICE_AVAILABLE and voice_mgr.dependencies_ready
    if voice_ready:
        voice_mgr.tts_stop_event.clear()

    # Obtener el último mensaje del usuario para el RAG de tools
    user_prompt = next(
        (m.get("content", "") for m in reversed(history) if m.get("role") == "user"),
        ""
    )
    dynamic_tools = (
        get_relevant_tools(user_prompt) if user_prompt else TOOL_DEFINITIONS
    )

    # Claves válidas para la API OpenAI-compatible de Gemini
    _valid_keys = {"role", "content", "tool_calls", "tool_call_id", "name"}

    tool_error_counts = {}

    for _iteration in range(max_iters):
        if cancelled():
            return
        full_response      = ""
        current_tool_calls = []
        buffer_frase       = ""
        stripper           = StreamEmotionStripper()
        stream_finished = False

        clean_history = []
        for msg in _sanitize_history(history):
            clean_msg = {k: v for k, v in msg.items() if k in _valid_keys}
            if "image_b64" in msg:
                image_mime = msg.get("image_mime", "image/jpeg")
                clean_msg["content"] = [
                    {"type": "text", "text": msg.get("content", "")},
                    {
                        "type": "image_url",
                        "image_url": {
                            "url": f"data:{image_mime};base64,{msg['image_b64']}"
                        },
                    },
                ]
            clean_history.append(clean_msg)

        req_data = {
            "model":       model,
            "messages":    clean_history,
            "tools":       dynamic_tools,
            "stream":      True,
            "temperature": temperature,
        }

        req = urllib.request.Request(
            _GEMINI_URL,
            data    = json.dumps(req_data).encode("utf-8"),
            headers = {
                "Authorization": f"Bearer {api_key}",
                "Content-Type":  "application/json"
            }
        )

        try:
            response = None
            for attempt in range(3):
                if cancelled():
                    return
                try:
                    response = urllib.request.urlopen(req, timeout=45)
                    break
                except urllib.error.HTTPError as exc:
                    retryable = exc.code in {429, 500, 502, 503, 504}
                    if not retryable or attempt == 2:
                        raise
                    retry_after = exc.headers.get("Retry-After", "")
                    exc.close()
                    try:
                        delay = min(10.0, max(0.5, float(retry_after)))
                    except (TypeError, ValueError):
                        delay = min(8.0, 2.0 ** attempt)
                    if cancel_event.wait(delay):
                        send({"type": "cancelled"})
                        return
                except (TimeoutError, urllib.error.URLError):
                    if attempt == 2:
                        raise
                    if cancel_event.wait(min(8.0, 2.0 ** attempt)):
                        send({"type": "cancelled"})
                        return

            if response is None:
                send_error("Gemini no devolvió una conexión utilizable.")
                return

            with response as resp:
                stream_deadline = time.monotonic() + MAX_STREAM_SECONDS
                stream_chars = 0
                for payload in _iter_sse_data(
                    resp,
                    deadline=stream_deadline,
                    cancel_event=cancel_event,
                ):
                    stream_chars += len(payload)
                    if stream_chars > MAX_STREAM_CHARS:
                        send_error("Gemini devolvió una respuesta demasiado grande.")
                        return
                    if cancelled():
                        return
                    if payload == "[DONE]":
                        stream_finished = True
                        continue
                    try:
                        chunk = json.loads(payload)
                    except json.JSONDecodeError:
                        continue

                    choices = chunk.get("choices") or []
                    if not isinstance(choices, list) or not choices:
                        continue
                    choice = choices[0]
                    if not isinstance(choice, dict):
                        continue
                    delta = choice.get("delta", {})
                    if not isinstance(delta, dict):
                        continue
                    if choice.get("finish_reason"):
                        stream_finished = True

                    # ── Tokens de texto ────────────────────────────────────
                    if isinstance(delta.get("content"), str):
                        token          = delta["content"]
                        full_response += token
                        buffer_frase  += token
                        clean_token    = stripper.add(token)
                        if clean_token:
                            send({"type": "token", "content": clean_token})

                        if (
                            voice_ready
                            and not voice_mgr.tts_stop_event.is_set()
                        ):
                            sentence_finished = (
                                re.search(r"[.!?\n:]", token)
                                and len(buffer_frase.strip()) > 5
                            )
                            if sentence_finished:
                                clean_frase = (
                                    buffer_frase.replace("*", "")
                                    .replace("#", "")
                                    .strip()
                                )
                                image_suffixes = {"png)", "jpg)", "jpeg)"}
                                if (
                                    clean_frase
                                    and "![" not in clean_frase
                                    and clean_frase not in image_suffixes
                                ):
                                    voice_mgr.enqueue_tts(clean_frase)
                                buffer_frase = ""

                    # ── Tool calls (se construyen de forma incremental) ────
                    if "tool_calls" in delta:
                        tool_call_deltas = delta["tool_calls"]
                        if not isinstance(tool_call_deltas, list):
                            continue
                        for tc in tool_call_deltas[:MAX_TOOL_CALLS_PER_RESPONSE]:
                            if not isinstance(tc, dict):
                                continue
                            idx = tc.get("index", 0)
                            if (
                                not isinstance(idx, int)
                                or isinstance(idx, bool)
                                or not 0 <= idx < MAX_TOOL_CALLS_PER_RESPONSE
                            ):
                                continue
                            while len(current_tool_calls) <= idx:
                                current_tool_calls.append({
                                    "id":       "",
                                    "type":     "function",
                                    "function": {"name": "", "arguments": ""}
                                })
                            for k, v in tc.items():
                                if k in ("index", "type"):
                                    continue
                                if k == "function":
                                    if not isinstance(v, dict):
                                        continue
                                    for fk, fv in v.items():
                                        if isinstance(fv, str):
                                            function = current_tool_calls[idx][
                                                "function"
                                            ]
                                            function.setdefault(fk, "")
                                            function[fk] += fv
                                        else:
                                            current_tool_calls[idx]["function"][fk] = fv
                                elif k == "id":
                                    if not isinstance(v, str):
                                        continue
                                    # Un id distinto en el mismo índice indica
                                    # un tool call nuevo sin índice explícito.
                                    existing = current_tool_calls[idx].get("id", "")
                                    id_changed = (
                                        existing
                                        and v
                                        and not v.startswith(existing)
                                        and not existing.startswith(v)
                                    )
                                    if id_changed:
                                        # id diferente → es un tool_call nuevo
                                        if (
                                            len(current_tool_calls)
                                            >= MAX_TOOL_CALLS_PER_RESPONSE
                                        ):
                                            continue
                                        current_tool_calls.append({
                                            "id":       v,
                                            "type":     "function",
                                            "function": {"name": "", "arguments": ""}
                                        })
                                    else:
                                        current_tool_calls[idx]["id"] = (
                                            existing + v if v else existing
                                        )
                                elif isinstance(v, str):
                                    current_tool_calls[idx].setdefault(k, "")
                                    current_tool_calls[idx][k] += v
                                else:
                                    current_tool_calls[idx][k] = v

            rem_token = stripper.flush()
            if rem_token:
                send({"type": "token", "content": rem_token})

        except _StreamCancelled:
            send({"type": "cancelled"})
            return
        except _StreamDeadlineExceeded:
            send_error("Gemini excedió el tiempo máximo de respuesta.")
            return
        except urllib.error.HTTPError as exc:
            raw_error = ""
            try:
                raw_error = exc.read(4096).decode("utf-8", errors="replace")
                parsed = json.loads(raw_error)
                detail = parsed.get("error", {}).get("message", "")
            except (json.JSONDecodeError, AttributeError, OSError):
                detail = raw_error
            finally:
                exc.close()
            send_error(f"Error de Gemini API: {exc.code} - {detail[:500]}")
            return
        except Exception as e:
            send_error(f"Error de conexión con Gemini: {type(e).__name__}")
            return

        # Sin tool calls → respuesta final
        if not current_tool_calls:
            if (
                voice_ready
                and buffer_frase.strip()
                and not voice_mgr.tts_stop_event.is_set()
            ):
                clean_frase = buffer_frase.replace("*", "").replace("#", "").strip()
                if clean_frase:
                    voice_mgr.enqueue_tts(clean_frase)
            if not stream_finished and not full_response.strip():
                send_error("La conexión con Gemini terminó sin una respuesta completa.")
                return
            send({
                "type": "done",
                "full_response": strip_emotion_tags(full_response).strip(),
            })
            return

        # Separar tool_calls concatenados por Gemini thinking.
        # Gemini 2.5 Flash con thinking puede fusionar M tool_calls en uno solo,
        # concatenando nombres y argumentos. Detectamos y separamos estos casos.
        expanded_tool_calls = []
        known_tool_names = {t["function"]["name"] for t in dynamic_tools}

        for tc in current_tool_calls:
            raw_name = tc["function"].get("name", "")
            raw_args = tc["function"].get("arguments", "")

            # Detectar repeticiones, por ejemplo run_commandrun_command.
            parts = _split_concatenated_calls(raw_name, raw_args, known_tool_names)
            if parts:
                for i, (p_name, p_args) in enumerate(parts):
                    new_tc = dict(tc)
                    new_tc["id"] = tc["id"] + (f"_{i}" if i > 0 else "")
                    new_tc["function"] = {
                        "name": p_name,
                        "arguments": json.dumps(p_args),
                    }
                    expanded_tool_calls.append(new_tc)
            else:
                expanded_tool_calls.append(tc)

        current_tool_calls = expanded_tool_calls[:MAX_TOOL_CALLS_PER_RESPONSE]

        # Filtrar tool_calls incompletos producidos por streaming anómalo.
        current_tool_calls = [
            tc for tc in current_tool_calls
            if tc.get("id") and tc.get("function", {}).get("name")
        ]

        # Sin tool calls válidos → respuesta final
        if not current_tool_calls:
            if (
                voice_ready
                and buffer_frase.strip()
                and not voice_mgr.tts_stop_event.is_set()
            ):
                clean_frase = buffer_frase.replace("*", "").replace("#", "").strip()
                if clean_frase:
                    voice_mgr.enqueue_tts(clean_frase)
            send({
                "type": "done",
                "full_response": strip_emotion_tags(full_response).strip(),
            })
            return

        # Guardar la respuesta del assistant.
        # Gemini rechaza content="" con tool_calls; debe enviarse None.
        history.append({
            "role":       "assistant",
            "content":    full_response or None,
            "tool_calls": current_tool_calls
        })

        # Procesar todas las herramientas. Los comandos quedan pendientes y
        # las demás respuestas se incorporan al historial inmediatamente.
        pending_jobs = []
        has_command_calls = any(
            call.get("function", {}).get("name") == "run_command"
            for call in current_tool_calls
        )
        if has_command_calls:
            job_mgr.begin_turn(request_id)

        for tc in current_tool_calls:
            if cancelled():
                if has_command_calls:
                    job_mgr.cancel_turn(request_id)
                    job_mgr.clear_turn(request_id)
                return
            tool_name = tc["function"]["name"]
            try:
                args = json.loads(tc["function"]["arguments"])
            except (json.JSONDecodeError, TypeError):
                args = {}
            if not isinstance(args, dict):
                args = {}

            tc_id = tc.get("id", "")
            send({"type": "tool_start", "tool": tool_name, "args": args})
            try:
                result = dispatch_tool(
                    tool_name,
                    args,
                    tool_call_id=tc_id,
                    api_key=api_key,
                    request_id=request_id,
                    register_turn=has_command_calls,
                )
            except Exception as exc:
                result = f"Error interno en {tool_name}: {type(exc).__name__}"

            if isinstance(result, CommandJob):
                # run_command pendiente — acumular y continuar con el resto
                pending_jobs.append(result)
                continue

            if isinstance(result, ScreenCapture):
                send({
                    "type": "tool_result",
                    "tool": tool_name,
                    "result": result.summary_text(),
                })
                history.append({
                    "role":         "tool",
                    "tool_call_id": tc_id,
                    "name":         tool_name,
                    "content":      result.summary_text() or "Captura tomada."
                })
                history.append({
                    "role":      "user",
                    "content": (
                        "Aquí está la captura de pantalla que tomé. "
                        "Analízala y responde."
                    ),
                    "image_b64": result.b64,
                    "image_mime": "image/png",
                })
            else:
                result_str = str(result) if result is not None else "OK"
                bounded_result = result_str[:MAX_TOOL_CONTENT_CHARS]
                if len(result_str) > MAX_TOOL_CONTENT_CHARS:
                    bounded_result += "\n[Resultado de herramienta truncado]"
                send({
                    "type": "tool_result",
                    "tool": tool_name,
                    "result": bounded_result,
                })
                history.append({
                    "role":         "tool",
                    "tool_call_id": tc_id,
                    "name":         tool_name,
                    "content":      bounded_result,
                })

                normalized_result = result_str.strip().lower()
                if normalized_result.startswith(
                    ("error", "acceso denegado")
                ):
                    call_key = (tool_name, json.dumps(args, sort_keys=True))
                    tool_error_counts[call_key] = tool_error_counts.get(call_key, 0) + 1
                    if tool_error_counts[call_key] >= 3:
                        send_error(
                            f"Bucle detectado: la herramienta '{tool_name}' "
                            "falló 3 veces seguidas. Operación abortada."
                        )
                        return

        if pending_jobs:
            # Cerrar el conjunto solo después de publicar todos los jobs. Así
            # una confirmación ultrarrápida no reanuda un turno incompleto.
            job_mgr.seal_turn(request_id)
            if job_mgr.all_turn_finished(request_id) and turn_ready_callback:
                turn_ready_callback()
            return
        if has_command_calls:
            job_mgr.clear_turn(request_id)
        # Si no hubo run_command, continuar la iteración agentic normalmente

    send_error(f"Demasiadas iteraciones de herramientas (límite: {max_iters})")
