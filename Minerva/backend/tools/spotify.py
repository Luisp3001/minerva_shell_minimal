#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SpotifyManager — OAuth 2.0 PKCE + API REST de Spotify para Minerva.

Expone:
  - SpotifyManager (clase)
  - spotify_mgr   (singleton)
  - tool_spotify_music() (función unificada para la IA)
"""
import base64
import errno
import hashlib
import json
import math
import os
import secrets
import stat
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

from ..core.config import (
    SPOTIFY_API_BASE,
    SPOTIFY_AUTH_URL,
    SPOTIFY_CREDS_FILE,
    SPOTIFY_SCOPES,
    SPOTIFY_TOKEN_FILE,
    SPOTIFY_TOKEN_URL,
)
from ..core.io import emit, safe_session_environment


MAX_TOKEN_CHARS = 16 * 1024


def _valid_token(value: object) -> str | None:
    if isinstance(value, str) and 0 < len(value) <= MAX_TOKEN_CHARS:
        return value
    return None


def _token_expiry(data: dict) -> float:
    expires_in = data.get("expires_in", 3600)
    if (
        not isinstance(expires_in, (int, float))
        or isinstance(expires_in, bool)
        or not math.isfinite(expires_in)
    ):
        expires_in = 3600
    return time.time() + max(120.0, min(86400.0, float(expires_in))) - 60


def _write_private_json(path: str, data: dict) -> None:
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    os.chmod(directory, 0o700)
    temp_name = ""
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=directory,
            prefix=".minerva-spotify-",
            delete=False,
        ) as temporary:
            json.dump(data, temporary, indent=2)
            temporary.write("\n")
            temporary.flush()
            temp_name = temporary.name
        os.chmod(temp_name, 0o600)
        os.replace(temp_name, path)
    finally:
        if temp_name:
            try:
                os.unlink(temp_name)
            except FileNotFoundError:
                pass


def _ensure_private_file(path: str) -> None:
    """Corrige permisos solo cuando son más amplios que 0600."""
    mode = stat.S_IMODE(os.stat(path).st_mode)
    if mode != 0o600:
        os.chmod(path, 0o600)


class SpotifyManager:
    """Gestiona la autenticación OAuth 2.0 PKCE y las llamadas a la API de Spotify."""

    def __init__(self):
        self.access_token  = None
        self.refresh_token = None
        self.token_expiry  = 0
        self.client_id     = None
        self.redirect_uri = "http://127.0.0.1:8888/callback"
        self._lock = threading.RLock()
        self._refresh_lock = threading.Lock()
        self._auth_in_progress = False
        self._last_refresh_error = ""
        self._load_credentials()
        self._load_cached_token()

    # ── Autenticación ──────────────────────────────────────────────────────────

    def _load_credentials(self):
        """Carga el identificador público OAuth y el callback local."""
        if not os.path.exists(SPOTIFY_CREDS_FILE):
            try:
                _write_private_json(SPOTIFY_CREDS_FILE, {
                    "client_id": "TU_CLIENT_ID_AQUI",
                    "redirect_uri": "http://127.0.0.1:8888/callback",
                })
            except Exception as e:
                print(
                    "Error creando credenciales de Spotify: "
                    f"{type(e).__name__}",
                    file=sys.stderr,
                )
            return
        try:
            with open(SPOTIFY_CREDS_FILE, "r") as f:
                creds = json.load(f)
            client_id = creds.get("client_id", "")
            redirect_uri = creds.get("redirect_uri", self.redirect_uri)
            self.client_id = (
                client_id.strip()[:512]
                if isinstance(client_id, str)
                else ""
            )
            if isinstance(redirect_uri, str):
                parsed_redirect = urllib.parse.urlparse(redirect_uri)
                valid_redirect = (
                    parsed_redirect.scheme == "http"
                    and parsed_redirect.hostname in {"127.0.0.1", "localhost"}
                    and parsed_redirect.port == 8888
                    and parsed_redirect.path == "/callback"
                    and not parsed_redirect.username
                    and not parsed_redirect.password
                    and not parsed_redirect.query
                    and not parsed_redirect.fragment
                )
                if valid_redirect:
                    self.redirect_uri = redirect_uri
            if self.client_id in ("", "TU_CLIENT_ID_AQUI"):
                self.client_id = None
            _ensure_private_file(SPOTIFY_CREDS_FILE)
        except (OSError, json.JSONDecodeError, AttributeError) as exc:
            print(
                f"Error leyendo credenciales de Spotify: {type(exc).__name__}",
                file=sys.stderr,
            )

    def _load_cached_token(self):
        """Carga tokens desde cache en disco."""
        if not os.path.exists(SPOTIFY_TOKEN_FILE):
            return
        try:
            with open(SPOTIFY_TOKEN_FILE, "r") as f:
                data = json.load(f)
            access_token = data.get("access_token")
            refresh_token = data.get("refresh_token")
            token_expiry = data.get("token_expiry", 0)
            self.access_token = _valid_token(access_token)
            self.refresh_token = _valid_token(refresh_token)
            valid_expiry = (
                isinstance(token_expiry, (int, float))
                and not isinstance(token_expiry, bool)
                and math.isfinite(token_expiry)
            )
            self.token_expiry = float(token_expiry) if valid_expiry else 0
            _ensure_private_file(SPOTIFY_TOKEN_FILE)
        except (OSError, json.JSONDecodeError, AttributeError) as exc:
            print(
                f"Error leyendo token de Spotify: {type(exc).__name__}",
                file=sys.stderr,
            )

    def _save_token_cache(self):
        """Persiste tokens en disco."""
        try:
            _write_private_json(SPOTIFY_TOKEN_FILE, {
                "access_token": self.access_token,
                "refresh_token": self.refresh_token,
                "token_expiry": self.token_expiry,
            })
        except OSError as exc:
            print(
                f"Error guardando token de Spotify: {type(exc).__name__}",
                file=sys.stderr,
            )

    def is_configured(self) -> bool:
        # Una app de escritorio con PKCE es un cliente público: no puede
        # proteger de forma real un client_secret embebido.
        return bool(self.client_id)

    def is_authenticated(self) -> bool:
        return bool(self.access_token or self.refresh_token)

    def _token_expired(self) -> bool:
        with self._lock:
            return time.time() >= self.token_expiry

    def _refresh_access_token(self) -> bool:
        with self._refresh_lock:
            with self._lock:
                if self.access_token and not self._token_expired():
                    return True
            return self._refresh_access_token_unlocked()

    def _refresh_access_token_unlocked(self) -> bool:
        """Refresca el access token usando el refresh token."""
        if not self.refresh_token or not self.client_id:
            return False
        with self._lock:
            refresh_token = self.refresh_token
            client_id = self.client_id
        try:
            data = urllib.parse.urlencode({
                "grant_type":    "refresh_token",
                "refresh_token": refresh_token,
                "client_id": client_id,
            }).encode()
            req = urllib.request.Request(SPOTIFY_TOKEN_URL, data=data, method="POST")
            req.add_header("Content-Type", "application/x-www-form-urlencoded")
            with urllib.request.urlopen(req, timeout=10) as resp:
                raw = resp.read(64 * 1024 + 1)
            if len(raw) > 64 * 1024:
                raise ValueError("respuesta de token demasiado grande")
            token_data = json.loads(raw.decode())
            access_token = _valid_token(token_data.get("access_token"))
            if not access_token:
                raise ValueError("respuesta de token inválida")
            with self._lock:
                self.access_token = access_token
                self.token_expiry = _token_expiry(token_data)
                refresh_token = _valid_token(token_data.get("refresh_token"))
                if refresh_token:
                    self.refresh_token = refresh_token
                self._last_refresh_error = ""
            self._save_token_cache()
            return True
        except Exception as exc:
            with self._lock:
                self._last_refresh_error = type(exc).__name__
            return False

    def _get_valid_token(self) -> str:
        """Obtiene un token válido, refrescando si es necesario."""
        if self._token_expired():
            with self._lock:
                can_refresh = bool(self.refresh_token)
            if not can_refresh or not self._refresh_access_token():
                return ""
        with self._lock:
            return self.access_token or ""

    def _api_request(self, method: str, endpoint: str, body: dict = None,
                     params: dict = None, timeout: int = 10) -> dict:
        """Hace una petición autenticada a la API de Spotify."""
        url = f"{SPOTIFY_API_BASE}{endpoint}"
        if params:
            url += "?" + urllib.parse.urlencode(params)

        body_bytes = json.dumps(body).encode() if body else None
        refreshed = False
        for attempt in range(3):
            token = self._get_valid_token()
            if not token:
                detail = (
                    f" ({self._last_refresh_error})"
                    if self._last_refresh_error
                    else ""
                )
                return {
                    "error": "No hay un token válido de Spotify. "
                    f"Necesitas autenticarte de nuevo{detail}."
                }

            req = urllib.request.Request(url, data=body_bytes, method=method)
            req.add_header("Authorization", f"Bearer {token}")
            if body:
                req.add_header("Content-Type", "application/json")

            try:
                with urllib.request.urlopen(req, timeout=timeout) as resp:
                    raw = resp.read(2 * 1024 * 1024 + 1)
                    if len(raw) > 2 * 1024 * 1024:
                        return {"error": "Respuesta de Spotify demasiado grande."}
                    stripped = raw.strip()
                    if not stripped:
                        return {"success": True}
                    try:
                        parsed = json.loads(stripped.decode())
                    except (json.JSONDecodeError, UnicodeDecodeError):
                        return {"error": "Spotify devolvió JSON inválido."}
                    if not isinstance(parsed, dict):
                        return {"error": "Spotify devolvió una respuesta inválida."}
                    return parsed
            except urllib.error.HTTPError as exc:
                error_body = (
                    exc.read(4096).decode(errors="replace") if exc.fp else ""
                )
                retry_after_header = exc.headers.get("Retry-After", "")
                exc.close()
                if exc.code == 401 and not refreshed:
                    refreshed = True
                    with self._lock:
                        self.token_expiry = 0
                    if self._refresh_access_token():
                        continue
                if exc.code == 429 or 500 <= exc.code < 600:
                    if attempt < 2:
                        try:
                            delay = min(
                                10.0,
                                max(0.5, float(retry_after_header)),
                            )
                        except (TypeError, ValueError):
                            delay = min(4.0, 2.0 ** attempt)
                        time.sleep(delay)
                        continue
                return {"error": f"Error HTTP {exc.code}: {error_body[:500]}"}
            except (TimeoutError, urllib.error.URLError) as exc:
                if attempt < 2:
                    time.sleep(min(4.0, 2.0 ** attempt))
                    continue
                return {"error": f"Error de conexión: {type(exc).__name__}"}
            except Exception as exc:
                return {"error": f"Error de conexión: {type(exc).__name__}"}

        return {"error": "Spotify no respondió después de varios intentos."}

    def start_authentication(self) -> bool:
        """Reserva y arranca un único flujo OAuth en segundo plano."""
        if not self.is_configured():
            return False
        with self._lock:
            if self._auth_in_progress:
                return False
            self._auth_in_progress = True

        def worker() -> None:
            result = self.authenticate(_already_claimed=True)
            emit({
                "type": "spotify_auth_result",
                "message": result,
                "success": result == "Autenticación con Spotify exitosa.",
            })

        auth_thread = threading.Thread(
            target=worker,
            name="minerva-spotify-oauth",
            daemon=True,
        )
        try:
            auth_thread.start()
        except RuntimeError:
            with self._lock:
                self._auth_in_progress = False
            return False
        return True

    def authenticate(self, _already_claimed: bool = False) -> str:
        """Inicia el flujo OAuth 2.0 Authorization Code con PKCE."""
        if not self.is_configured():
            return (
                "Spotify no está configurado. Edita el archivo "
                f"{SPOTIFY_CREDS_FILE} con tu client_id "
                "de https://developer.spotify.com/dashboard"
            )
        if not _already_claimed:
            with self._lock:
                if self._auth_in_progress:
                    return "Ya hay una autenticación de Spotify en curso."
                self._auth_in_progress = True

        code_verifier  = secrets.token_urlsafe(64)[:128]
        code_challenge = base64.urlsafe_b64encode(
            hashlib.sha256(code_verifier.encode()).digest()
        ).rstrip(b"=").decode()
        state = secrets.token_urlsafe(16)

        auth_params = urllib.parse.urlencode({
            "client_id":              self.client_id,
            "response_type":          "code",
            "redirect_uri":           self.redirect_uri,
            "scope":                  SPOTIFY_SCOPES,
            "state":                  state,
            "code_challenge_method":  "S256",
            "code_challenge":         code_challenge
        })
        auth_url = f"{SPOTIFY_AUTH_URL}?{auth_params}"

        auth_result = {"code": None, "error": None}

        class CallbackHandler(BaseHTTPRequestHandler):
            def do_GET(self):
                parsed_path = urllib.parse.urlparse(self.path)
                query = urllib.parse.parse_qs(parsed_path.query)
                received_state = query.get("state", [""])[0]
                if parsed_path.path != "/callback" or received_state != state:
                    self.send_response(400)
                    self.end_headers()
                    self.wfile.write(b"Callback OAuth invalido")
                elif "code" in query:
                    auth_result["code"] = query["code"][0]
                    self.send_response(200)
                    self.send_header("Content-Type", "text/html; charset=utf-8")
                    self.end_headers()
                    self.wfile.write(
                        b"<html><body><h2>Autorizacion exitosa. "
                        b"Puedes cerrar esta ventana.</h2></body></html>"
                    )
                else:
                    auth_result["error"] = query.get("error", ["unknown"])[0]
                    self.send_response(400)
                    self.end_headers()
                    self.wfile.write(b"Error en la autorizacion")
            def log_message(self, fmt, *args):
                pass

        server = None
        try:
            server = HTTPServer(("127.0.0.1", 8888), CallbackHandler)
            server.timeout = 1
            emit({"type": "spotify_auth_url", "url": auth_url})
            try:
                subprocess.Popen(
                    ["gio", "open", auth_url],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True,
                    env=safe_session_environment(),
                )
            except OSError:
                # La URL ya fue enviada a QML para apertura manual.
                pass
            deadline = time.monotonic() + 120
            while (
                auth_result["code"] is None
                and auth_result["error"] is None
                and time.monotonic() < deadline
            ):
                server.handle_request()

            if auth_result["code"] is None and auth_result["error"] is None:
                return "La autorización de Spotify expiró después de 120 segundos."

            if auth_result["error"]:
                return f"Error de autorización: {auth_result['error']}"

            token_data = urllib.parse.urlencode({
                "grant_type":    "authorization_code",
                "code":          auth_result["code"],
                "redirect_uri":  self.redirect_uri,
                "client_id":     self.client_id,
                "code_verifier": code_verifier
            }).encode()

            req = urllib.request.Request(
                SPOTIFY_TOKEN_URL,
                data=token_data,
                method="POST",
            )
            req.add_header("Content-Type", "application/x-www-form-urlencoded")
            with urllib.request.urlopen(req, timeout=10) as resp:
                raw = resp.read(64 * 1024 + 1)
            if len(raw) > 64 * 1024:
                raise ValueError("respuesta de token demasiado grande")
            tokens = json.loads(raw.decode())
            access_token = _valid_token(tokens.get("access_token"))
            if not access_token:
                raise ValueError("respuesta de token inválida")

            with self._lock:
                self.access_token = access_token
                self.refresh_token = _valid_token(tokens.get("refresh_token"))
                self.token_expiry = _token_expiry(tokens)
            self._save_token_cache()
            return "Autenticación con Spotify exitosa."

        except OSError as exc:
            if exc.errno == errno.EADDRINUSE:
                return (
                    "El puerto 8888 está en uso. Cierra el proceso que lo usa "
                    "e intenta de nuevo."
                )
            return (
                "Error al iniciar el callback de Spotify: "
                f"{type(exc).__name__}"
            )
        except Exception as exc:
            return f"Error durante la autenticación: {type(exc).__name__}"
        finally:
            if server is not None:
                server.server_close()
            with self._lock:
                self._auth_in_progress = False

    # ── Métodos de la API ──────────────────────────────────────────────────────

    def search(self, query: str, search_type: str = "track", limit: int = 5) -> str:
        valid_types = {"track", "artist", "album", "playlist"}
        if search_type not in valid_types:
            search_type = "track"
        limit  = max(1, min(10, limit))
        result = self._api_request("GET", "/search", params={
            "q": query, "type": search_type, "limit": limit, "market": "from_token"
        })
        if "error" in result:
            return result["error"]

        lines     = [f"Resultados de Spotify para '{query}' (tipo: {search_type}):\n"]
        items_key = f"{search_type}s"
        items     = result.get(items_key, {}).get("items", [])

        if not items:
            return f"No se encontraron resultados para '{query}'"

        for i, item in enumerate(items, 1):
            if search_type == "track":
                artists = ", ".join(a.get("name", "") for a in item.get("artists", []))
                album        = item.get("album", {}).get("name", "")
                duration_ms  = item.get("duration_ms", 0)
                mins, secs   = divmod(duration_ms // 1000, 60)
                uri          = item.get("uri", "")
                lines.append(f"[{i}] {item.get('name', 'Sin nombre')} — {artists}")
                lines.append(f"    Album: {album} | Duracion: {mins}:{secs:02d}")
                lines.append(f"    URI: {uri}")
            elif search_type == "artist":
                genres    = ", ".join(item.get("genres", [])[:3]) or "Sin genero"
                followers = item.get("followers", {}).get("total", 0)
                uri       = item.get("uri", "")
                lines.append(f"[{i}] {item.get('name', 'Sin nombre')}")
                lines.append(f"    Generos: {genres} | Seguidores: {followers:,}")
                lines.append(f"    URI: {uri}")
            elif search_type == "album":
                artists = ", ".join(a.get("name", "") for a in item.get("artists", []))
                year    = item.get("release_date", "")[:4]
                tracks  = item.get("total_tracks", 0)
                uri     = item.get("uri", "")
                lines.append(f"[{i}] {item.get('name', 'Sin nombre')} — {artists}")
                lines.append(f"    Año: {year} | Canciones: {tracks}")
                lines.append(f"    URI: {uri}")
            elif search_type == "playlist":
                owner = item.get("owner", {}).get("display_name", "")
                total = item.get("tracks", {}).get("total", 0)
                uri   = item.get("uri", "")
                lines.append(f"[{i}] {item.get('name', 'Sin nombre')}")
                lines.append(f"    Por: {owner} | Canciones: {total}")
                lines.append(f"    URI: {uri}")
            lines.append("")

        return "\n".join(lines).strip()

    def play(self, uri: str = None, query: str = None) -> str:
        body = {}
        if not uri and query:
            search_result = self._api_request("GET", "/search", params={
                "q": query, "type": "track", "limit": 10, "market": "from_token"
            })
            if "error" in search_result:
                return search_result["error"]
            tracks = search_result.get("tracks", {}).get("items", [])
            if not tracks:
                return f"No se encontro ninguna cancion para '{query}'"
            tracks.sort(key=lambda x: x.get("popularity", 0), reverse=True)
            uri = tracks[0].get("uri", "")
            track_name = tracks[0].get("name", "Sin nombre")
            artist_name = ", ".join(
                artist.get("name", "")
                for artist in tracks[0].get("artists", [])
            )
            if not uri:
                return "Spotify devolvió una canción sin URI utilizable."

        if uri:
            if ":track:" in uri:
                body["uris"] = [uri]
            elif ":album:" in uri or ":playlist:" in uri or ":artist:" in uri:
                body["context_uri"] = uri
            else:
                body["uris"] = [uri]

        result = self._api_request(
            "PUT",
            "/me/player/play",
            body=body or None,
            timeout=20,
        )
        if "error" in result:
            return result["error"]
        if not query and not uri:
            return (
                "Reproduccion reanudada. La accion fue exitosa, "
                "NO repitas la llamada."
            )
        if query:
            return (
                f"Reproduciendo: {track_name} — {artist_name}. "
                "La accion fue exitosa, NO repitas la llamada."
            )
        return "Reproduccion iniciada. La accion fue exitosa, NO repitas la llamada."

    def pause(self) -> str:
        result = self._api_request("PUT", "/me/player/pause", timeout=20)
        return result.get(
            "error",
            "Reproduccion pausada. Accion exitosa; no repitas la llamada.",
        )

    def resume(self) -> str:
        result = self._api_request("PUT", "/me/player/play", timeout=20)
        return result.get(
            "error",
            "Reproduccion reanudada. Accion exitosa; no repitas la llamada.",
        )

    def next_track(self) -> str:
        result = self._api_request("POST", "/me/player/next", timeout=20)
        return result.get(
            "error",
            "Siguiente cancion. Accion exitosa; no repitas la llamada.",
        )

    def previous_track(self) -> str:
        result = self._api_request("POST", "/me/player/previous", timeout=20)
        return result.get(
            "error",
            "Cancion anterior. Accion exitosa; no repitas la llamada.",
        )

    def set_volume(self, volume: int) -> str:
        volume = max(0, min(100, volume))
        result = self._api_request(
            "PUT",
            "/me/player/volume",
            params={"volume_percent": volume},
            timeout=20,
        )
        return result.get(
            "error",
            f"Volumen establecido al {volume}%. Accion exitosa.",
        )

    def current_playing(self) -> str:
        result = self._api_request("GET", "/me/player/currently-playing")
        if "error" in result:
            return result["error"]
        if not result or not result.get("item"):
            return "No se esta reproduciendo nada en este momento."
        item      = result["item"]
        name      = item.get("name", "Desconocido")
        artists = ", ".join(
            artist.get("name", "") for artist in item.get("artists", [])
        )
        album     = item.get("album", {}).get("name", "")
        progress  = result.get("progress_ms", 0)
        duration  = item.get("duration_ms", 0)
        p_min, p_sec = divmod(progress // 1000, 60)
        d_min, d_sec = divmod(duration // 1000, 60)
        state     = "Reproduciendo" if result.get("is_playing", False) else "Pausado"
        return (
            f"{state}: {name} — {artists}\n"
            f"Album: {album}\n"
            f"Progreso: {p_min}:{p_sec:02d} / {d_min}:{d_sec:02d}"
        )

    def add_to_queue(self, uri: str = None, query: str = None) -> str:
        if not uri and query:
            search_result = self._api_request("GET", "/search", params={
                "q": query, "type": "track", "limit": 10, "market": "US"
            })
            if "error" in search_result:
                return search_result["error"]
            tracks = search_result.get("tracks", {}).get("items", [])
            if not tracks:
                return f"No se encontro ninguna cancion para '{query}'"
            tracks.sort(key=lambda x: x.get("popularity", 0), reverse=True)
            uri = tracks[0].get("uri", "")
            track_name = tracks[0].get("name", "Sin nombre")
            artist_name = ", ".join(
                artist.get("name", "")
                for artist in tracks[0].get("artists", [])
            )
            if not uri:
                return "Spotify devolvió una canción sin URI utilizable."

        if not uri:
            return (
                "Se necesita un URI o una consulta de busqueda para "
                "agregar a la cola."
            )

        result = self._api_request(
            "POST",
            "/me/player/queue",
            params={"uri": uri},
            timeout=20,
        )
        if "error" in result:
            return result["error"]
        if query:
            return (
                "Cancion agregada a la cola: "
                f"{track_name} — {artist_name} (uri={uri}). "
                "Accion exitosa; no repitas la llamada."
            )
        return (
            f"Cancion con uri={uri} agregada a la cola. "
            "Accion exitosa; no repitas la llamada."
        )


# ─────────────────────────────────────────────────────────────────────────────
# Singleton + función unificada para la IA
# ─────────────────────────────────────────────────────────────────────────────
spotify_mgr = SpotifyManager()


def tool_spotify_music(action: str, query: str = "", uri: str = "",
                       search_type: str = "track", volume: int = 50) -> str:
    """Herramienta unificada de Spotify para la IA."""
    if not spotify_mgr.is_configured():
        return (
            "Spotify no esta configurado. El usuario debe editar el archivo "
            f"{SPOTIFY_CREDS_FILE} con su client_id "
            "de https://developer.spotify.com/dashboard"
        )

    if not spotify_mgr.is_authenticated():
        started = spotify_mgr.start_authentication()
        if not started:
            return "La autorización de Spotify ya está en curso en el navegador."
        return (
            "Spotify necesita autorizacion. Se abrió el navegador para que "
            "inicies sesion. "
            "Una vez que autorices en el navegador, intenta tu peticion de nuevo."
        )

    action = action.strip().lower()
    if action == "search":
        res = (
            spotify_mgr.search(query, search_type)
            if query
            else "Se necesita un texto de busqueda (parametro 'query')."
        )
    elif action == "play":
        res = spotify_mgr.play(uri=uri or None, query=query or None)
    elif action == "pause":
        res = spotify_mgr.pause()
    elif action == "resume":
        res = spotify_mgr.resume()
    elif action == "next":
        res = spotify_mgr.next_track()
    elif action == "previous":
        res = spotify_mgr.previous_track()
    elif action == "volume":
        res = spotify_mgr.set_volume(volume)
    elif action == "current":
        res = spotify_mgr.current_playing()
    elif action == "queue":
        res = spotify_mgr.add_to_queue(uri=uri or None, query=query or None)
    else:
        res = (
            f"Accion desconocida: '{action}'. Acciones validas: search, play, "
            "pause, resume, next, previous, volume, current, queue."
        )

    return (
        res
        + "\n\nIMPORTANTE: Responde brevemente confirmando lo realizado "
        "o informando del error."
    )
