#!/usr/bin/env python3
"""Punto de entrada de Minerva.

QML y Python intercambian objetos JSON Lines por stdin/stdout. El coordinador
solo valida y enruta eventos; las operaciones bloqueantes viven en pools
acotados para que cancelar, confirmar y usar voz siga siendo inmediato.
"""
from __future__ import annotations

import base64
import codecs
import datetime
import json
import os
import pathlib
import queue
import selectors
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field


# Compatibilidad para GPUs AMD RX 6000 (RDNA 2) en PyTorch ROCm.
os.environ.setdefault("HSA_OVERRIDE_GFX_VERSION", "10.3.0")

from backend.core.config import HOME, MINERVA_CONFIG_DIR
from backend.core.gemini_engine import do_chat_gemini
from backend.core.io import (
    emit,
    emit_error,
    is_safe_path,
    safe_session_environment,
)
from backend.core.job_manager import JobSnapshot, job_mgr
from backend.core.memory import get_memory_context
from backend.core.tasks_db import (
    clear_completed_tasks,
    get_pending_tasks,
    init_db,
    renew_recurring_tasks,
)
from backend.core.voice import VOICE_AVAILABLE, voice_mgr
from backend.tools import FISH_AUDIO_EMOTION_PROMPT, SYSTEM_PROMPT


MAX_IPC_LINE = 2 * 1024 * 1024
MAX_MESSAGE_CHARS = 64 * 1024
MAX_HISTORY_MESSAGES = 100
MAX_HISTORY_CHARS = 256 * 1024
MAX_IMAGE_BYTES = 20 * 1024 * 1024
MAX_TOOL_RESULT_CHARS = 8 * 1024
COMMAND_TIMEOUT_SECONDS = 30 * 60
COMMAND_MAX_PENDING = 8
CHAT_MAX_PENDING = 4
TRANSCRIPTION_MAX_PENDING = 2
VOICE_OPERATION_MAX_PENDING = 2

_ALLOWED_IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".webp"}
_SETTING_KEYS = {
    "aiProvider",
    "aiTemperature",
    "fishApiKey",
    "fishModel",
    "fishVoiceId",
    "geminiApiKey",
    "geminiModel",
    "geminiTtsModel",
    "geminiTtsVoice",
    "ttsProvider",
}
_CHAT_SETTING_KEYS = {
    "fish_api_key",
    "fish_model",
    "fish_voice_id",
    "gemini_api_key",
    "gemini_model",
    "gemini_tts_model",
    "gemini_tts_voice",
    "provider",
    "temperature",
    "tts_provider",
}

msg_queue: queue.Queue[str | dict] = queue.Queue(maxsize=64)
shutdown_event = threading.Event()
chat_executor = ThreadPoolExecutor(max_workers=2, thread_name_prefix="minerva-chat")
command_executor = ThreadPoolExecutor(
    max_workers=4,
    thread_name_prefix="minerva-command",
)
transcription_executor = ThreadPoolExecutor(
    max_workers=1,
    thread_name_prefix="minerva-stt",
)
voice_executor = ThreadPoolExecutor(
    max_workers=1,
    thread_name_prefix="minerva-voice-control",
)
chat_slots = threading.BoundedSemaphore(CHAT_MAX_PENDING)
command_slots = threading.BoundedSemaphore(COMMAND_MAX_PENDING)
transcription_slots = threading.BoundedSemaphore(TRANSCRIPTION_MAX_PENDING)
voice_operation_slots = threading.BoundedSemaphore(
    VOICE_OPERATION_MAX_PENDING,
)


@dataclass(slots=True)
class ChatContext:
    request_id: str
    message: str
    client_history: list[dict]
    settings: dict
    image_path: str = ""
    history: list[dict] = field(default_factory=list)
    cancel_event: threading.Event = field(default_factory=threading.Event)
    prepared: bool = False


active_context: ChatContext | None = None


def _request_event(context: ChatContext, event: dict) -> None:
    event["request_id"] = context.request_id
    emit(event)


def _read_stdin() -> None:
    """Lee IPC con un máximo por mensaje y aplica backpressure con la cola."""
    while not shutdown_event.is_set():
        line = sys.stdin.readline(MAX_IPC_LINE + 1)
        if not line:
            msg_queue.put({"type": "_shutdown"})
            return
        if len(line) > MAX_IPC_LINE:
            if not line.endswith("\n"):
                while remainder := sys.stdin.readline(MAX_IPC_LINE + 1):
                    if remainder.endswith("\n"):
                        break
            msg_queue.put({
                "type": "_protocol_error",
                "message": "Mensaje IPC demasiado grande",
            })
            continue
        msg_queue.put(line)


def _clean_client_history(value: object) -> list[dict]:
    if not isinstance(value, list):
        raise ValueError("history debe ser una lista")
    cleaned: list[dict] = []
    total_chars = 0
    for item in value[-MAX_HISTORY_MESSAGES:]:
        if not isinstance(item, dict):
            raise ValueError("Cada entrada de history debe ser un objeto")
        role = item.get("role")
        content = item.get("content")
        if role not in {"user", "assistant"} or not isinstance(content, str):
            raise ValueError("history solo admite roles user/assistant con texto")
        total_chars += len(content)
        if total_chars > MAX_HISTORY_CHARS:
            raise ValueError("El historial excede el límite permitido")
        cleaned.append({"role": role, "content": content})
    return cleaned


def _clean_chat_settings(value: object) -> dict:
    if not isinstance(value, dict):
        raise ValueError("settings debe ser un objeto")
    unexpected = set(value) - _CHAT_SETTING_KEYS
    if unexpected:
        raise ValueError(
            f"Ajustes de chat desconocidos: {', '.join(sorted(unexpected))}"
        )

    cleaned = {}
    for key, item in value.items():
        if key == "temperature":
            if isinstance(item, bool) or not isinstance(item, (str, int, float)):
                raise ValueError("temperature debe ser texto o número")
        elif not isinstance(item, str):
            raise ValueError(f"El ajuste de chat {key} debe ser texto")
        if len(str(item)) > 4096:
            raise ValueError(f"El ajuste de chat {key} es demasiado largo")
        cleaned[key] = item
    return cleaned


def _parse_chat_message(msg: dict) -> ChatContext:
    message = msg.get("message", "")
    image_path = msg.get("image", "")
    settings = _clean_chat_settings(msg.get("settings", {}))
    request_id = msg.get("request_id") or uuid.uuid4().hex

    if not isinstance(message, str) or not message.strip():
        raise ValueError("message debe ser texto no vacío")
    if len(message) > MAX_MESSAGE_CHARS:
        raise ValueError("El mensaje excede el límite permitido")
    if not isinstance(image_path, str):
        raise ValueError("image debe ser una ruta de texto")
    if not isinstance(request_id, str) or len(request_id) > 128:
        raise ValueError("request_id inválido")

    return ChatContext(
        request_id=request_id,
        message=message.strip(),
        client_history=_clean_client_history(msg.get("history", [])),
        settings=dict(settings),
        image_path=image_path.strip(),
    )


def _prepare_context(context: ChatContext) -> bool:
    if context.prepared:
        return True

    now_text = datetime.datetime.now().strftime("%A, %d de %B de %Y, %H:%M")
    system_prompt = SYSTEM_PROMPT.replace("{fecha_actual}", now_text)
    if context.settings.get("tts_provider", "piper") == "fish":
        system_prompt += FISH_AUDIO_EMOTION_PROMPT

    memories = get_memory_context()
    if memories:
        system_prompt += f"\n\n## Memoria del usuario\n{memories}"

    try:
        pending = get_pending_tasks(report_error=False) or []
        now = datetime.datetime.now()
        upcoming = [
            task
            for task in pending
            if not task.get("due_date")
            or task["due_date"] - now <= datetime.timedelta(days=7)
        ]
        if upcoming:
            tasks_text = "\n".join(
                f"- [ID: {task['id']}] {task['description']} "
                f"(Vence: {task.get('due_date') or 'N/A'})"
                for task in upcoming
            )
            system_prompt += (
                "\n\n## Tareas pendientes del usuario:\n"
                f"{tasks_text}\n\n"
                "Menciónalas solo cuando aporten valor."
            )
    except Exception as exc:
        print(
            f"Minerva: no se pudieron cargar tareas: {type(exc).__name__}",
            file=sys.stderr,
        )

    context.history = [{"role": "system", "content": system_prompt}]
    context.history.extend(context.client_history)
    user_message = {"role": "user", "content": context.message}

    if context.image_path:
        path = pathlib.Path(context.image_path).expanduser()
        try:
            if not is_safe_path(str(path)):
                raise ValueError("la imagen debe estar dentro del directorio HOME")
            path = path.resolve(strict=True)
            if path.suffix.lower() not in _ALLOWED_IMAGE_SUFFIXES:
                raise ValueError("formato de imagen no permitido")
            if not path.is_file() or path.stat().st_size > MAX_IMAGE_BYTES:
                raise ValueError("imagen inexistente o demasiado grande")
            image_bytes = path.read_bytes()
            if image_bytes.startswith(b"\x89PNG\r\n\x1a\n"):
                image_mime = "image/png"
            elif image_bytes.startswith(b"\xff\xd8\xff"):
                image_mime = "image/jpeg"
            elif image_bytes[:4] == b"RIFF" and image_bytes[8:12] == b"WEBP":
                image_mime = "image/webp"
            else:
                raise ValueError("el contenido no corresponde a una imagen válida")
            user_message["image_b64"] = base64.b64encode(image_bytes).decode()
            user_message["image_mime"] = image_mime
        except (OSError, ValueError) as exc:
            _request_event(
                context,
                {"type": "error", "message": f"No se pudo adjuntar la imagen: {exc}"},
            )
            return False

    context.history.append(user_message)
    context.prepared = True
    return True


def _run_chat(context: ChatContext) -> None:
    if context.cancel_event.is_set() or not _prepare_context(context):
        return
    if context.cancel_event.is_set():
        return

    settings = context.settings
    if VOICE_AVAILABLE:
        voice_mgr.set_tts_provider(
            provider=settings.get("tts_provider", "piper"),
            fish_api_key=settings.get("fish_api_key", ""),
            fish_voice_id=settings.get("fish_voice_id", ""),
            fish_model=settings.get("fish_model", ""),
            gemini_api_key=settings.get("gemini_api_key", ""),
            gemini_tts_voice=settings.get("gemini_tts_voice", ""),
            gemini_tts_model=settings.get("gemini_tts_model", ""),
        )

    try:
        temperature = float(settings.get("temperature", "0.7"))
    except (TypeError, ValueError):
        temperature = 0.7
    temperature = max(0.0, min(2.0, temperature))

    do_chat_gemini(
        context.history,
        model=str(settings.get("gemini_model", "gemini-2.5-flash")),
        api_key=str(settings.get("gemini_api_key", "")),
        temperature=temperature,
        cancel_event=context.cancel_event,
        request_id=context.request_id,
        turn_ready_callback=lambda: msg_queue.put({
            "type": "_turn_ready",
            "request_id": context.request_id,
        }),
    )


def _run_chat_worker(context: ChatContext) -> None:
    try:
        _run_chat(context)
    finally:
        chat_slots.release()


def _submit_chat(context: ChatContext) -> bool:
    if not chat_slots.acquire(blocking=False):
        _request_event(
            context,
            {
                "type": "error",
                "message": "Hay demasiadas solicitudes de chat pendientes.",
            },
        )
        return False
    try:
        chat_executor.submit(_run_chat_worker, context)
    except RuntimeError:
        chat_slots.release()
        _request_event(
            context,
            {"type": "error", "message": "El worker de chat no está disponible."},
        )
        return False
    return True


def _command_environment() -> dict[str, str]:
    return safe_session_environment()


def _emit_job_event(job: JobSnapshot, event: dict) -> None:
    if job.turn_id and job.turn_id != "__default__":
        event["request_id"] = job.turn_id
    emit(event)


def _signal_process(process: subprocess.Popen, sig: signal.Signals) -> None:
    try:
        os.killpg(process.pid, sig)
    except (ProcessLookupError, PermissionError, OSError):
        try:
            process.send_signal(sig)
        except (ProcessLookupError, OSError):
            pass


def _execute_command(job: JobSnapshot) -> None:
    process: subprocess.Popen | None = None
    selector: selectors.BaseSelector | None = None
    timed_out = False
    try:
        raw_command = job.command.removeprefix("sudo ") if job.is_sudo else job.command
        shell_args = ["bash", "--noprofile", "--norc", "-c", raw_command]
        command_args = ["pkexec", *shell_args] if job.is_sudo else shell_args
        process = subprocess.Popen(
            command_args,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            bufsize=0,
            cwd=HOME,
            env=_command_environment(),
            start_new_session=True,
        )
        if not job_mgr.attach_process(job.job_id, process):
            _signal_process(process, signal.SIGTERM)

        decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        selector = selectors.DefaultSelector()
        assert process.stdout is not None
        selector.register(process.stdout, selectors.EVENT_READ)
        started_at = time.monotonic()
        terminate_at: float | None = None

        while True:
            now = time.monotonic()
            cancelled = job_mgr.should_cancel(job.job_id)
            if now - started_at > COMMAND_TIMEOUT_SECONDS and not timed_out:
                timed_out = True
                job_mgr.append_output(job.job_id, "\n[Tiempo máximo excedido]\n")
                _signal_process(process, signal.SIGTERM)
                terminate_at = now + 3
            elif cancelled and process.poll() is None and terminate_at is None:
                _signal_process(process, signal.SIGTERM)
                terminate_at = now + 3
            elif terminate_at is not None and now >= terminate_at:
                _signal_process(process, signal.SIGKILL)
                terminate_at = None

            events = selector.select(timeout=0.2)
            for key, _ in events:
                chunk = os.read(key.fileobj.fileno(), 4096)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                text = decoder.decode(chunk)
                if text:
                    captured = job_mgr.append_output(job.job_id, text)
                    if captured:
                        _emit_job_event(job, {
                            "type": "command_output",
                            "job_id": job.job_id,
                            "command": job.command,
                            "text": captured,
                        })

            if process.poll() is not None and not selector.get_map():
                break

        tail = decoder.decode(b"", final=True)
        if tail:
            captured = job_mgr.append_output(job.job_id, tail)
            if captured:
                _emit_job_event(job, {
                    "type": "command_output",
                    "job_id": job.job_id,
                    "command": job.command,
                    "text": captured,
                })
        returncode = process.wait()
        success = returncode == 0 and not timed_out
        job_mgr.set_result(job.job_id, None, 124 if timed_out else returncode, success)
    except Exception as exc:
        if process is not None and process.poll() is None:
            _signal_process(process, signal.SIGKILL)
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                pass
        job_mgr.append_output(
            job.job_id,
            f"\nError ejecutando comando: {type(exc).__name__}: {exc}\n",
        )
        job_mgr.set_result(job.job_id, None, -1, False)
    finally:
        if selector is not None:
            selector.close()
        if process is not None and process.stdout is not None:
            process.stdout.close()
        msg_queue.put({"type": "_internal_cmd_done", "job_id": job.job_id})
        command_slots.release()


def _start_command(job: JobSnapshot) -> None:
    _emit_job_event(job, {
        "type": "command_start",
        "job_id": job.job_id,
        "command": job.command,
    })
    if not command_slots.acquire(blocking=False):
        job_mgr.append_output(job.job_id, "Límite de comandos pendientes alcanzado.")
        job_mgr.set_result(job.job_id, None, -1, False)
        msg_queue.put({"type": "_internal_cmd_done", "job_id": job.job_id})
        return
    try:
        command_executor.submit(_execute_command, job)
    except RuntimeError:
        command_slots.release()
        job_mgr.append_output(job.job_id, "No se pudo iniciar el worker del comando.")
        job_mgr.set_result(job.job_id, None, -1, False)
        msg_queue.put({"type": "_internal_cmd_done", "job_id": job.job_id})


def _append_tool_result(context: ChatContext, job: JobSnapshot, content: str) -> None:
    if not job.tool_call_id:
        return
    context.history.append({
        "role": "tool",
        "tool_call_id": job.tool_call_id,
        "name": "run_command",
        "content": content[:MAX_TOOL_RESULT_CHARS] or "(sin salida)",
    })


def _consume_results_and_resume(context: ChatContext) -> None:
    turn_id = context.request_id
    for finished_job in job_mgr.consume_finished_turn_jobs(turn_id):
        content = (
            "Cancelado por el usuario."
            if finished_job.status == "cancelled"
            else finished_job.output
        )
        _append_tool_result(context, finished_job, content)
    if not job_mgr.all_turn_finished(turn_id):
        return
    job_mgr.clear_turn(turn_id)
    if not context.cancel_event.is_set():
        _submit_chat(context)


def _handle_command_done(msg: dict) -> None:
    context = active_context
    job_id = str(msg.get("job_id", ""))
    job = job_mgr.get(job_id)
    if not job:
        return
    belongs_to_turn = bool(
        context
        and job_mgr.is_turn_job(job_id, context.request_id)
    )
    # La cancelación ya notificó el resultado al momento de solicitarla.
    if job.status == "cancelled":
        return

    _emit_job_event(job, {
        "type": "command_result",
        "job_id": job.job_id,
        "command": job.command,
        "output": job.output[:MAX_TOOL_RESULT_CHARS] or "(sin salida)",
        "returncode": job.returncode,
        "success": job.status == "completed",
        "cancelled": job.status == "cancelled",
    })

    if not context or not belongs_to_turn:
        return
    _consume_results_and_resume(context)


def _cancel_job(job_id: str) -> None:
    context = active_context
    job = job_mgr.cancel(job_id)
    if not job:
        return
    belongs_to_turn = bool(
        context
        and job_mgr.is_turn_job(job_id, context.request_id)
    )
    _emit_job_event(job, {
        "type": "command_result",
        "job_id": job.job_id,
        "command": job.command,
        "output": "Cancelado por el usuario.",
        "returncode": job.returncode,
        "success": False,
        "cancelled": True,
    })
    if context and belongs_to_turn:
        _consume_results_and_resume(context)


def _cancel_active() -> None:
    global active_context

    context = active_context
    if context:
        context.cancel_event.set()
    turn_id = context.request_id if context else None
    jobs = job_mgr.cancel_turn(turn_id)
    job_mgr.clear_turn(turn_id)
    for job in jobs:
        _emit_job_event(job, {
            "type": "command_result",
            "job_id": job.job_id,
            "command": job.command,
            "output": "Cancelado por el usuario.",
            "returncode": job.returncode,
            "success": False,
            "cancelled": True,
        })
    if VOICE_AVAILABLE:
        voice_mgr.stop_tts()
    emit({
        "type": "cancelled",
        "request_id": context.request_id if context else "",
    })


def _transcribe(audio_data) -> None:
    tmp_name = ""
    try:
        import soundfile as sf
        from pywhispercpp.model import Model as WhisperModel

        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
            tmp_name = tmp.name
        sf.write(tmp_name, audio_data, 16000)
        if not voice_mgr.whisper_model:
            voice_mgr.whisper_model = WhisperModel(
                "small",
                language="es",
                print_realtime=False,
                print_progress=False,
            )
        segments = voice_mgr.whisper_model.transcribe(tmp_name)
        text = " ".join(segment.text for segment in segments).strip()
        if text and "[BLANK_AUDIO]" not in text and len(text) >= 2:
            emit({"type": "voice_recognized", "text": text})
        else:
            emit({"type": "voice_recognized", "text": ""})
    except Exception as exc:
        emit_error(f"Error al transcribir: {type(exc).__name__}: {exc}")
    finally:
        if tmp_name:
            try:
                os.unlink(tmp_name)
            except OSError:
                pass


def _transcribe_worker(audio_data) -> None:
    try:
        _transcribe(audio_data)
    finally:
        transcription_slots.release()


def _toggle_voice() -> None:
    if not VOICE_AVAILABLE:
        emit_error("Dependencias de voz no instaladas")
        return
    if not voice_mgr.dependencies_ready:
        detail = voice_mgr.initialization_error or "inicialización en curso"
        emit_error(f"El sistema de voz todavía no está disponible: {detail}")
        return
    if not voice_mgr.is_recording:
        result = voice_mgr.toggle_recording()
        if result == "started":
            emit({"type": "voice_recording_started"})
        else:
            emit_error("No se pudo iniciar la grabación")
        return

    voice_mgr.is_recording = False
    if voice_mgr.stream:
        voice_mgr.stream.stop()
        voice_mgr.stream.close()
    emit({"type": "voice_recording_stopped"})
    if not voice_mgr.audio_data:
        return

    import numpy as np

    audio = np.concatenate(voice_mgr.audio_data, axis=0)
    emit({"type": "voice_transcribing"})
    if not transcription_slots.acquire(blocking=False):
        emit_error("Hay demasiadas transcripciones pendientes")
        return
    try:
        transcription_executor.submit(_transcribe_worker, audio)
    except RuntimeError:
        transcription_slots.release()
        emit_error("El worker de transcripción no está disponible")


def _voice_toggle_worker() -> None:
    try:
        _toggle_voice()
    finally:
        voice_operation_slots.release()


def _submit_voice_toggle() -> None:
    if not voice_operation_slots.acquire(blocking=False):
        emit_error("Hay demasiadas operaciones de voz pendientes")
        return
    try:
        voice_executor.submit(_voice_toggle_worker)
    except RuntimeError:
        voice_operation_slots.release()
        emit_error("El worker de voz no está disponible")


def _tasks_worker() -> None:
    initialized = False
    cleanup_cycle = 0
    while not shutdown_event.is_set():
        try:
            if not initialized:
                initialized = init_db(report_error=False)
                if not initialized:
                    if shutdown_event.wait(300):
                        break
                    continue
            cleanup_cycle += 1
            if cleanup_cycle >= 144:
                clear_completed_tasks(report_error=False)
                cleanup_cycle = 0
            renew_recurring_tasks(report_error=False)
            pending = get_pending_tasks(report_error=False) or []
            now = datetime.datetime.now()
            upcoming = [
                task
                for task in pending
                if not task.get("due_date")
                or task["due_date"] - now <= datetime.timedelta(days=7)
            ]
            if not upcoming:
                emit({"type": "tasks_cleared"})
            else:
                urgency = "low"
                for task in upcoming:
                    due_date = task.get("due_date")
                    if not due_date:
                        continue
                    remaining = due_date - now
                    if remaining < datetime.timedelta(hours=24):
                        urgency = "urgent"
                        break
                    if remaining < datetime.timedelta(days=3):
                        urgency = "medium"
                emit({
                    "type": "tasks_pending",
                    "urgent": urgency == "urgent",
                    "urgency": urgency,
                })
        except Exception as exc:
            print(
                f"Minerva: worker de tareas falló: {type(exc).__name__}",
                file=sys.stderr,
            )
        if shutdown_event.wait(600):
            break


def _decode_message(raw: str | dict) -> dict | None:
    if isinstance(raw, dict):
        return raw
    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError as exc:
        emit_error(f"JSON inválido: {exc}")
        return None
    if not isinstance(decoded, dict):
        emit_error("El mensaje IPC debe ser un objeto JSON")
        return None
    return decoded


def _save_settings(value: object) -> None:
    if not isinstance(value, dict):
        emit_error("settings debe ser un objeto")
        return
    unexpected = set(value) - _SETTING_KEYS
    if unexpected:
        emit_error(f"Ajustes desconocidos: {', '.join(sorted(unexpected))}")
        return
    settings = {}
    for key, item in value.items():
        if not isinstance(item, (str, int, float, bool)):
            emit_error(f"Valor inválido para el ajuste {key}")
            return
        rendered = str(item) if not isinstance(item, str) else item
        if len(rendered) > 4096:
            emit_error(f"El ajuste {key} es demasiado largo")
            return
        settings[key] = item

    config_dir = pathlib.Path(MINERVA_CONFIG_DIR)
    config_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    config_dir.chmod(0o700)
    destination = config_dir / "settings.json"
    temp_name = ""
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=config_dir,
            prefix=".settings-",
            delete=False,
        ) as temporary:
            json.dump(settings, temporary, ensure_ascii=False, indent=2)
            temporary.write("\n")
            temporary.flush()
            temp_name = temporary.name
        os.chmod(temp_name, 0o600)
        os.replace(temp_name, destination)
        emit({"type": "settings_saved"})
    except OSError as exc:
        emit_error(f"No se pudieron guardar los ajustes: {type(exc).__name__}")
    finally:
        if temp_name:
            pathlib.Path(temp_name).unlink(missing_ok=True)


def main() -> None:
    global active_context

    voice_mgr.initialize_async()
    threading.Thread(
        target=_read_stdin,
        name="minerva-stdin",
        daemon=True,
    ).start()
    threading.Thread(
        target=_tasks_worker,
        name="minerva-tasks",
        daemon=True,
    ).start()
    emit({"type": "ready", "model": "Gemini", "home": HOME})

    while not shutdown_event.is_set():
        msg = _decode_message(msg_queue.get())
        if not msg:
            continue
        msg_type = msg.get("type")

        if msg_type == "_shutdown":
            break
        if msg_type == "_protocol_error":
            emit_error(str(msg.get("message", "Error de protocolo")))
            continue
        if msg_type == "chat":
            try:
                context = _parse_chat_message(msg)
            except ValueError as exc:
                emit_error(str(exc))
                continue
            if active_context:
                active_context.cancel_event.set()
                old_turn_id = active_context.request_id
                # Solo desacoplar el turno; NO cancelar los jobs en ejecución.
                # Los procesos en background seguirán corriendo y emitirán sus
                # resultados sin reanudar el chat (belongs_to_turn será False).
                job_mgr.detach_turn(old_turn_id)
                if VOICE_AVAILABLE:
                    voice_mgr.stop_tts()
            active_context = context
            _submit_chat(context)
            continue
        if msg_type == "save_settings":
            _save_settings(msg.get("settings"))
            continue
        if msg_type == "run_confirmed":
            job = job_mgr.claim(
                str(msg.get("job_id", "")),
                expected_sudo=False,
            )
            if job:
                _start_command(job)
            else:
                emit_error("Confirmación inválida o job ya iniciado")
            continue
        if msg_type == "run_sudo":
            job = job_mgr.claim(
                str(msg.get("job_id", "")),
                expected_sudo=True,
            )
            if job:
                _start_command(job)
            else:
                emit_error("Confirmación sudo inválida o job ya iniciado")
            continue
        if msg_type == "_internal_cmd_done":
            _handle_command_done(msg)
            continue
        if msg_type == "_turn_ready":
            if (
                active_context
                and msg.get("request_id") == active_context.request_id
            ):
                _consume_results_and_resume(active_context)
            continue
        if msg_type == "job_cancelled":
            _cancel_job(str(msg.get("job_id", "")))
            continue
        if msg_type == "ping":
            emit({"type": "ready", "model": "Gemini", "home": HOME})
            continue
        if msg_type == "cancel":
            _cancel_active()
            continue
        if msg_type == "stop_tts":
            if VOICE_AVAILABLE:
                voice_mgr.stop_tts()
            continue
        if msg_type == "toggle_voice":
            _submit_voice_toggle()
            continue
        emit_error(f"Tipo de mensaje desconocido: {msg_type!r}")

    shutdown_event.set()
    _cancel_active()
    chat_executor.shutdown(wait=False, cancel_futures=True)
    command_executor.shutdown(wait=False, cancel_futures=True)
    transcription_executor.shutdown(wait=False, cancel_futures=True)
    voice_executor.shutdown(wait=False, cancel_futures=True)


if __name__ == "__main__":
    main()
