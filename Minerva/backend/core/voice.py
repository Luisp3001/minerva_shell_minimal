#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VoiceManager — STT (Whisper + Vosk) y TTS (Piper / Fish Audio) para Minerva.

Expone el singleton `voice_mgr` que utilizan los engines de chat.
"""
from fishaudio import TTSConfig
import io
import json
import os
import queue
import sys
import tempfile
import threading
import time

from .audio_analyzer import AudioAnalyzer
from .config import (
    FISH_AUDIO_AVAILABLE,
    GEMINI_TTS_AVAILABLE,
    VOICE_AVAILABLE,
    VOICE_DIR,
    VOSK_AVAILABLE,
)
from .io import emit


MAX_TTS_QUEUE_ITEMS = 128
MAX_PLAY_QUEUE_ITEMS = 32
MAX_CLOUD_AUDIO_BYTES = 25 * 1024 * 1024
MAX_RECORDING_FRAMES = 16000 * 300

np = None
sd = None
sf = None
Model = None
VoskModel = None
KaldiRecognizer = None
FishSession = None
TTSRequest = None
genai = None
genai_types = None


# ── Utilidades de emotion tags ────────────────────────────────────────────────
import re as _re

# Tags soportados por Fish Audio:
# Tags compatibles con Fish Audio, compilados una sola vez.
_EMOTION_TAGS_PATTERN = (
    r"happy|sad|angry|excited|calm|nervous|confident|surprised|disgusted"
)

_EMOTION_TAG_RE = _re.compile(
    rf'\s*\[({_EMOTION_TAGS_PATTERN})\]\s*',
    _re.IGNORECASE
)

def strip_emotion_tags(text: str) -> str:
    """Elimina los emotion tags del texto para mostrarlo limpio en el chat.

    Preserva la separación natural entre palabras sin juntar ni duplicar espacios.
    """
    def _sub(m):
        start = m.start()
        end = m.end()
        prev_char = text[start-1] if start > 0 else ''
        next_char = text[end] if end < len(text) else ''

        if start == 0 or prev_char in '\n\r':
            return ''
        if prev_char.isspace() or next_char.isspace():
            return ''
        return ' '

    cleaned = _EMOTION_TAG_RE.sub(_sub, text)
    cleaned = _re.sub(r'  +', ' ', cleaned)
    return cleaned


class StreamEmotionStripper:
    """Elimina tags parciales sin destruir los espacios entre palabras."""
    def __init__(self):
        self.buffer = ''
        self.emitted_any = False
        self.last_char = ''

    def _strip(self, text: str) -> str:
        def _sub(m):
            start = m.start()
            end = m.end()
            prev_char = text[start-1] if start > 0 else self.last_char
            next_char = text[end] if end < len(text) else ''

            if not self.emitted_any and start == 0 and prev_char == '':
                return ''
            if prev_char in '\n\r':
                return ''
            if prev_char.isspace() or next_char.isspace():
                return ''
            return ' '

        cleaned = _EMOTION_TAG_RE.sub(_sub, text)
        if self.last_char.isspace() and cleaned.startswith(' '):
            cleaned = cleaned.lstrip(' ')
        cleaned = _re.sub(r'  +', ' ', cleaned)
        return cleaned

    def add(self, chunk: str) -> str:
        self.buffer += chunk

        last_bracket = self.buffer.rfind('[')
        if last_bracket != -1:
            closing = self.buffer.find(']', last_bracket)
            if closing == -1 or closing >= len(self.buffer) - 1:
                safe_split = last_bracket
                while safe_split > 0 and self.buffer[safe_split-1].isspace():
                    safe_split -= 1
                out = self.buffer[:safe_split]
                self.buffer = self.buffer[safe_split:]
                out_cleaned = self._strip(out)
                if out_cleaned:
                    self.emitted_any = True
                    self.last_char = out_cleaned[-1]
                return out_cleaned

        out = self.buffer
        self.buffer = ''
        out_cleaned = self._strip(out)
        if out_cleaned:
            self.emitted_any = True
            self.last_char = out_cleaned[-1]
        return out_cleaned

    def flush(self) -> str:
        out = self.buffer
        self.buffer = ''
        out_cleaned = self._strip(out)
        if out_cleaned:
            self.emitted_any = True
            self.last_char = out_cleaned[-1]
        return out_cleaned


class VoiceManager:
    def __init__(self):
        self.is_recording  = False
        self.audio_data    = []
        self.recorded_frames = 0
        self.recording_limit_reached = False
        self.samplerate    = 16000
        self.stream        = None
        self.whisper_model = None
        self.vosk_model = None
        self.vosk_recognizer = None
        self.wake_word_thread = None
        self.dependencies_ready = False
        self.initialization_error = ""
        self._initialization_started = False
        self._initialization_lock = threading.Lock()

        self.piper_voice = None

        # ── Proveedor TTS ──────────────────────────────────────────────────────
        # Proveedores: piper local, Fish Audio o Gemini TTS.
        self.tts_provider = "piper"
        self.fish_api_key = ""
        self.fish_voice_id = "15e8b140868348538ab2d7d887060e78"
        self.fish_model = "speech-1.5"
        self._fish_client = None

        # Gemini TTS
        self.gemini_api_key = ""
        self.gemini_tts_voice = "Kore"
        self.gemini_tts_model = "gemini-2.5-flash-tts"
        self._gemini_client = None

        self.tts_queue = queue.Queue(maxsize=MAX_TTS_QUEUE_ITEMS)
        self.play_queue = queue.Queue(maxsize=MAX_PLAY_QUEUE_ITEMS)
        self.tts_thread    = None
        self.play_thread   = None
        self.tts_stop_event = threading.Event()

        # Analizador de audio para métricas de visualización (RMS + FFT)
        self.analyzer = AudioAnalyzer(smoothing=0.3)

    def initialize_async(self) -> bool:
        """Inicia dependencias pesadas una sola vez y fuera del import."""
        if not VOICE_AVAILABLE:
            return False
        with self._initialization_lock:
            if self._initialization_started:
                return True
            self._initialization_started = True
        try:
            threading.Thread(
                target=self._initialize_dependencies,
                name="minerva-voice-init",
                daemon=True,
            ).start()
        except RuntimeError as exc:
            self.initialization_error = type(exc).__name__
            with self._initialization_lock:
                self._initialization_started = False
            return False
        return True

    def _initialize_dependencies(self) -> None:
        """Carga audio/modelos fuera del arranque crítico del backend."""
        global np, sd, sf, Model
        global VoskModel, KaldiRecognizer
        global FishSession, TTSRequest, genai, genai_types

        try:
            import numpy as numpy_module
            import soundfile as soundfile_module
            from pywhispercpp.model import Model as WhisperModel

            np = numpy_module
            sf = soundfile_module
            Model = WhisperModel

            if VOSK_AVAILABLE:
                from vosk import KaldiRecognizer as VoskRecognizer
                from vosk import Model as VoskModelClass

                VoskModel = VoskModelClass
                KaldiRecognizer = VoskRecognizer
            if FISH_AUDIO_AVAILABLE:
                from fish_audio_sdk import Session, TTSRequest as FishTTSRequest
                from fishaudio.types import TTSConfig

                FishSession = Session
                TTSRequest = FishTTSRequest
            if GEMINI_TTS_AVAILABLE:
                from google import genai as google_genai
                from google.genai import types as google_genai_types

                genai = google_genai
                genai_types = google_genai_types

            # PortAudio puede tardar o fallar según la sesión de escritorio;
            # por eso se importa al final y siempre en este worker.
            import sounddevice as sounddevice_module

            sd = sounddevice_module
            os.makedirs(VOICE_DIR, exist_ok=True)
            self.dependencies_ready = True
            self.tts_thread = threading.Thread(
                target=self._tts_worker,
                name="minerva-tts",
                daemon=True,
            )
            self.play_thread = threading.Thread(
                target=self._play_worker,
                name="minerva-audio-playback",
                daemon=True,
            )
            self.tts_thread.start()
            self.play_thread.start()

            if VOSK_AVAILABLE:
                vosk_path = os.path.join(VOICE_DIR, "vosk-model-es")
                if os.path.exists(vosk_path):
                    self.vosk_model = VoskModel(vosk_path)
                    self.vosk_recognizer = KaldiRecognizer(
                        self.vosk_model,
                        16000,
                    )
                    self.wake_word_thread = threading.Thread(
                        target=self._wake_word_worker,
                        name="minerva-wake-word",
                        daemon=True,
                    )
                    self.wake_word_thread.start()
        except Exception as exc:
            self.initialization_error = f"{type(exc).__name__}: {exc}"
            print(
                f"Error inicializando voz: {self.initialization_error}",
                file=sys.stderr,
            )

    # ── Configuración de proveedor TTS ────────────────────────────────────────

    def enqueue_tts(self, text: str) -> bool:
        """Encola voz sin bloquear el worker de chat cuando hay saturación."""
        if not self.dependencies_ready or self.tts_stop_event.is_set():
            return False
        try:
            self.tts_queue.put_nowait(text)
            return True
        except queue.Full:
            print(
                "[VoiceManager] Cola TTS saturada; fragmento omitido",
                file=sys.stderr,
            )
            return False

    def set_tts_provider(
        self,
        provider: str,
        fish_api_key: str = "",
        fish_voice_id: str = "",
        fish_model: str = "",
        gemini_api_key: str = "",
        gemini_tts_voice: str = "",
        gemini_tts_model: str = "",
    ) -> None:
        """Cambia el proveedor TTS en caliente (sin reiniciar el backend).

        Args:
            provider:         "piper", "fish" o "gemini"
            fish_api_key:     API Key de Fish Audio (solo necesaria si provider="fish")
            fish_voice_id:    reference_id del modelo de voz en Fish Audio
            fish_model: Backend de generación de Fish Audio.
            gemini_api_key:   API Key de Gemini (solo necesaria si provider="gemini")
            gemini_tts_voice: Voz configurada de Gemini TTS.
            gemini_tts_model: Modelo configurado de Gemini TTS.
        """
        normalized_provider = provider.lower().strip()
        self.tts_provider = (
            normalized_provider
            if normalized_provider in {"piper", "fish", "gemini"}
            else "piper"
        )
        self.fish_api_key  = fish_api_key
        if fish_voice_id:
            self.fish_voice_id = fish_voice_id
        if fish_model:
            self.fish_model = fish_model

        # Invalidar el cliente de Fish para que se recree con la nueva API key
        self._fish_client = None

        # Gemini TTS
        self.gemini_api_key = gemini_api_key
        if gemini_tts_voice:
            self.gemini_tts_voice = gemini_tts_voice
        if gemini_tts_model:
            self.gemini_tts_model = gemini_tts_model
        # Invalidar el cliente de Gemini para que se recree con la nueva API key
        self._gemini_client = None

        extra = ""
        if self.tts_provider == "fish":
            extra = f"  model: {self.fish_model!r}  voice_id: {self.fish_voice_id!r}"
        elif self.tts_provider == "gemini":
            extra = (
                f"  model: {self.gemini_tts_model!r} "
                f" voice: {self.gemini_tts_voice!r}"
            )

        print(
            f"[VoiceManager] TTS provider: {self.tts_provider!r}{extra}",
            file=sys.stderr
        )

    def _get_fish_client(self):
        """Retorna (o crea) el cliente de Fish Audio reutilizando la instancia."""
        if self._fish_client is None:
            if not FISH_AUDIO_AVAILABLE:
                raise RuntimeError("fish-audio-sdk no está instalado")
            if not self.fish_api_key:
                raise RuntimeError("Se requiere una API Key de Fish Audio")
            self._fish_client = FishSession(apikey=self.fish_api_key)
        return self._fish_client

    # ── TTS (Gemini) ──────────────────────────────────────────────────────────

    def _get_gemini_client(self):
        """Retorna (o crea) el cliente de Gemini reutilizando la instancia."""
        if self._gemini_client is None:
            if not GEMINI_TTS_AVAILABLE:
                raise RuntimeError("google-genai no está instalado")
            if not self.gemini_api_key:
                raise RuntimeError("Se requiere una API Key de Gemini")
            self._gemini_client = genai.Client(
                api_key=self.gemini_api_key,
                http_options=genai_types.HttpOptions(timeout=60_000),
            )
        return self._gemini_client

    def _synthesize_gemini(self, text: str):
        """Genera audio con Gemini TTS y lo encola en play_queue.

        Gemini TTS retorna PCM crudo (24kHz, 16-bit, mono) que se convierte
        directamente a numpy int16 para reproducción con sounddevice.
        """
        try:
            client = self._get_gemini_client()
        except RuntimeError as e:
            print(f"[Gemini TTS] Error: {e}", file=sys.stderr)
            return

        try:
            response = client.models.generate_content(
                model=self.gemini_tts_model,
                contents=text,
                config=genai_types.GenerateContentConfig(
                    response_modalities=["AUDIO"],
                    speech_config=genai_types.SpeechConfig(
                        voice_config=genai_types.VoiceConfig(
                            prebuilt_voice_config=genai_types.PrebuiltVoiceConfig(
                                voice_name=self.gemini_tts_voice
                            )
                        )
                    ),
                ),
            )

            if self.tts_stop_event.is_set():
                return

            candidates = getattr(response, "candidates", None) or []
            if not candidates or not getattr(candidates[0], "content", None):
                raise ValueError("Gemini TTS no devolvió audio")
            parts = getattr(candidates[0].content, "parts", None) or []
            for part in parts:
                if self.tts_stop_event.is_set():
                    break
                if part.inline_data and part.inline_data.data:
                    pcm_data = part.inline_data.data
                    if len(pcm_data) > MAX_CLOUD_AUDIO_BYTES:
                        raise ValueError("Audio de Gemini demasiado grande")
                    # Gemini TTS: 24kHz, 16-bit, mono PCM
                    audio_np = np.frombuffer(pcm_data, dtype=np.int16)
                    self.play_queue.put((audio_np, 24000))

        except Exception as exc:
            print(
                f"ERROR EN TTS WORKER (Gemini TTS): {type(exc).__name__}",
                file=sys.stderr,
            )

    # ── TTS (Piper) ──────────────────────────────────────────────────────────

    def _ensure_piper_model(self):
        if self.piper_voice is not None:
            return
        try:
            print("Cargando modelo Piper TTS...", file=sys.stderr)
            from piper import PiperVoice
            model_path = os.path.join(VOICE_DIR, "es_MX-claude-high.onnx")
            if not os.path.exists(model_path):
                print(f"Modelo no encontrado: {model_path}", file=sys.stderr)
                return
            self.piper_voice = PiperVoice.load(model_path)
            print("Modelo Piper TTS cargado exitosamente.", file=sys.stderr)
        except Exception as e:
            print(f"Error cargando Piper TTS: {e}", file=sys.stderr)

    # ── TTS (Fish Audio — HTTP streaming) ─────────────────────────────────────

    def _synthesize_fish(self, text: str):
        """Genera audio con Fish Audio (HTTP streaming) y lo encola en play_queue.

        Fish Audio devuelve el audio como un stream de bytes MP3 que se decodifica
        en memoria con soundfile. Para mantener latencia baja, cada respuesta HTTP
        (que ya viene en chunks) se decodifica y encola tan pronto como llega.
        """
        try:
            client = self._get_fish_client()
        except RuntimeError as e:
            print(f"[Fish Audio] Error: {e}", file=sys.stderr)
            return

        try:
            mp3_buffer = io.BytesIO()

            for chunk in client.tts(
                TTSRequest(
                    reference_id=self.fish_voice_id,
                    text=text,
                    config=TTSConfig(format="mp3", mp3_bitrate=128, latency="normal")
                ),
                backend=self.fish_model,
            ):
                if self.tts_stop_event.is_set():
                    break
                mp3_buffer.write(chunk)
                if mp3_buffer.tell() > MAX_CLOUD_AUDIO_BYTES:
                    raise ValueError("Audio de Fish demasiado grande")

            if self.tts_stop_event.is_set():
                return

            # Decodificar el MP3 completo en memoria
            mp3_buffer.seek(0)
            audio_np, sample_rate = sf.read(mp3_buffer, dtype="int16", always_2d=False)

            # Si es estéreo, mezclar a mono
            if audio_np.ndim == 2:
                audio_np = audio_np.mean(axis=1).astype(np.int16)

            self.play_queue.put((audio_np, sample_rate))

        except Exception as exc:
            print(
                f"ERROR EN TTS WORKER (Fish Audio): {type(exc).__name__}",
                file=sys.stderr,
            )

    # ── Worker de síntesis ────────────────────────────────────────────────────

    def _tts_worker(self):
        while True:
            text = self.tts_queue.get()
            if text is None:
                break
            if self.tts_stop_event.is_set():
                self.tts_queue.task_done()
                continue

            try:
                if self.tts_provider == "fish":
                    if not self.tts_stop_event.is_set():
                        self._synthesize_fish(text)
                elif self.tts_provider == "gemini":
                    if not self.tts_stop_event.is_set():
                        self._synthesize_gemini(text)
                else:
                    # Piper (comportamiento original)
                    self._ensure_piper_model()
                    if not self.piper_voice:
                        print("Piper TTS no pudo ser inicializado", file=sys.stderr)
                        self.tts_queue.task_done()
                        continue
                    if not self.tts_stop_event.is_set():
                        for chunk in self.piper_voice.synthesize(text):
                            if self.tts_stop_event.is_set():
                                break
                            audio_np = np.frombuffer(
                                chunk.audio_int16_bytes,
                                dtype=np.int16,
                            )
                            self.play_queue.put((audio_np, chunk.sample_rate))
            except Exception as exc:
                print(
                    "ERROR EN TTS WORKER "
                    f"({self.tts_provider}): {type(exc).__name__}",
                    file=sys.stderr,
                )

            self.tts_queue.task_done()

    def _play_worker(self):
        self.is_speaking = False
        _zero_audio = {"type": "audio_data", "source": "tts",
                       "rms": 0, "band0": 0, "band1": 0, "band2": 0, "band3": 0}
        while True:
            item = self.play_queue.get()
            if item is None:
                if self.is_speaking:
                    emit({"type": "voice_speaking_stopped"})
                    self.analyzer.reset()
                    emit(_zero_audio)
                    self.is_speaking = False
                break

            if not self.is_speaking:
                emit({"type": "voice_speaking_started"})
                self.is_speaking = True

            audio, sample_rate = item
            if not self.tts_stop_event.is_set():
                # Subdividir en chunks de ~20ms para análisis a ~50fps
                sub_size = max(1, int(sample_rate * 0.02))
                metrics_list = []
                for j in range(0, len(audio), sub_size):
                    sub = audio[j:j + sub_size]
                    metrics_list.append(self.analyzer.analyze(sub, sample_rate))

                # Reproducir el chunk completo (non-blocking)
                sd.play(audio, sample_rate)

                # Emitir métricas a intervalos de ~20ms durante la reproducción
                for m in metrics_list:
                    if self.tts_stop_event.is_set():
                        break
                    emit({"type": "audio_data", "source": "tts", **m})
                    time.sleep(0.02)

                # Esperar a que termine la reproducción del chunk
                sd.wait()

            self.play_queue.task_done()

            if self.play_queue.empty() and self.is_speaking:
                emit({"type": "voice_speaking_stopped"})
                self.analyzer.reset()
                emit(_zero_audio)
                self.is_speaking = False

    def stop_tts(self):
        if not VOICE_AVAILABLE:
            return
        self.tts_stop_event.set()
        if self.dependencies_ready and sd is not None:
            try:
                sd.stop()
            except Exception as exc:
                print(
                    f"Error deteniendo audio: {type(exc).__name__}",
                    file=sys.stderr,
                )
        while not self.tts_queue.empty():
            try:
                self.tts_queue.get_nowait()
                self.tts_queue.task_done()
            except queue.Empty:
                break
        while not self.play_queue.empty():
            try:
                self.play_queue.get_nowait()
                self.play_queue.task_done()
            except queue.Empty:
                break
        # Resetear métricas de audio y notificar al frontend
        self.analyzer.reset()
        emit({"type": "audio_data", "source": "tts",
              "rms": 0, "band0": 0, "band1": 0, "band2": 0, "band3": 0})
        if getattr(self, 'is_speaking', False):
            self.is_speaking = False
            emit({"type": "voice_speaking_stopped"})

    # ── Wake word (Vosk) ──────────────────────────────────────────────────────

    def _wake_word_worker(self):
        if not self.vosk_model:
            return
        try:
            with sd.RawInputStream(
                samplerate=16000, blocksize=320, dtype='int16',
                channels=1, callback=self.audio_callback
            ):
                while True:
                    time.sleep(1)
        except Exception as e:
            print(f"Error en wake word stream: {e}", file=sys.stderr)

    def audio_callback(self, indata, frames, time_info, status):
        if self.is_recording:
            if self.recording_limit_reached:
                return
            audio_np = (
                np.frombuffer(indata, dtype=np.int16).astype(np.float32)
                / 32768.0
            )
            self.audio_data.append(audio_np.copy())
            self.recorded_frames += len(audio_np)
            if self.recorded_frames >= MAX_RECORDING_FRAMES:
                self.recording_limit_reached = True
                emit({"type": "silence_detected"})

            # Emitir métricas de audio del micrófono para el Minerva_waveform
            metrics = self.analyzer.analyze(audio_np, 16000)
            emit({"type": "audio_data", "source": "mic", **metrics})

            if self.vosk_recognizer:
                is_final = self.vosk_recognizer.AcceptWaveform(bytes(indata))
                if is_final:
                    res  = json.loads(self.vosk_recognizer.Result())
                    text = res.get("text", "")
                    if text.strip():
                        emit({"type": "silence_detected"})
        elif self.vosk_recognizer:
            if getattr(self, 'is_speaking', False):
                self.vosk_recognizer.Reset()
                return

            is_final = self.vosk_recognizer.AcceptWaveform(bytes(indata))
            if is_final:
                res  = json.loads(self.vosk_recognizer.Result())
                text = res.get("text", "")
            else:
                res  = json.loads(self.vosk_recognizer.PartialResult())
                text = res.get("partial", "")

            if "minerva" in text.lower():
                if not self.is_recording:
                    self.vosk_recognizer.Reset()
                    emit({"type": "wake_word_detected"})

    # ── Grabación / Transcripción ─────────────────────────────────────────────

    def toggle_recording(self):
        if not VOICE_AVAILABLE:
            return None

        if not self.is_recording:
            self.stop_tts()
            self.tts_stop_event.clear()
            self.is_recording = True
            self.audio_data = []
            self.recorded_frames = 0
            self.recording_limit_reached = False
            if (
                not getattr(self, "wake_word_thread", None)
                or not self.wake_word_thread.is_alive()
            ):
                self.stream = sd.RawInputStream(
                    samplerate=16000, blocksize=320, dtype='int16',
                    channels=1, callback=self.audio_callback
                )
                self.stream.start()
            return "started"
        else:
            self.is_recording = False
            if self.stream:
                self.stream.stop()
                self.stream.close()
                self.stream = None

            if not self.audio_data:
                return "empty"

            audio_np = np.concatenate(self.audio_data, axis=0)

            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
                sf.write(tmp.name, audio_np, self.samplerate)
                tmp_name = tmp.name

            if not self.whisper_model:
                try:
                    self.whisper_model = Model(
                        "small", language="es",
                        print_realtime=False, print_progress=False
                    )
                except Exception:
                    os.remove(tmp_name)
                    return "error"

            try:
                segments = self.whisper_model.transcribe(tmp_name)
                text = " ".join([s.text for s in segments]).strip()
            except Exception:
                text = "error"
            finally:
                os.remove(tmp_name)

            return text


# ─────────────────────────────────────────────────────────────────────────────
# Singleton
# ─────────────────────────────────────────────────────────────────────────────
voice_mgr = VoiceManager()
