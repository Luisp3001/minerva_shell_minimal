#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Configuración global del backend Minerva.
Todas las constantes y flags de disponibilidad de dependencias opcionales.
"""
import os
import pathlib
from importlib.util import find_spec

from dotenv import load_dotenv

# ─────────────────────────────────────────────────────────────────────────────
# Directorio de configuración unificado: ~/.config/minerva
# ─────────────────────────────────────────────────────────────────────────────
_HOME_EARLY = str(pathlib.Path.home())
MINERVA_CONFIG_DIR = os.path.join(_HOME_EARLY, ".config", "minerva")

# Cargar variables de entorno desde ~/.config/minerva/.env
# Fallback al .env antiguo (backend/.env) para compatibilidad durante la transición
_env_primary  = os.path.join(MINERVA_CONFIG_DIR, ".env")
_env_fallback = os.path.join(os.path.dirname(__file__), "..", ".env")
load_dotenv(_env_primary if os.path.exists(_env_primary) else _env_fallback)

# ─────────────────────────────────────────────────────────────────────────────
# Configuración base
# ─────────────────────────────────────────────────────────────────────────────
HOME     = str(pathlib.Path.home())

MAX_DIR  = 4_096   # 4 KiB máx por listado de directorio

# ─────────────────────────────────────────────────────────────────────────────
# Spotify  (ahora dentro de ~/.config/minerva/)
# ─────────────────────────────────────────────────────────────────────────────
SPOTIFY_CONFIG_DIR = MINERVA_CONFIG_DIR
SPOTIFY_CREDS_FILE = os.path.join(SPOTIFY_CONFIG_DIR, "credentials.json")
SPOTIFY_TOKEN_FILE = os.path.join(SPOTIFY_CONFIG_DIR, "token_cache.json")
SPOTIFY_API_BASE   = "https://api.spotify.com/v1"
SPOTIFY_AUTH_URL   = "https://accounts.spotify.com/authorize"
SPOTIFY_TOKEN_URL  = "https://accounts.spotify.com/api/token"
SPOTIFY_SCOPES     = (
    "user-read-playback-state user-modify-playback-state "
    "user-read-currently-playing streaming app-remote-control "
    "user-read-private playlist-modify-public"
)

# ─────────────────────────────────────────────────────────────────────────────
# Voz (STT / TTS)
# ─────────────────────────────────────────────────────────────────────────────
PLUGIN_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
VOICE_DIR = os.environ.get("MINERVA_VOICE_DIR", os.path.join(PLUGIN_DIR, "voice"))
REF_WAV   = os.path.join(VOICE_DIR, "referencia.wav")
REF_TXT   = os.path.join(VOICE_DIR, "referencia.txt")

# ─────────────────────────────────────────────────────────────────────────────
# Disponibilidad de dependencias opcionales
# ─────────────────────────────────────────────────────────────────────────────
def _available(*module_names: str) -> bool:
    """Comprueba presencia sin ejecutar imports pesados durante el arranque."""
    try:
        return all(find_spec(name) is not None for name in module_names)
    except (ImportError, ModuleNotFoundError, ValueError):
        return False


WEB_SEARCH_AVAILABLE = _available("ddgs")
VOICE_AVAILABLE = _available(
    "numpy",
    "sounddevice",
    "soundfile",
    "pywhispercpp.model",
)
VOSK_AVAILABLE = _available("vosk")
FISH_AUDIO_AVAILABLE = _available("fish_audio_sdk")
GEMINI_TTS_AVAILABLE = _available("google.genai")
