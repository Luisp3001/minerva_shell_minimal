#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
LiveSession — Modo de conversación en tiempo real para JARVIS.

Combina Gemini Live API (WebSocket bidireccional gemini-3.8-live) con Fish Audio
para mantener la latencia al mínimo posible.

Flujo:
  Micrófono (PCM 16kHz) → Gemini Live (audio=blob)
      ├── input_transcription  → emit("live_user_prompt") → QML chat
      ├── output_transcription → emit("token") → QML chat
      └── texto de oraciones  → Fish Audio → audio PCM → sounddevice + waveform
"""
from __future__ import annotations

import asyncio
import io
import os
import queue
import re
import sys
import threading
import time
from typing import Any, Optional

try:
    import numpy as np
except ImportError:
    np = None

try:
    import soundfile as sf
except ImportError:
    sf = None

try:
    from fishaudio import AsyncFishAudio
    from fishaudio.types.tts import TTSConfig
    FISH_AUDIO_WS_AVAILABLE = True
except ImportError:
    AsyncFishAudio = None
    TTSConfig = None
    FISH_AUDIO_WS_AVAILABLE = False

from .audio_analyzer import AudioAnalyzer
from .config import FISH_AUDIO_AVAILABLE, VOICE_AVAILABLE
from .io import emit
import backend.core.voice as _voice_module
from .voice import (
    MAX_CLOUD_AUDIO_BYTES,
    StreamEmotionStripper,
    voice_mgr,
)
from ..tools import TOOL_DEFINITIONS, dispatch_tool
from ..tools.screen import ScreenCapture


# ─────────────────────────────────────────────────────────────────────────────
# Constantes
# ─────────────────────────────────────────────────────────────────────────────
LIVE_INACTIVITY_TIMEOUT   = 120        # segundos de silencio → cerrar sesión
LIVE_MIC_CHUNK_MS         = 100        # ms de audio por chunk enviado a Gemini
LIVE_MIC_SAMPLERATE       = 16_000    # Hz requerido por Gemini Live
LIVE_MIC_CHANNELS         = 1
LIVE_MAX_SESSION_SECONDS  = 10 * 60   # límite absoluto de sesión (10 min)
LIVE_SPEECH_RMS_THRESHOLD = 250.0     # Umbral de energía RMS para habla activa en PCM 16-bit

# Opción de depuración de latencias (activada por defecto, configurable con MINERVA_LIVE_DEBUG_LATENCY)
LIVE_DEBUG_LATENCY = os.getenv("MINERVA_LIVE_DEBUG_LATENCY", "1").lower() in ("1", "true", "yes")

# Herramientas permitidas en Live — sin run_command (requiere diálogo de confirmación)
LIVE_ALLOWED_TOOLS: set[str] = {
    "web_search",
    "spotify_music",
    "hyprland_control",
    "capture_screen",
    "list_dir",
    "read_file",
    "file_info",
    "read_pdf",
    "read_docx",
    "read_pptx",
    "read_excel",
    "launch_app",
}

# Modelos Gemini Live conocidos (en orden de preferencia)
_LIVE_MODEL_CANDIDATES = [
    "gemini-3.8-live",
    "gemini-2.5-flash-preview-native-audio-dialog",
    "gemini-2.0-flash-live-001",
]


def _clean_schema(schema: Any) -> Any:
    """
    Limpia recursivamente el esquema JSON de parámetros para compatibilidad con Gemini Live.
    Elimina campos que la API Live de Gemini rechaza (como additionalProperties, $schema, etc.).
    """
    if not isinstance(schema, dict):
        return schema
    bad_keys = {"additionalProperties", "additional_properties", "$schema", "default"}
    cleaned: dict[str, Any] = {}
    for k, v in schema.items():
        if k in bad_keys:
            continue
        if isinstance(v, dict):
            cleaned[k] = _clean_schema(v)
        elif isinstance(v, list):
            cleaned[k] = [_clean_schema(item) if isinstance(item, dict) else item for item in v]
        else:
            cleaned[k] = v
    return cleaned


# ─────────────────────────────────────────────────────────────────────────────
# LiveSession
# ─────────────────────────────────────────────────────────────────────────────

class LiveSession:
    """Gestiona una sesión de conversación en tiempo real JARVIS↔usuario."""

    def __init__(self) -> None:
        self._stop_event: threading.Event = threading.Event()
        self._active: bool = False
        self.is_speaking: bool = False
        self._is_synthesizing: bool = False
        self._in_model_turn: bool = False
        self._playback_cooldown_until: float = 0.0
        self._current_turn_id: int = 0
        self._loop: Optional[asyncio.AbstractEventLoop] = None
        self._thread: Optional[threading.Thread] = None

        # Colas de comunicación entre hilos
        self._mic_queue: queue.Queue[Optional[bytes]] = queue.Queue(maxsize=128)
        self._fish_text_queue: queue.Queue[Optional[str]] = queue.Queue(maxsize=256)
        self._play_queue: queue.Queue[Optional[Any]] = queue.Queue(maxsize=128)

        # Configuración
        self._gemini_api_key  = ""
        self._gemini_model    = ""
        self._fish_api_key    = ""
        self._fish_voice_id   = ""
        self._fish_model      = ""
        self._system_prompt   = ""

        self._current_ai_text = ""
        self._last_activity_ts: float = time.monotonic()
        self._analyzer = AudioAnalyzer(smoothing=0.3)
        self._logged_first_mic = False

        # Métricas de latencia y debug
        self.debug_latency: bool = LIVE_DEBUG_LATENCY
        self._turn_count: int = 0
        self._t_user_last_speech: float = 0.0
        self._t_user_last_vad: float = 0.0
        self._current_turn_speech_end: float = 0.0
        self._t_turn_gemini_first_token: float = 0.0
        self._t_turn_fish_first_audio: float = 0.0
        self._last_user_prompt: str = ""

        # Manejo de audio stream y websocket
        self._current_output_stream: Optional[Any] = None
        self._fish_async_queue: Optional[asyncio.Queue[Optional[tuple[Optional[str], int]]]] = None

    # ──────────────────────────────────────────────────────────────────────────
    # API pública
    # ──────────────────────────────────────────────────────────────────────────

    @property
    def is_active(self) -> bool:
        return self._active

    def _should_mute_mic_to_gemini(self) -> bool:
        """
        Retorna True si debemos enviar silencio (zeros) a Gemini Live en lugar
        del audio real del micrófono. Esto evita que el micrófono capture el audio
        que sale por los altavoces (eco acústico), lo cual causaría falsas
        interrupciones (barge-in) y provocaría que Gemini se responda a sí mismo.
        """
        if self.is_speaking:
            return True
        if not self._play_queue.empty():
            return True
        if self._is_synthesizing:
            return True
        if self._in_model_turn:
            return True
        if time.monotonic() < self._playback_cooldown_until:
            return True
        return False

    def start(
        self,
        gemini_api_key: str,
        gemini_model: str,
        fish_api_key: str,
        fish_voice_id: str,
        fish_model: str,
        system_prompt: str,
    ) -> None:
        """Lanza la sesión Live en un hilo daemon con su propio event loop."""
        if self._active:
            return

        self._gemini_api_key = gemini_api_key
        self._gemini_model   = gemini_model
        self._fish_api_key   = fish_api_key
        self._fish_voice_id  = fish_voice_id
        self._fish_model     = fish_model
        self._system_prompt  = system_prompt

        self._stop_event.clear()
        self._active = True
        self.is_speaking = False
        self._is_synthesizing = False
        self._in_model_turn = False
        self._playback_cooldown_until = 0.0
        self._current_turn_id = 0
        self._logged_first_mic = False
        self._last_activity_ts = time.monotonic()
        self._turn_count = 0
        self._t_user_last_speech = 0.0
        self._t_user_last_vad = 0.0
        self._current_turn_speech_end = 0.0
        self._t_turn_gemini_first_token = 0.0
        self._t_turn_fish_first_audio = 0.0
        self._last_user_prompt = ""
        self._current_output_stream = None

        self._thread = threading.Thread(
            target=self._run_event_loop,
            name="jarvis-live-session",
            daemon=True,
        )
        self._thread.start()

    def stop(self, reason: str = "manual") -> None:
        """Para la sesión de forma limpia desde cualquier hilo."""
        if not self._active:
            return
        self._stop_event.set()
        try:
            self._mic_queue.put_nowait(None)
            self._fish_text_queue.put_nowait(None)
            if self._fish_async_queue is not None:
                self._fish_async_queue.put_nowait(None)
            self._play_queue.put_nowait(None)
        except Exception:
            pass
        if self._current_output_stream is not None:
            try:
                self._current_output_stream.abort()
            except Exception:
                pass
        if self._loop and not self._loop.is_closed():
            self._loop.call_soon_threadsafe(self._loop.stop)
        print(f"[LiveSession] Stop solicitado: {reason}", file=sys.stderr)

    def barge_in(self) -> None:
        """El usuario interrumpe: detiene el audio y cancela la síntesis en curso."""
        if not self._active:
            return
        self._current_turn_id += 1
        while not self._fish_text_queue.empty():
            try:
                self._fish_text_queue.get_nowait()
            except queue.Empty:
                break
        if self._fish_async_queue is not None:
            while not self._fish_async_queue.empty():
                try:
                    self._fish_async_queue.get_nowait()
                except Exception:
                    break
        while not self._play_queue.empty():
            try:
                self._play_queue.get_nowait()
            except queue.Empty:
                break
        if self._current_output_stream is not None:
            try:
                self._current_output_stream.abort()
            except Exception:
                pass
        if _voice_module.sd is not None:
            try:
                _voice_module.sd.stop()
            except Exception:
                pass
        self.is_speaking = False
        self._is_synthesizing = False
        self._in_model_turn = False
        self._playback_cooldown_until = 0.0
        self._analyzer.reset()
        emit({"type": "voice_speaking_stopped"})
        emit({"type": "audio_data", "source": "tts",
              "rms": 0, "band0": 0, "band1": 0, "band2": 0, "band3": 0})
        # Drenar cola de micrófono para empezar limpios
        while not self._mic_queue.empty():
            try:
                self._mic_queue.get_nowait()
            except queue.Empty:
                break
        print("[LiveSession] Barge-in ejecutado con éxito. Altavoz silenciado y micrófono listo.", file=sys.stderr)

    def push_audio_chunk(self, pcm_bytes: bytes) -> None:
        """Encola un chunk de audio de micrófono (llamado desde audio_callback)."""
        if not self._active or self._stop_event.is_set():
            return
        self._last_activity_ts = time.monotonic()
        if not self._logged_first_mic:
            self._logged_first_mic = True
            print(f"[LiveSession] Micrófono capturando y transmitiendo audio ({len(pcm_bytes)} bytes/bloque).", file=sys.stderr)

        # Detección de fin de habla por RMS para medir latencia con precisión
        if not self._should_mute_mic_to_gemini() and np is not None:
            try:
                samples = np.frombuffer(pcm_bytes, dtype=np.int16)
                if len(samples) > 0:
                    rms = float(np.sqrt(np.mean(samples.astype(np.float32) ** 2)))
                    if rms >= LIVE_SPEECH_RMS_THRESHOLD:
                        self._t_user_last_speech = time.monotonic()
            except Exception:
                pass

        try:
            self._mic_queue.put_nowait(pcm_bytes)
        except queue.Full:
            pass

    # ──────────────────────────────────────────────────────────────────────────
    # Event loop principal
    # ──────────────────────────────────────────────────────────────────────────

    def _run_event_loop(self) -> None:
        try:
            self._loop = asyncio.new_event_loop()
            asyncio.set_event_loop(self._loop)
            self._loop.run_until_complete(self._session_main())
        except Exception as exc:
            print(f"[LiveSession] Error fatal: {type(exc).__name__}: {exc}",
                  file=sys.stderr)
        finally:
            self._active = False
            self.is_speaking = False
            emit({"type": "live_session_stopped"})
            print("[LiveSession] Sesión terminada.", file=sys.stderr)

    async def _session_main(self) -> None:
        """Orquesta todas las tareas asíncronas de la sesión."""
        try:
            from google import genai
            from google.genai import types as genai_types
        except ImportError:
            emit({"type": "error",
                  "message": "google-genai no está instalado. Instálalo con: pip install google-genai"})
            return

        if not self._gemini_api_key:
            emit({"type": "error",
                  "message": "Se requiere una API Key de Gemini para el modo Live."})
            return

        if not FISH_AUDIO_AVAILABLE:
            emit({"type": "error",
                  "message": "fish-audio-sdk no está instalado. Instálalo con: pip install fish-audio-sdk"})
            return

        if not self._fish_api_key:
            emit({"type": "error",
                  "message": "JARVIS Live requiere una API Key de Fish Audio."})
            return

        client = genai.Client(
            api_key=self._gemini_api_key,
            http_options=genai_types.HttpOptions(timeout=60_000),
        )

        model = self._resolve_live_model(client)
        if not model:
            emit({"type": "error",
                  "message": "No se encontró un modelo Gemini Live compatible."})
            return

        # Construir definiciones de herramientas permitidas limpiando el esquema JSON
        live_tool_defs = [
            t for t in TOOL_DEFINITIONS
            if t["function"]["name"] in LIVE_ALLOWED_TOOLS
        ]
        genai_tools = []
        for t in live_tool_defs:
            fn = t["function"]
            cleaned_params = _clean_schema(fn.get("parameters"))
            genai_tools.append(
                genai_types.Tool(
                    function_declarations=[
                        genai_types.FunctionDeclaration(
                            name=fn["name"],
                            description=fn.get("description", ""),
                            parameters=cleaned_params,
                        )
                    ]
                )
            )

        # Asegurar system prompt completo de JARVIS
        system_prompt = self._system_prompt.strip()
        if not system_prompt:
            from ..tools.definitions import get_system_prompt, FISH_AUDIO_EMOTION_PROMPT
            system_prompt = get_system_prompt("jarvis") + FISH_AUDIO_EMOTION_PROMPT

        print(
            f"[LiveSession] System prompt configurado ({len(system_prompt)} caracteres, personalidad JARVIS).",
            file=sys.stderr,
        )

        # Gemini 3.8 Live requiere response_modalities=["AUDIO"]
        config = genai_types.LiveConnectConfig(
            response_modalities=["AUDIO"],
            system_instruction=genai_types.Content(
                parts=[genai_types.Part.from_text(text=system_prompt)]
            ),
            tools=genai_tools if genai_tools else None,
        )

        # Inicializar cola asíncrona para Fish Audio WebSocket
        self._fish_async_queue = asyncio.Queue(maxsize=512)

        # Arrancar worker de reproducción de audio
        player_thread = threading.Thread(target=self._player_worker,
                                         name="jarvis-live-player", daemon=True)
        player_thread.start()

        # Determinar si usamos streaming por WebSocket nativo o fallback REST
        use_ws = FISH_AUDIO_WS_AVAILABLE and bool(self._fish_api_key)
        fish_thread = None
        fish_client = None

        if use_ws:
            try:
                fish_client = AsyncFishAudio(api_key=self._fish_api_key)
                print(
                    f"[LiveSession] Fish Audio WebSocket streaming inicializado (modelo: {self._fish_model or 's2-pro'}).",
                    file=sys.stderr,
                )
            except Exception as exc:
                print(f"[LiveSession] Error creando AsyncFishAudio ({exc}); usando fallback REST.", file=sys.stderr)
                fish_client = None
                use_ws = False

        if not use_ws:
            fish_thread = threading.Thread(target=self._fish_tts_worker,
                                           name="jarvis-live-fish", daemon=True)
            fish_thread.start()

        # Asegurar micrófono activo y registrar sink de audio
        if VOICE_AVAILABLE:
            voice_mgr.ensure_mic_active()
            voice_mgr.live_audio_sink = self.push_audio_chunk
            print("[LiveSession] Micrófono registrado y activo en voice_mgr.", file=sys.stderr)
        else:
            print("[LiveSession] VOICE no disponible — sin audio de mic.", file=sys.stderr)

        emit({"type": "live_session_started"})
        print(f"[LiveSession] Sesión iniciada con modelo: {model}", file=sys.stderr)

        deadline = time.monotonic() + LIVE_MAX_SESSION_SECONDS

        try:
            async with client.aio.live.connect(model=model, config=config) as session:
                recv_task = asyncio.create_task(
                    self._receive_task(session)
                )
                send_task = asyncio.create_task(
                    self._send_mic_task(session)
                )
                watch_task = asyncio.create_task(
                    self._watchdog_task(deadline)
                )

                tasks_to_wait = [recv_task, send_task, watch_task]
                tts_task = None
                if use_ws and fish_client is not None:
                    tts_task = asyncio.create_task(self._fish_tts_task(fish_client))
                    tasks_to_wait.append(tts_task)

                done, pending_tasks = await asyncio.wait(
                    tasks_to_wait,
                    return_when=asyncio.FIRST_COMPLETED,
                )
                for t in pending_tasks:
                    t.cancel()
                    try:
                        await t
                    except asyncio.CancelledError:
                        pass
        except Exception as exc:
            print(f"[LiveSession] Error en sesión Gemini: {type(exc).__name__}: {exc}",
                  file=sys.stderr)
            if not self._stop_event.is_set():
                emit({"type": "error",
                      "message": f"Error en sesión Live: {type(exc).__name__}"})
        finally:
            self._stop_event.set()
            if VOICE_AVAILABLE:
                voice_mgr.live_audio_sink = None
            if fish_client is not None:
                try:
                    await fish_client.close()
                except Exception:
                    pass
            try:
                self._mic_queue.put_nowait(None)
                self._fish_text_queue.put_nowait(None)
                if self._fish_async_queue is not None:
                    self._fish_async_queue.put_nowait(None)
                self._play_queue.put_nowait(None)
            except Exception:
                pass
            if fish_thread is not None:
                fish_thread.join(timeout=3)
            player_thread.join(timeout=3)

    # ──────────────────────────────────────────────────────────────────────────
    # Tarea asíncrona: recibir de Gemini
    # ──────────────────────────────────────────────────────────────────────────

    async def _receive_task(self, session) -> None:
        """Lee la respuesta de Gemini y la distribuye al chat y a Fish Audio."""
        stripper = StreamEmotionStripper()
        self._current_ai_text = ""
        user_transcription_parts: list[str] = []
        in_turn = False
        loop = asyncio.get_event_loop()

        while not self._stop_event.is_set():
            try:
                async for response in session.receive():
                    if self._stop_event.is_set():
                        break

                    self._last_activity_ts = time.monotonic()
                    sc = response.server_content

                    # ── Input transcription (Gemini VAD detectó voz del usuario) ─
                    if sc and hasattr(sc, "input_transcription") and sc.input_transcription:
                        it_text = sc.input_transcription.text
                        if it_text:
                            if self._should_mute_mic_to_gemini():
                                print(f"[LiveSession] Ignorando transcripción de eco acústico del altavoz: {it_text!r}", file=sys.stderr)
                            else:
                                print(f"[LiveSession] Usuario dijo (VAD): {it_text!r}", file=sys.stderr)
                                self._t_user_last_vad = time.monotonic()
                                user_transcription_parts.append(it_text)

                    # ── Tool call ────────────────────────────────────────────────
                    if response.tool_call:
                        if user_transcription_parts:
                            user_text = "".join(user_transcription_parts).strip()
                            user_transcription_parts.clear()
                            if user_text:
                                self._last_user_prompt = user_text
                                emit({"type": "live_user_prompt", "text": user_text})

                        for fn_call in response.tool_call.function_calls:
                            tool_name = fn_call.name
                            tool_args = dict(fn_call.args) if fn_call.args else {}
                            call_id   = fn_call.id or ""

                            if tool_name not in LIVE_ALLOWED_TOOLS:
                                result_str = f"Herramienta '{tool_name}' no disponible en modo Live."
                            else:
                                emit({"type": "tool_start", "name": tool_name})
                                print(f"[LiveSession] Tool call: {tool_name}({tool_args})", file=sys.stderr)
                                try:
                                    result = await loop.run_in_executor(
                                        None,
                                        lambda tn=tool_name, ta=tool_args, cid=call_id:
                                            dispatch_tool(tn, ta, tool_call_id=cid),
                                    )
                                    if isinstance(result, ScreenCapture):
                                        result_str = result.text or "(captura realizada)"
                                    else:
                                        result_str = str(result) if result is not None else "OK"
                                except Exception as exc:
                                    result_str = f"Error en {tool_name}: {type(exc).__name__}: {exc}"
                                    print(f"[LiveSession] Tool error: {exc}", file=sys.stderr)

                            try:
                                await session.send_tool_response(
                                    function_responses=[{
                                        "id": call_id,
                                        "name": tool_name,
                                        "response": {"result": result_str},
                                    }]
                                )
                            except Exception as exc:
                                print(f"[LiveSession] Error enviando tool response: {exc}", file=sys.stderr)
                        continue

                    # ── Output transcription / texto parcial (token) ─────────────
                    token = None
                    if sc and hasattr(sc, "output_transcription") and sc.output_transcription:
                        token = sc.output_transcription.text
                    elif response.text:
                        token = response.text

                    if token:
                        if user_transcription_parts:
                            user_text = "".join(user_transcription_parts).strip()
                            user_transcription_parts.clear()
                            if user_text:
                                self._last_user_prompt = user_text
                                emit({"type": "live_user_prompt", "text": user_text})

                        self._current_ai_text += token

                        # Texto limpio → UI
                        clean = stripper.add(token)
                        if clean:
                            emit({"type": "token", "content": clean})

                        # Texto con tags → Fish Audio (WS y REST fallback)
                        if self._fish_async_queue is not None:
                            try:
                                self._fish_async_queue.put_nowait((token, self._current_turn_id))
                            except Exception:
                                pass
                        try:
                            self._fish_text_queue.put_nowait(token)
                        except queue.Full:
                            pass

                        if not in_turn:
                            in_turn = True
                            self._in_model_turn = True
                            self._turn_count += 1
                            self._t_turn_gemini_first_token = time.monotonic()

                            # Fin de habla del usuario para cálculo de latencia
                            now_t = self._t_turn_gemini_first_token
                            if self._t_user_last_speech > 0 and (now_t - self._t_user_last_speech) < 10.0:
                                t_speech_end = self._t_user_last_speech
                            elif self._t_user_last_vad > 0 and (now_t - self._t_user_last_vad) < 10.0:
                                t_speech_end = self._t_user_last_vad
                            else:
                                t_speech_end = now_t
                            self._current_turn_speech_end = t_speech_end
                            gemini_lat_ms = (now_t - t_speech_end) * 1000

                            print("[LiveSession] Gemini respondiendo...", file=sys.stderr)
                            if self.debug_latency:
                                user_txt_prev = self._last_user_prompt or "(voz detectada)"
                                print(f"\n[LiveDebug] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", file=sys.stderr)
                                print(f"[LiveDebug] ⏱️  Turno #{self._turn_count} — Métricas de Latencia en Tiempo Real", file=sys.stderr)
                                print(f"[LiveDebug] 🎤 Usuario fin de habla: 0 ms (ref) | {user_txt_prev!r}", file=sys.stderr)
                                print(f"[LiveDebug] 🤖 Gemini recibió audio y emitió 1er token en +{gemini_lat_ms:.0f} ms", file=sys.stderr)

                            emit({"type": "live_turn_started"})

                    # ── Fin de turno del modelo ────────────────────────────────────
                    if sc and getattr(sc, "turn_complete", False):
                        if user_transcription_parts:
                            user_text = "".join(user_transcription_parts).strip()
                            user_transcription_parts.clear()
                            if user_text:
                                self._last_user_prompt = user_text
                                emit({"type": "live_user_prompt", "text": user_text})

                        remaining = stripper.flush()
                        if remaining:
                            emit({"type": "token", "content": remaining})

                        full_text = self._current_ai_text
                        self._current_ai_text = ""
                        in_turn = False
                        self._in_model_turn = False

                        if self._fish_async_queue is not None:
                            try:
                                self._fish_async_queue.put_nowait((None, self._current_turn_id))
                            except Exception:
                                pass
                        try:
                            self._fish_text_queue.put_nowait(None)  # fin de turno para Fish TTS
                        except queue.Full:
                            pass

                        emit({
                            "type": "live_turn_done",
                            "full_response": full_text,
                        })
                        print("[LiveSession] Turno completado por Gemini. Esperando fin de reproducción...", file=sys.stderr)
                        stripper = StreamEmotionStripper()

                    # ── Interrupción (barge-in del usuario) ───────────────────────
                    if sc and getattr(sc, "interrupted", False):
                        # Solo procesar interrupción si el micrófono no estaba silenciado por reproducción
                        if not self._should_mute_mic_to_gemini():
                            self.barge_in()
                            stripper = StreamEmotionStripper()
                            self._current_ai_text = ""
                            user_transcription_parts.clear()
                            in_turn = False
                            self._in_model_turn = False
                            emit({"type": "live_barge_in"})
                            print("[LiveSession] Barge-in detectado (interrupción).", file=sys.stderr)
                        else:
                            print("[LiveSession] Ignorando señal de interrupción residual de Gemini durante reproducción activa.", file=sys.stderr)
            except Exception as exc:
                if self._stop_event.is_set():
                    break
                print(f"[LiveSession] Error en receive loop: {type(exc).__name__}: {exc}", file=sys.stderr)
                await asyncio.sleep(0.5)

    # ──────────────────────────────────────────────────────────────────────────
    # Tarea asíncrona: enviar audio de mic a Gemini
    # ──────────────────────────────────────────────────────────────────────────

    async def _send_mic_task(self, session) -> None:
        """Lee chunks de la cola de mic y los envía a Gemini Live en bloques de ~100ms."""
        from google.genai import types as genai_types
        loop = asyncio.get_event_loop()
        buffer = bytearray()
        target_bytes = int(LIVE_MIC_SAMPLERATE * 2 * (LIVE_MIC_CHUNK_MS / 1000.0))  # 3200 bytes
        sent_blocks = 0
        was_muted = False

        while not self._stop_event.is_set():
            try:
                chunk = await loop.run_in_executor(
                    None, lambda: self._mic_queue.get(timeout=0.2)
                )
            except queue.Empty:
                if buffer and not self._stop_event.is_set():
                    try:
                        mute = self._should_mute_mic_to_gemini()
                        data_to_send = b'\x00' * len(buffer) if mute else bytes(buffer)
                        blob = genai_types.Blob(data=data_to_send, mime_type="audio/pcm;rate=16000")
                        await session.send_realtime_input(audio=blob)
                        sent_blocks += 1
                    except Exception as e:
                        print(f"[LiveSession] Error enviando audio: {e}", file=sys.stderr)
                    buffer.clear()
                continue

            if chunk is None:
                break

            mute = self._should_mute_mic_to_gemini()
            if mute:
                if not was_muted:
                    was_muted = True
                    print("[LiveSession] Supresión de eco acústico activada (mic silenciado hacia Gemini).", file=sys.stderr)
                # Cuando el altavoz suena, enviamos silencio continuo a Gemini para mantener la conexión activa sin falsos VAD
                buffer.extend(b'\x00' * len(chunk))
            else:
                if was_muted:
                    was_muted = False
                    # Acabamos de salir del silencio: descartar residuos del mic acumulados durante el habla
                    buffer.clear()
                    while not self._mic_queue.empty():
                        try:
                            self._mic_queue.get_nowait()
                        except queue.Empty:
                            break
                    print("[LiveSession] Micrófono reanudado para el usuario.", file=sys.stderr)
                    continue
                buffer.extend(chunk)

            if len(buffer) >= target_bytes:
                try:
                    blob = genai_types.Blob(data=bytes(buffer), mime_type="audio/pcm;rate=16000")
                    await session.send_realtime_input(audio=blob)
                    sent_blocks += 1
                    if sent_blocks == 1:
                        print("[LiveSession] Primer bloque de audio enviado a Gemini Live (audio=blob).", file=sys.stderr)
                except Exception as exc:
                    print(f"[LiveSession] Error enviando audio: {exc}", file=sys.stderr)
                    break
                buffer.clear()

    # ──────────────────────────────────────────────────────────────────────────
    # Tarea asíncrona: vigilante de timeout
    # ──────────────────────────────────────────────────────────────────────────

    async def _watchdog_task(self, deadline: float) -> None:
        """Cierra la sesión si hay inactividad o se supera el tiempo máximo."""
        while not self._stop_event.is_set():
            await asyncio.sleep(5)
            now = time.monotonic()
            if now >= deadline:
                print("[LiveSession] Límite absoluto de sesión alcanzado.",
                      file=sys.stderr)
                emit({"type": "live_session_timeout",
                      "reason": "Límite máximo de sesión alcanzado."})
                self._stop_event.set()
                break
            elapsed_inactive = now - self._last_activity_ts
            if elapsed_inactive >= LIVE_INACTIVITY_TIMEOUT:
                print(f"[LiveSession] Timeout de inactividad ({LIVE_INACTIVITY_TIMEOUT}s).",
                      file=sys.stderr)
                emit({"type": "live_session_timeout",
                      "reason": "Sesión cerrada por inactividad."})
                self._stop_event.set()
                break

    # ──────────────────────────────────────────────────────────────────────────
    # Tarea asíncrona: Fish Audio TTS por WebSocket (Streaming en tiempo real)
    # ──────────────────────────────────────────────────────────────────────────

    async def _fish_tts_task(self, fish_client: Any) -> None:
        """
        Tarea asíncrona: sintetiza tokens en tiempo real mediante WebSocket con Fish Audio.
        Envía cada chunk de audio PCM (44.1kHz 16-bit mono) a _play_queue tan pronto llega.
        """
        while not self._stop_event.is_set():
            try:
                item = await self._fish_async_queue.get()
            except asyncio.CancelledError:
                break
            if item is None:
                continue

            first_token, turn_id = item
            if first_token is None or self._current_turn_id != turn_id:
                continue

            self._is_synthesizing = True
            t_first_chunk = None
            t_speech_end = self._current_turn_speech_end
            t_gemini_token = self._t_turn_gemini_first_token

            async def token_gen():
                if first_token:
                    yield first_token
                while not self._stop_event.is_set() and self._current_turn_id == turn_id:
                    try:
                        sub_item = await asyncio.wait_for(self._fish_async_queue.get(), timeout=0.1)
                    except asyncio.TimeoutError:
                        continue
                    except asyncio.CancelledError:
                        break
                    if sub_item is None:
                        break
                    tok, tok_turn_id = sub_item
                    if tok_turn_id != turn_id or tok is None:
                        break
                    if tok:
                        yield tok

            try:
                async for chunk in fish_client.tts.stream_websocket(
                    token_gen(),
                    reference_id=self._fish_voice_id,
                    format="pcm",
                    config=TTSConfig(sample_rate=44100, latency="balanced"),
                    model=self._fish_model or "s2-pro",
                ):
                    if self._stop_event.is_set() or self._current_turn_id != turn_id:
                        break
                    if not chunk:
                        continue

                    if t_first_chunk is None:
                        t_first_chunk = time.monotonic()
                        fish_ttfb_ms = (t_first_chunk - t_gemini_token) * 1000
                        total_first_audio_ms = (t_first_chunk - t_speech_end) * 1000
                        if self.debug_latency:
                            print(
                                f"[LiveDebug] 🐟 Fish Audio (WebSocket PCM): 1er chunk recibido en +{fish_ttfb_ms:.0f} ms "
                                f"(total hasta 1er audio: +{total_first_audio_ms:.0f} ms)",
                                file=sys.stderr,
                            )

                    audio_np = np.frombuffer(chunk, dtype=np.int16)
                    if len(audio_np) > 0 and self._current_turn_id == turn_id and not self._stop_event.is_set():
                        self._play_queue.put((
                            audio_np,
                            44100,
                            turn_id,
                            t_speech_end,
                            t_gemini_token,
                            t_first_chunk or time.monotonic(),
                        ))

            except asyncio.CancelledError:
                break
            except Exception as exc:
                if self._current_turn_id == turn_id and not self._stop_event.is_set():
                    print(f"[LiveSession/FishWS] Error en stream_websocket: {type(exc).__name__}: {exc}", file=sys.stderr)
            finally:
                self._is_synthesizing = False

    # ──────────────────────────────────────────────────────────────────────────
    # Worker síncrono: Fish Audio TTS (Fallback HTTP REST)
    # ──────────────────────────────────────────────────────────────────────────

    def _fish_tts_worker(self) -> None:
        """
        Consume texto de _fish_text_queue y sintetiza con Fish Audio por oraciones.
        Mantiene la latencia al mínimo reproduciendo frases en cuanto se generan.
        """
        if not FISH_AUDIO_AVAILABLE:
            return

        try:
            from fish_audio_sdk import Session, TTSRequest
            from fishaudio.types import TTSConfig
        except ImportError as exc:
            print(f"[LiveSession/Fish] Error importando SDK: {exc}", file=sys.stderr)
            return

        try:
            fish_client = Session(apikey=self._fish_api_key)
        except Exception as exc:
            print(f"[LiveSession/Fish] Error creando cliente: {exc}", file=sys.stderr)
            return

        # Delimitadores de oraciones: signos de puntuación seguidos de espacio/fin o saltos de línea
        sentence_regex = re.compile(r'([.!?]+(?:\s+|\Z)|[\n\r]+)')

        while not self._stop_event.is_set():
            buffer: list[str] = []

            while not self._stop_event.is_set():
                turn_id = self._current_turn_id
                try:
                    token = self._fish_text_queue.get(timeout=0.2)
                except queue.Empty:
                    continue

                if token is None:
                    # Fin de turno: sintetizar lo que quede
                    if buffer:
                        text_to_speak = "".join(buffer).strip()
                        buffer.clear()
                        words = re.sub(r'\[[\w\s]+\]|[^\w\s]', '', text_to_speak).strip()
                        if words:
                            self._synthesize_fish_phrase(fish_client, TTSRequest, TTSConfig, text_to_speak, turn_id)
                    break

                buffer.append(token)
                joined = "".join(buffer)

                # Buscar la última división de oración
                matches = list(sentence_regex.finditer(joined))
                if matches:
                    last_match = matches[-1]
                    candidate = joined[:last_match.end()].strip()
                    words = re.sub(r'\[[\w\s]+\]|[^\w\s]', '', candidate).strip()
                    # Mínimo de caracteres para no sintetizar fragmentos diminutos
                    if len(candidate) >= 15 and words:
                        text_to_speak = candidate
                        remaining = joined[last_match.end():]
                        buffer = [remaining] if remaining else []
                        self._synthesize_fish_phrase(fish_client, TTSRequest, TTSConfig, text_to_speak, turn_id)

    def _synthesize_fish_phrase(
        self,
        client: Any,
        TTSRequest: Any,
        TTSConfig: Any,
        text: str,
        turn_id: int,
    ) -> None:
        """Sintetiza una frase con Fish Audio y encola el audio (np.ndarray, sr) en _play_queue."""
        if not text or self._stop_event.is_set() or self._current_turn_id != turn_id:
            return

        display_text = (text[:60] + "...") if len(text) > 60 else text
        print(f"[LiveSession/Fish] Sintetizando ({len(text)} car.): {display_text!r}", file=sys.stderr)

        self._is_synthesizing = True
        mp3_buf = io.BytesIO()
        try:
            for chunk in client.tts(
                TTSRequest(
                    reference_id=self._fish_voice_id,
                    text=text,
                    config=TTSConfig(format="wav", latency="normal"),
                ),
                backend=self._fish_model,
            ):
                if self._stop_event.is_set() or self._current_turn_id != turn_id:
                    return
                mp3_buf.write(chunk)
                if mp3_buf.tell() > MAX_CLOUD_AUDIO_BYTES:
                    break

            if mp3_buf.tell() > 0 and not self._stop_event.is_set() and self._current_turn_id == turn_id:
                mp3_buf.seek(0)
                if sf is not None and np is not None:
                    audio_np, sample_rate = sf.read(mp3_buf, dtype="int16", always_2d=False)
                    if audio_np.ndim == 2:
                        audio_np = audio_np.mean(axis=1).astype(np.int16)
                    if self._current_turn_id == turn_id and not self._stop_event.is_set():
                        self._play_queue.put((
                            audio_np,
                            sample_rate,
                            turn_id,
                            self._current_turn_speech_end,
                            self._t_turn_gemini_first_token,
                            time.monotonic(),
                        ))
        except Exception as exc:
            if self._current_turn_id == turn_id and not self._stop_event.is_set():
                print(f"[LiveSession/Fish] Error sintetizando '{display_text}': {exc}", file=sys.stderr)
        finally:
            self._is_synthesizing = False

    # ──────────────────────────────────────────────────────────────────────────
    # Worker síncrono: reproducción de audio (OutputStream streaming continuo)
    # ──────────────────────────────────────────────────────────────────────────

    def _player_worker(self) -> None:
        """Reproduce chunks de audio decodificados (audio_np, sample_rate) con sounddevice."""
        _zero = {"type": "audio_data", "source": "tts",
                 "rms": 0, "band0": 0, "band1": 0, "band2": 0, "band3": 0}

        output_stream = None
        current_sr = None

        def close_stream():
            nonlocal output_stream, current_sr
            if output_stream is not None:
                try:
                    output_stream.stop()
                    output_stream.close()
                except Exception:
                    pass
                output_stream = None
                current_sr = None
                self._current_output_stream = None

        while not self._stop_event.is_set():
            try:
                item = self._play_queue.get(timeout=0.25)
            except queue.Empty:
                if self.is_speaking:
                    self.is_speaking = False
                    self._playback_cooldown_until = time.monotonic() + 0.45
                    emit({"type": "voice_speaking_stopped"})
                    self._analyzer.reset()
                    emit(_zero)
                    close_stream()
                continue

            if item is None:
                break

            if self._stop_event.is_set():
                break

            if len(item) == 2:
                audio_np, sample_rate = item
                turn_id = self._current_turn_id
                t_speech_end = 0.0
                t_gemini = 0.0
                t_fish = 0.0
            else:
                audio_np, sample_rate, turn_id, t_speech_end, t_gemini, t_fish = item[:6]

            if audio_np is None or self._stop_event.is_set() or self._current_turn_id != turn_id:
                continue

            if _voice_module.sd is None:
                continue

            try:
                # Si la frecuencia cambió o el stream no está abierto, crear uno nuevo
                if output_stream is None or current_sr != sample_rate:
                    close_stream()
                    output_stream = _voice_module.sd.OutputStream(
                        samplerate=sample_rate,
                        channels=1,
                        dtype="int16",
                        blocksize=max(1, int(sample_rate * 0.02)),
                    )
                    output_stream.start()
                    current_sr = sample_rate
                    self._current_output_stream = output_stream

                if not self.is_speaking:
                    self.is_speaking = True
                    t_playback_start = time.monotonic()
                    emit({"type": "voice_speaking_started"})

                    if self.debug_latency and t_speech_end > 0:
                        e2e_ms = (t_playback_start - t_speech_end) * 1000
                        gemini_ms = (t_gemini - t_speech_end) * 1000 if t_gemini > 0 else 0
                        fish_ms = (t_fish - t_gemini) * 1000 if t_fish > 0 and t_gemini > 0 else 0
                        print(
                            f"[LiveDebug] 🔊 Inicio de reproducción en altavoces: +{e2e_ms:.0f} ms "
                            f"(latencia total fin de habla → voz sonando)",
                            file=sys.stderr,
                        )
                        print(
                            f"[LiveDebug] 📊 Desglose: Gemini STT+LLM: {gemini_ms:.0f}ms | Fish Audio WS TTFB: {fish_ms:.0f}ms | Buffer/Audio: {max(0, e2e_ms - gemini_ms - fish_ms):.0f}ms",
                            file=sys.stderr,
                        )
                        print(f"[LiveDebug] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", file=sys.stderr)
                        emit({
                            "type": "live_latency_debug",
                            "turn": self._turn_count,
                            "gemini_ms": round(gemini_ms),
                            "fish_ttfb_ms": round(fish_ms),
                            "total_e2e_ms": round(e2e_ms),
                        })

                # Reproducir chunk en bloques de ~20ms emitiendo métricas para el visualizador
                block_size = max(1, int(sample_rate * 0.02))
                for i in range(0, len(audio_np), block_size):
                    if self._stop_event.is_set() or self._current_turn_id != turn_id:
                        break
                    block = audio_np[i : i + block_size]
                    try:
                        output_stream.write(block)
                    except Exception:
                        break
                    metrics = self._analyzer.analyze(block, sample_rate)
                    emit({"type": "audio_data", "source": "tts", **metrics})

            except Exception as exc:
                print(f"[LiveSession/Player] Error reproduciendo: {exc}", file=sys.stderr)
                close_stream()

        close_stream()
        if self.is_speaking:
            self.is_speaking = False
            self._playback_cooldown_until = time.monotonic() + 0.45
            emit({"type": "voice_speaking_stopped"})
            self._analyzer.reset()
            emit(_zero)

    # ──────────────────────────────────────────────────────────────────────────
    # Helpers
    # ──────────────────────────────────────────────────────────────────────────

    def _resolve_live_model(self, client: Any) -> Optional[str]:
        """Devuelve el modelo Live apropiado (gemini-3.8-live por defecto)."""
        user_model = self._gemini_model.strip()
        if any(kw in user_model.lower() for kw in ("live", "dialog")):
            return user_model

        for candidate in _LIVE_MODEL_CANDIDATES:
            return candidate

        return "gemini-3.8-live"


# ─────────────────────────────────────────────────────────────────────────────
# Singleton
# ─────────────────────────────────────────────────────────────────────────────
live_session = LiveSession()
