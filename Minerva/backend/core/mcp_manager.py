#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
MCPManager — Gestión de conexiones de servidores Model Context Protocol (MCP) para Minerva.

Soporta:
  - Transporte HTTP / SSE (Server-Sent Events) y HTTP Streamable/JSON-RPC.
  - Transporte STDIO: subproceso local (npx, uvx, python, etc.) con comunicación JSON-RPC
    por stdin/stdout. Compatible con todos los servidores MCP del ecosistema npm/python.
  - Autenticación: Sin auth, Token Bearer / API Key, y OAuth 2.0 con PKCE.
  - Descubrimiento dinámico de herramientas ('tools/list') y ejecución ('tools/call').
  - Persistencia segura y atómica en ~/.config/minerva/mcp_servers.json.
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import secrets
import select
import stat
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any

import httpx

from .config import MCP_CONFIG_FILE, MINERVA_CONFIG_DIR
from .io import emit

DEFAULT_TIMEOUT = 20.0


def _write_private_json(path: str, data: Any) -> None:
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    try:
        os.chmod(directory, 0o700)
    except OSError:
        pass
    temp_name = ""
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=directory,
            prefix=".minerva-mcp-",
            delete=False,
        ) as temporary:
            json.dump(data, temporary, indent=2, ensure_ascii=False)
            temporary.write("\n")
            temporary.flush()
            temp_name = temporary.name
        os.chmod(temp_name, 0o600)
        os.replace(temp_name, path)
    finally:
        if temp_name and os.path.exists(temp_name):
            try:
                os.unlink(temp_name)
            except OSError:
                pass


def _sanitize_identifier(name: str) -> str:
    """Convierte un nombre a un identificador seguro para funciones de Gemini."""
    clean = re.sub(r"[^a-zA-Z0-9_]", "_", name).strip("_")
    return clean or "tool"


class MCPManager:
    """Gestor central de servidores y herramientas MCP para Minerva."""

    def __init__(self, config_path: str = MCP_CONFIG_FILE):
        self.config_path = config_path
        self._lock = threading.RLock()
        self._servers: list[dict[str, Any]] = []
        self._active_sessions: dict[str, str] = {}  # server_id -> endpoint_url (HTTP)
        self._tool_cache: dict[str, list[dict[str, Any]]] = {}  # server_id -> list of tool dicts
        self._oauth_lock = threading.Lock()
        self._oauth_in_progress = False
        # ── Estado de procesos STDIO ──────────────────────────────────────────
        self._stdio_procs: dict[str, subprocess.Popen] = {}   # server_id -> proceso vivo
        self._stdio_locks: dict[str, threading.Lock] = {}     # server_id -> lock de I/O
        self._stdio_req_id: int = 0
        self._load_servers()

    # ── Persistencia ──────────────────────────────────────────────────────────

    def _load_servers(self) -> None:
        with self._lock:
            if not os.path.exists(self.config_path):
                self._servers = []
                return
            try:
                with open(self.config_path, "r", encoding="utf-8") as f:
                    data = json.load(f)
                if isinstance(data, list):
                    self._servers = data
                elif isinstance(data, dict) and "servers" in data:
                    self._servers = data["servers"]
                else:
                    self._servers = []
            except Exception as exc:
                print(f"[MCP] Error leyendo {self.config_path}: {exc}", file=sys.stderr)
                self._servers = []

            # Poblar caché de herramientas a partir de lo guardado
            for s in self._servers:
                s_id = s.get("id")
                if s_id and "tools" in s and isinstance(s["tools"], list):
                    self._tool_cache[s_id] = s["tools"]

    def _save_servers(self) -> None:
        with self._lock:
            try:
                _write_private_json(self.config_path, self._servers)
            except Exception as exc:
                print(f"[MCP] Error guardando servidores: {exc}", file=sys.stderr)

    # ── Consultas y operaciones de servidores ─────────────────────────────────

    def get_servers(self) -> list[dict[str, Any]]:
        with self._lock:
            # Retornar copias limpias de los servidores
            result = []
            for s in self._servers:
                item = dict(s)
                # Ocultar secretos sensibles en resúmenes si es necesario
                result.append(item)
            return result

    def get_server(self, server_id: str) -> dict[str, Any] | None:
        with self._lock:
            for s in self._servers:
                if s.get("id") == server_id:
                    return s
            return None

    def add_or_update_server(
        self,
        server_data: dict[str, Any],
        auto_test: bool = True,
    ) -> dict[str, Any]:
        """Añade un nuevo servidor o actualiza uno existente."""
        with self._lock:
            server_id = server_data.get("id")
            if not server_id:
                server_id = "srv_" + secrets.token_hex(4)
                server_data["id"] = server_id

            # Defaults
            server_data.setdefault("name", "Servidor MCP")
            server_data.setdefault("url", "")
            server_data.setdefault("enabled", True)
            server_data.setdefault("auth_type", "none")  # none, bearer, oauth2
            server_data.setdefault("bearer_token", "")
            server_data.setdefault("oauth2", {})
            server_data.setdefault("headers", {})
            server_data.setdefault("status", "disconnected")
            server_data.setdefault("error_message", "")
            server_data.setdefault("tools", [])

            existing_idx = None
            for idx, s in enumerate(self._servers):
                if s.get("id") == server_id:
                    existing_idx = idx
                    break

            if existing_idx is not None:
                # Conservar tokens OAuth existentes si no se especificaron nuevos
                old_oauth = self._servers[existing_idx].get("oauth2", {})
                new_oauth = server_data.get("oauth2", {})
                if old_oauth and isinstance(new_oauth, dict):
                    if not new_oauth.get("access_token") and old_oauth.get("access_token"):
                        new_oauth["access_token"] = old_oauth["access_token"]
                    if not new_oauth.get("refresh_token") and old_oauth.get("refresh_token"):
                        new_oauth["refresh_token"] = old_oauth["refresh_token"]
                    if not new_oauth.get("expires_at") and old_oauth.get("expires_at"):
                        new_oauth["expires_at"] = old_oauth["expires_at"]
                    server_data["oauth2"] = new_oauth
                self._servers[existing_idx] = server_data
            else:
                self._servers.append(server_data)

            self._save_servers()

        # Probar conexión en segundo plano si está habilitado
        if auto_test and server_data.get("enabled", True) and server_data.get("url"):
            threading.Thread(
                target=self.test_and_refresh_server,
                args=(server_id,),
                daemon=True,
                name=f"mcp-test-{server_id}",
            ).start()

        return server_data

    def delete_server(self, server_id: str) -> bool:
        self._stop_stdio_proc(server_id)  # Matar proceso STDIO si existe
        with self._lock:
            orig_len = len(self._servers)
            self._servers = [s for s in self._servers if s.get("id") != server_id]
            self._tool_cache.pop(server_id, None)
            self._active_sessions.pop(server_id, None)
            if len(self._servers) != orig_len:
                self._save_servers()
                return True
            return False

    def toggle_server(self, server_id: str, enabled: bool) -> dict[str, Any] | None:
        with self._lock:
            server = self.get_server(server_id)
            if not server:
                return None
            server["enabled"] = bool(enabled)
            if not enabled:
                server["status"] = "disconnected"
                self._active_sessions.pop(server_id, None)
                self._stop_stdio_proc(server_id)
            self._save_servers()

        if enabled and (server.get("url") or server.get("command")):
            threading.Thread(
                target=self.test_and_refresh_server,
                args=(server_id,),
                daemon=True,
                name=f"mcp-toggle-{server_id}",
            ).start()

        return server

    # ── Autenticación OAuth 2.0 y Headers ─────────────────────────────────────

    def _refresh_oauth_token_if_needed(self, server: dict[str, Any]) -> bool:
        """Renueva el access token si está expirado y hay un refresh token disponible."""
        oauth_data = server.get("oauth2", {})
        if not isinstance(oauth_data, dict):
            return False

        refresh_token = oauth_data.get("refresh_token")
        token_url = oauth_data.get("token_url")
        client_id = oauth_data.get("client_id")
        client_secret = oauth_data.get("client_secret", "")
        expires_at = oauth_data.get("expires_at", 0)

        # Si aún es válido con margen de 60 segundos, no hace falta renovar
        if expires_at and time.time() < (expires_at - 60):
            return True

        if not refresh_token or not token_url or not client_id:
            return bool(oauth_data.get("access_token"))

        try:
            payload = {
                "grant_type": "refresh_token",
                "refresh_token": refresh_token,
                "client_id": client_id,
            }
            if client_secret:
                payload["client_secret"] = client_secret

            with httpx.Client(timeout=15.0) as client:
                res = client.post(
                    token_url,
                    data=payload,
                    headers={"Accept": "application/json"},
                )
            if res.status_code == 200:
                data = res.json()
                new_access = data.get("access_token")
                if new_access:
                    oauth_data["access_token"] = new_access
                    expires_in = data.get("expires_in", 3600)
                    oauth_data["expires_at"] = time.time() + float(expires_in)
                    if data.get("refresh_token"):
                        oauth_data["refresh_token"] = data["refresh_token"]
                    server["oauth2"] = oauth_data
                    self._save_servers()
                    print(f"[MCP] Token OAuth renovado con éxito para servidor {server.get('name')}")
                    return True
            else:
                print(f"[MCP] Error al renovar token OAuth: {res.status_code} {res.text}", file=sys.stderr)
        except Exception as exc:
            print(f"[MCP] Excepción al renovar token OAuth: {exc}", file=sys.stderr)
        return False

    def _build_request_headers(self, server: dict[str, Any]) -> dict[str, str]:
        headers = {
            "User-Agent": "Minerva-MCP-Client/1.0",
            "Accept": "application/json, text/event-stream",
            "Content-Type": "application/json",
        }
        auth_type = server.get("auth_type", "none")
        if auth_type == "bearer":
            token = server.get("bearer_token", "").strip()
            if token:
                headers["Authorization"] = f"Bearer {token}"
        elif auth_type == "oauth2":
            self._refresh_oauth_token_if_needed(server)
            token = server.get("oauth2", {}).get("access_token", "").strip()
            if token:
                headers["Authorization"] = f"Bearer {token}"

        # Headers personalizados definidos por el usuario
        custom_headers = server.get("headers", {})
        if isinstance(custom_headers, dict):
            for k, v in custom_headers.items():
                if isinstance(k, str) and isinstance(v, str):
                    headers[k] = v

        return headers

    def start_oauth_flow(self, server_id: str) -> None:
        """Inicia el flujo interactivo de OAuth 2.0 PKCE en el navegador."""
        with self._oauth_lock:
            if self._oauth_in_progress:
                emit({"type": "mcp_oauth_error", "server_id": server_id, "error": "Ya hay una autenticación en curso."})
                return
            self._oauth_in_progress = True

        threading.Thread(
            target=self._run_oauth_flow,
            args=(server_id,),
            daemon=True,
            name=f"mcp-oauth-{server_id}",
        ).start()

    def _run_oauth_flow(self, server_id: str) -> None:
        server = self.get_server(server_id)
        if not server:
            with self._oauth_lock:
                self._oauth_in_progress = False
            emit({"type": "mcp_oauth_error", "server_id": server_id, "error": "Servidor no encontrado."})
            return

        oauth_cfg = server.get("oauth2", {})
        auth_url_base = oauth_cfg.get("auth_url", "").strip()
        token_url = oauth_cfg.get("token_url", "").strip()
        client_id = oauth_cfg.get("client_id", "").strip()
        client_secret = oauth_cfg.get("client_secret", "").strip()
        scopes = oauth_cfg.get("scopes", "").strip()

        if not auth_url_base or not token_url or not client_id:
            with self._oauth_lock:
                self._oauth_in_progress = False
            emit({
                "type": "mcp_oauth_error",
                "server_id": server_id,
                "error": "Faltan Auth URL, Token URL o Client ID en la configuración OAuth.",
            })
            return

        # Generar PKCE verifier y challenge
        code_verifier = secrets.token_urlsafe(64)
        hashed = hashlib.sha256(code_verifier.encode("ascii")).digest()
        code_challenge = base64.urlsafe_b64encode(hashed).decode("ascii").rstrip("=")
        state = secrets.token_urlsafe(24)

        port = 8889
        redirect_uri = f"http://127.0.0.1:{port}/callback"

        auth_params = {
            "response_type": "code",
            "client_id": client_id,
            "redirect_uri": redirect_uri,
            "scope": scopes,
            "state": state,
            "code_challenge": code_challenge,
            "code_challenge_method": "S256",
        }
        # Para Google OAuth, solicitar offline access para refresh token
        if "google" in auth_url_base.lower() or "accounts.google.com" in auth_url_base:
            auth_params["access_type"] = "offline"
            auth_params["prompt"] = "consent"

        auth_full_url = f"{auth_url_base}?{urllib.parse.urlencode(auth_params)}"

        received_code: list[str] = []
        received_state: list[str] = []
        server_error: list[str] = []
        flow_done = threading.Event()

        class OAuthCallbackHandler(BaseHTTPRequestHandler):
            def do_GET(self):
                parsed = urllib.parse.urlparse(self.path)
                if parsed.path == "/callback":
                    params = urllib.parse.parse_qs(parsed.query)
                    code = params.get("code", [None])[0]
                    st = params.get("state", [None])[0]
                    err = params.get("error", [None])[0]
                    if err:
                        server_error.append(err)
                    elif code:
                        received_code.append(code)
                        if st:
                            received_state.append(st)

                    self.send_response(200)
                    self.send_header("Content-Type", "text/html; charset=utf-8")
                    self.end_headers()
                    html = """<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>Minerva MCP — Conectado</title>
<style>
body { background: #0c0c12; color: #f5f2f4; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; }
.card { background: #14141e; border: 1px solid rgba(120, 209, 211, 0.3); border-radius: 20px; padding: 40px; text-align: center; max-width: 420px; box-shadow: 0 12px 30px rgba(0,0,0,0.5); }
h1 { color: #78d1d3; font-size: 22px; margin-bottom: 12px; }
p { color: #9b969c; font-size: 14px; line-height: 1.5; }
</style>
</head>
<body>
<div class="card">
  <h1>✓ Autenticación exitosa</h1>
  <p>Minerva se ha conectado correctamente a tu cuenta.<br>Puedes cerrar esta pestaña y volver al escritorio.</p>
</div>
</body>
</html>"""
                    self.wfile.write(html.encode("utf-8"))
                    flow_done.set()
                else:
                    self.send_response(404)
                    self.end_headers()

            def log_message(self, format, *args):
                pass  # Silenciar logs http en consola

        httpd = None
        try:
            httpd = HTTPServer(("127.0.0.1", port), OAuthCallbackHandler)
            httpd.timeout = 1.0
        except Exception as exc:
            with self._oauth_lock:
                self._oauth_in_progress = False
            emit({
                "type": "mcp_oauth_error",
                "server_id": server_id,
                "error": f"No se pudo abrir el puerto local {port}: {exc}",
            })
            return

        emit({
            "type": "mcp_oauth_started",
            "server_id": server_id,
            "auth_url": auth_full_url,
        })

        # Abrir navegador
        try:
            subprocess.Popen(
                ["xdg-open", auth_full_url],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except Exception:
            pass

        start_time = time.time()
        timeout_sec = 120.0
        while not flow_done.is_set() and (time.time() - start_time < timeout_sec):
            httpd.handle_request()

        httpd.server_close()

        with self._oauth_lock:
            self._oauth_in_progress = False

        if not received_code:
            err_msg = server_error[0] if server_error else "Tiempo de espera agotado sin autorización."
            emit({"type": "mcp_oauth_error", "server_id": server_id, "error": err_msg})
            return

        if received_state and received_state[0] != state:
            emit({"type": "mcp_oauth_error", "server_id": server_id, "error": "Parámetro 'state' inválido."})
            return

        # Canjear código por tokens
        try:
            token_payload = {
                "grant_type": "authorization_code",
                "code": received_code[0],
                "redirect_uri": redirect_uri,
                "client_id": client_id,
                "code_verifier": code_verifier,
            }
            if client_secret:
                token_payload["client_secret"] = client_secret

            with httpx.Client(timeout=15.0) as client:
                resp = client.post(
                    token_url,
                    data=token_payload,
                    headers={"Accept": "application/json"},
                )
            if resp.status_code == 200:
                data = resp.json()
                access_token = data.get("access_token")
                refresh_token = data.get("refresh_token")
                expires_in = data.get("expires_in", 3600)
                if not access_token:
                    emit({"type": "mcp_oauth_error", "server_id": server_id, "error": "No se recibió access_token."})
                    return

                with self._lock:
                    s = self.get_server(server_id)
                    if s:
                        o = s.setdefault("oauth2", {})
                        o["access_token"] = access_token
                        if refresh_token:
                            o["refresh_token"] = refresh_token
                        o["expires_at"] = time.time() + float(expires_in)
                        s["auth_type"] = "oauth2"
                        self._save_servers()

                emit({"type": "mcp_oauth_success", "server_id": server_id})
                # Probar y actualizar lista de herramientas
                self.test_and_refresh_server(server_id)
            else:
                emit({
                    "type": "mcp_oauth_error",
                    "server_id": server_id,
                    "error": f"Error del servidor de tokens: {resp.status_code} {resp.text[:200]}",
                })
        except Exception as exc:
            emit({"type": "mcp_oauth_error", "server_id": server_id, "error": f"Error canjeando token: {exc}"})

    # ── Transporte STDIO ───────────────────────────────────────────────────────

    def _stdio_next_id(self) -> int:
        self._stdio_req_id += 1
        return self._stdio_req_id

    def _get_stdio_lock(self, server_id: str) -> threading.Lock:
        if server_id not in self._stdio_locks:
            self._stdio_locks[server_id] = threading.Lock()
        return self._stdio_locks[server_id]

    def _stop_stdio_proc(self, server_id: str) -> None:
        """Termina el proceso STDIO de un servidor si está activo."""
        proc = self._stdio_procs.pop(server_id, None)
        if proc and proc.poll() is None:
            try:
                proc.stdin.close()
            except Exception:
                pass
            try:
                proc.terminate()
                proc.wait(timeout=3)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass

    def _build_stdio_env(self, server: dict[str, Any]) -> dict[str, str]:
        """Construye el entorno para el proceso STDIO, mergeando env_vars o env del servidor."""
        env = os.environ.copy()
        extra_env = server.get("env_vars") or server.get("env") or {}
        if isinstance(extra_env, dict):
            for k, v in extra_env.items():
                if isinstance(k, str):
                    env[k] = str(v)
        return env

    def _ensure_stdio_proc(self, server: dict[str, Any]) -> subprocess.Popen:
        """
        Asegura que el proceso STDIO del servidor esté activo.
        Si no existe o ha muerto, lo inicia de nuevo.
        """
        server_id = server["id"]
        proc = self._stdio_procs.get(server_id)
        if proc is not None and proc.poll() is None:
            return proc  # Ya está corriendo

        command = server.get("command", "").strip()
        if not command:
            raise RuntimeError("El servidor STDIO no tiene ningún comando configurado.")

        env = self._build_stdio_env(server)
        # Usar shell=True para soportar comandos compuestos (npx, uvx, python -m, etc.)
        proc = subprocess.Popen(
            command,
            shell=True,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            text=True,
            encoding="utf-8",
            bufsize=1,  # Line-buffered
        )
        self._stdio_procs[server_id] = proc
        print(f"[MCP STDIO] Proceso iniciado para '{server.get('name')}': {command} (PID={proc.pid})")
        # Dar tiempo al proceso para arrancar
        time.sleep(0.8)
        if proc.poll() is not None:
            stderr_out = ""
            try:
                stderr_out = proc.stderr.read(512)
            except Exception:
                pass
            raise RuntimeError(
                f"El proceso STDIO terminó inmediatamente (código {proc.returncode}). "
                f"Revisa el comando.\nStderr: {stderr_out[:300]}"
            )
        return proc

    def _send_stdio_jsonrpc(
        self,
        server: dict[str, Any],
        method: str,
        params: dict[str, Any] | None = None,
        req_id: int | str | None = None,
        timeout: float = 30.0,
    ) -> dict[str, Any]:
        """
        Envía una llamada JSON-RPC por stdin al proceso MCP y lee la respuesta de stdout.
        Cada línea de stdout es un objeto JSON-RPC independiente (ndjson / newline-delimited).
        """
        server_id = server["id"]
        lock = self._get_stdio_lock(server_id)

        is_notification = req_id is None
        if req_id is None and not is_notification:
            req_id = self._stdio_next_id()

        payload: dict[str, Any] = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            payload["params"] = params
        if not is_notification:
            if req_id is None:
                req_id = self._stdio_next_id()
            payload["id"] = req_id

        line = json.dumps(payload, ensure_ascii=False) + "\n"

        with lock:
            proc = self._ensure_stdio_proc(server)
            try:
                proc.stdin.write(line)
                proc.stdin.flush()
            except BrokenPipeError as exc:
                # Proceso muerto, limpiar y relanzar
                self._stop_stdio_proc(server_id)
                raise RuntimeError(f"Proceso STDIO terminó inesperadamente: {exc}") from exc

            if is_notification:
                return {"result": "Notification sent"}

            # Leer respuesta por stdout (ndjson)
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if proc.poll() is not None:
                    raise RuntimeError(f"Proceso STDIO terminó (código {proc.returncode}).")
                try:
                    proc.stdout._CHUNK_SIZE = 1  # type: ignore[attr-defined]
                except Exception:
                    pass
                ready, _, _ = select.select([proc.stdout], [], [], 0.5)
                if not ready:
                    continue
                raw = proc.stdout.readline()
                if not raw:
                    continue
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                # Ignorar notificaciones del servidor; esperar la respuesta con nuestro id
                if isinstance(msg, dict) and msg.get("id") == req_id:
                    return msg
                # También aceptar si no tiene id (algunos servidores omiten id en error)
                if isinstance(msg, dict) and "error" in msg and "id" not in msg:
                    return msg

            raise TimeoutError(f"Tiempo de espera agotado esperando respuesta STDIO para '{method}'.")

    def _stdio_handshake_and_list(
        self, server: dict[str, Any]
    ) -> list[dict[str, Any]]:
        """Realiza el handshake MCP completo por STDIO y retorna la lista de tools."""
        # 1. Initialize
        rid = self._stdio_next_id()
        init_resp = self._send_stdio_jsonrpc(
            server,
            method="initialize",
            params={
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "Minerva", "version": "1.0"},
            },
            req_id=rid,
        )
        if "error" in init_resp:
            msg = init_resp["error"].get("message", str(init_resp["error"])) if isinstance(init_resp["error"], dict) else str(init_resp["error"])
            raise RuntimeError(f"Error de handshake STDIO: {msg}")

        # 2. Notification initialized (sin id = notificación)
        notif: dict[str, Any] = {"jsonrpc": "2.0", "method": "notifications/initialized"}
        server_id = server["id"]
        lock = self._get_stdio_lock(server_id)
        with lock:
            proc = self._stdio_procs.get(server_id)
            if proc and proc.poll() is None:
                try:
                    proc.stdin.write(json.dumps(notif) + "\n")
                    proc.stdin.flush()
                except Exception:
                    pass

        # 3. tools/list
        rid2 = self._stdio_next_id()
        tools_resp = self._send_stdio_jsonrpc(
            server,
            method="tools/list",
            params={},
            req_id=rid2,
        )
        if "error" in tools_resp:
            msg = tools_resp["error"].get("message", str(tools_resp["error"])) if isinstance(tools_resp["error"], dict) else str(tools_resp["error"])
            raise RuntimeError(f"Error obteniendo tools vía STDIO: {msg}")

        result_obj = tools_resp.get("result", {})
        if isinstance(result_obj, dict):
            return result_obj.get("tools", [])
        if isinstance(result_obj, list):
            return result_obj
        return []

    # ── Protocolo MCP (SSE / HTTP JSON-RPC) ───────────────────────────────────

    @staticmethod
    def _parse_sse_body(text: str) -> dict[str, Any] | None:
        """
        Parsea un cuerpo de respuesta SSE (text/event-stream) y retorna el primer
        objeto JSON-RPC encontrado en las líneas 'data:'. Usado por el transporte
        HTTP Streamable (ej: GitHub MCP, etc.).
        """
        result = None
        for raw_line in text.splitlines():
            line = raw_line.strip()
            if not line.startswith("data:"):
                continue
            data_str = line[5:].strip()
            if not data_str or data_str == "[DONE]":
                continue
            try:
                obj = json.loads(data_str)
                if not isinstance(obj, dict):
                    continue
                # Preferir mensajes JSON-RPC con 'id' (respuestas) sobre notificaciones
                if "id" in obj:
                    return obj
                if result is None:
                    result = obj
            except json.JSONDecodeError:
                pass
        return result

    def _resolve_mcp_endpoint(
        self,
        server: dict[str, Any],
        client: httpx.Client,
        timeout: float = DEFAULT_TIMEOUT,
    ) -> str:
        """Determina el endpoint POST para enviar mensajes JSON-RPC (vía SSE o directo)."""
        server_id = server["id"]
        cached_endpoint = self._active_sessions.get(server_id)
        if cached_endpoint:
            return cached_endpoint

        url = server["url"].strip()
        headers = self._build_request_headers(server)

        # Probar si la URL acepta GET con SSE (protocolo SSE clásico MCP)
        # Algunos servidores (ej: GitHub) devuelven 405 en GET → usar URL directa para POST
        try:
            with client.stream("GET", url, headers=headers, timeout=min(timeout, 8.0)) as stream_resp:
                if stream_resp.status_code == 405:
                    # Servidor no acepta GET → Streamable HTTP directo
                    self._active_sessions[server_id] = url
                    return url
                content_type = stream_resp.headers.get("Content-Type", "")
                if "text/event-stream" in content_type:
                    current_event = ""
                    for raw_line in stream_resp.iter_lines():
                        line = raw_line.strip()
                        if not line:
                            current_event = ""
                            continue
                        if line.startswith("event:"):
                            current_event = line[6:].strip()
                        elif line.startswith("data:"):
                            data_val = line[5:].strip()
                            if current_event == "endpoint" or "/messages" in data_val:
                                endpoint = urllib.parse.urljoin(url, data_val)
                                self._active_sessions[server_id] = endpoint
                                return endpoint
        except Exception:
            pass

        # Fallback: usar la URL directa para JSON-RPC POST (Streamable HTTP)
        self._active_sessions[server_id] = url
        return url

    def _send_jsonrpc(
        self,
        endpoint_url: str,
        method: str,
        params: dict[str, Any] | None = None,
        req_id: int | str = 1,
        headers: dict[str, str] | None = None,
        client: httpx.Client | None = None,
        timeout: float = DEFAULT_TIMEOUT,
    ) -> dict[str, Any]:
        """Envía una llamada JSON-RPC 2.0 y retorna la respuesta procesada.

        Soporta dos transportes:
        - JSON directo: el servidor responde con Content-Type: application/json
        - Streamable HTTP (SSE): el servidor responde con Content-Type: text/event-stream
          y encapsula la respuesta JSON-RPC en líneas 'data:' del stream SSE.
        """
        payload = {
            "jsonrpc": "2.0",
            "id": req_id,
            "method": method,
            "params": params if params is not None else {},
        }
        close_client = False
        if client is None:
            client = httpx.Client(timeout=timeout)
            close_client = True

        try:
            res = client.post(endpoint_url, json=payload, headers=headers)
            if res.status_code in (200, 201):
                content_type = res.headers.get("Content-Type", "")
                # Transporte Streamable HTTP: respuesta SSE encapsulada
                if "text/event-stream" in content_type:
                    parsed = self._parse_sse_body(res.text)
                    if parsed is not None:
                        return parsed
                    # Si no se pudo parsear, devolver texto crudo
                    return {"result": res.text}
                # Transporte JSON directo
                try:
                    return res.json()
                except json.JSONDecodeError:
                    return {"result": res.text}
            elif res.status_code == 202:
                # 202 Accepted: El servidor procesará la notificación asíncronamente
                return {"result": "Accepted"}
            else:
                return {
                    "error": {
                        "code": res.status_code,
                        "message": f"HTTP {res.status_code}: {res.text[:300]}",
                    }
                }
        finally:
            if close_client:
                client.close()

    def test_and_refresh_server(self, server_id: str) -> dict[str, Any]:
        """Conecta al servidor, ejecuta el handshake de inicialización y obtiene la lista de tools.

        Dispatcher: detecta el transporte (STDIO vs HTTP) según el campo 'transport' del servidor.
        """
        with self._lock:
            server = self.get_server(server_id)
            if not server:
                return {}

        transport = server.get("transport", "http")  # "http" | "stdio"

        try:
            if transport == "stdio":
                tools_list = self._stdio_handshake_and_list(server)
            else:
                tools_list = self._http_handshake_and_list(server)

            # Normalizar herramientas
            normalized_tools = []
            for t in tools_list:
                if not isinstance(t, dict):
                    continue
                t_name = str(t.get("name", "")).strip()
                if not t_name:
                    continue
                normalized_tools.append({
                    "name": t_name,
                    "description": str(t.get("description", "")),
                    "inputSchema": t.get("inputSchema", {"type": "object", "properties": {}}),
                })

            with self._lock:
                server["status"] = "connected"
                server["error_message"] = ""
                server["tools"] = normalized_tools
                server["tool_count"] = len(normalized_tools)
                self._tool_cache[server_id] = normalized_tools
                self._save_servers()

            emit({"type": "mcp_servers_updated", "servers": self.get_servers()})
            return server

        except Exception as exc:
            error_str = str(exc)
            with self._lock:
                server["status"] = "error"
                server["error_message"] = error_str
                self._save_servers()
            emit({"type": "mcp_servers_updated", "servers": self.get_servers()})
            return server

    def _http_handshake_and_list(self, server: dict[str, Any]) -> list[dict[str, Any]]:
        """Realiza el handshake MCP por HTTP/SSE y retorna la lista de tools."""
        headers = self._build_request_headers(server)
        timeout = 15.0
        with httpx.Client(timeout=timeout) as client:
            endpoint = self._resolve_mcp_endpoint(server, client, timeout=timeout)

            init_resp = self._send_jsonrpc(
                endpoint, method="initialize",
                params={"protocolVersion": "2024-11-05", "capabilities": {},
                        "clientInfo": {"name": "Minerva", "version": "1.0"}},
                req_id=1, headers=headers, client=client, timeout=timeout,
            )
            if "error" in init_resp:
                raise RuntimeError(init_resp["error"].get("message", "Error de handshake MCP"))

            try:
                client.post(endpoint,
                            json={"jsonrpc": "2.0", "method": "notifications/initialized"},
                            headers=headers)
            except Exception:
                pass

            tools_resp = self._send_jsonrpc(
                endpoint, method="tools/list", params={}, req_id=2,
                headers=headers, client=client, timeout=timeout,
            )
            if "error" in tools_resp:
                raise RuntimeError(tools_resp["error"].get("message", "Error obteniendo herramientas"))

            result_obj = tools_resp.get("result", {})
            if isinstance(result_obj, dict) and "tools" in result_obj:
                return result_obj["tools"]
            if isinstance(result_obj, list):
                return result_obj
            return []

    def call_tool(self, namespaced_tool_name: str, args: dict[str, Any]) -> str:
        """
        Ejecuta una herramienta en el servidor MCP correspondiente.
        Formato de tool: mcp__{server_id}__{tool_name}
        Dispatcher: detecta transporte STDIO vs HTTP automáticamente.
        """
        parts = namespaced_tool_name.split("__")
        if len(parts) < 3 or parts[0] != "mcp":
            return f"Error: Nombre de herramienta MCP inválido '{namespaced_tool_name}'"

        server_id = parts[1]
        received_tool_name = "__".join(parts[2:])

        server = self.get_server(server_id)
        if not server:
            return f"Error: Servidor MCP '{server_id}' no encontrado."
        if not server.get("enabled", True):
            return f"Error: El servidor MCP '{server.get('name')}' está desactivado."

        # Resolver el nombre real de la herramienta en el servidor (deshacer sanitización si aplica)
        orig_tool_name = received_tool_name
        cached_tools = self._tool_cache.get(server_id, server.get("tools", []))
        for t in cached_tools:
            real_name = t.get("name", "")
            if real_name == received_tool_name or _sanitize_identifier(real_name) == received_tool_name:
                orig_tool_name = real_name
                break

        transport = server.get("transport", "http")

        if transport == "stdio":
            return self._call_tool_stdio(server, orig_tool_name, args)
        else:
            return self._call_tool_http(server, orig_tool_name, args)

    def _call_tool_stdio(self, server: dict[str, Any], tool_name: str, args: dict[str, Any]) -> str:
        """Llama a una herramienta por STDIO JSON-RPC."""
        for attempt in range(2):
            try:
                rid = self._stdio_next_id()
                resp = self._send_stdio_jsonrpc(
                    server,
                    method="tools/call",
                    params={"name": tool_name, "arguments": args if isinstance(args, dict) else {}},
                    req_id=rid,
                    timeout=60.0,
                )
                return self._extract_tool_result(resp, server.get("name", ""), tool_name)
            except Exception as exc:
                if attempt == 0:
                    # Matar proceso y relanzar en el siguiente intento
                    self._stop_stdio_proc(server["id"])
                    time.sleep(0.5)
                    continue
                return f"[Error STDIO '{server.get('name')}']: {type(exc).__name__} - {exc}"
        return "Error inesperado ejecutando herramienta STDIO."

    def _call_tool_http(self, server: dict[str, Any], tool_name: str, args: dict[str, Any]) -> str:
        """Llama a una herramienta por HTTP JSON-RPC."""
        server_id = server["id"]
        headers = self._build_request_headers(server)
        for attempt in range(2):
            try:
                with httpx.Client(timeout=35.0) as client:
                    endpoint = self._resolve_mcp_endpoint(server, client)
                    resp = self._send_jsonrpc(
                        endpoint,
                        method="tools/call",
                        params={"name": tool_name, "arguments": args if isinstance(args, dict) else {}},
                        req_id=secrets.randbelow(100000) + 1,
                        headers=headers,
                        client=client,
                        timeout=35.0,
                    )
                return self._extract_tool_result(resp, server.get("name", ""), tool_name)
            except Exception as exc:
                if attempt == 0:
                    self._active_sessions.pop(server_id, None)
                    time.sleep(0.5)
                    continue
                return f"[Error HTTP '{server.get('name')}']: {type(exc).__name__} - {exc}"
        return "Error inesperado ejecutando herramienta HTTP."

    @staticmethod
    def _extract_tool_result(resp: dict[str, Any], server_name: str, tool_name: str) -> str:
        """Extrae texto del resultado JSON-RPC de tools/call (formato MCP estándar)."""
        if "error" in resp:
            err = resp["error"]
            err_msg = err.get("message", str(err)) if isinstance(err, dict) else str(err)
            return f"[Error MCP {server_name}]: {err_msg}"

        result = resp.get("result", {})
        if isinstance(result, dict):
            content = result.get("content", [])
            is_error = result.get("isError", False)
            text_parts = []
            if isinstance(content, list):
                for item in content:
                    if isinstance(item, dict) and item.get("type") == "text":
                        text_parts.append(item.get("text", ""))
                    elif isinstance(item, str):
                        text_parts.append(item)
            elif isinstance(content, str):
                text_parts.append(content)
            else:
                text_parts.append(json.dumps(result, ensure_ascii=False))

            full_text = "\n".join(text_parts).strip()
            if is_error:
                return f"[Error en {tool_name}]: {full_text}"
            return full_text or "Operación completada sin contenido de texto."

        return str(result)

    # ── Exportar herramientas para Gemini ─────────────────────────────────────

    def get_tool_definitions(self) -> list[dict[str, Any]]:
        """Devuelve las definiciones de tools para Gemini de todos los servidores MCP activos."""
        definitions = []
        with self._lock:
            for server in self._servers:
                if not server.get("enabled", True):
                    continue
                server_id = server.get("id", "")
                server_name = server.get("name", "MCP")
                tools = self._tool_cache.get(server_id, server.get("tools", []))

                for t in tools:
                    t_name = t.get("name", "")
                    if not t_name:
                        continue
                    namespaced_name = f"mcp__{server_id}__{_sanitize_identifier(t_name)}"
                    raw_desc = t.get("description", "")
                    clean_desc = f"[Servidor MCP: {server_name}] {raw_desc}".strip()
                    schema = t.get("inputSchema", {})
                    if not isinstance(schema, dict) or schema.get("type") != "object":
                        schema = {"type": "object", "properties": {}}

                    definitions.append({
                        "type": "function",
                        "function": {
                            "name": namespaced_name,
                            "description": clean_desc,
                            "parameters": schema,
                        },
                    })
        return definitions

    def is_mcp_tool(self, tool_name: str) -> bool:
        """Determina si un nombre de tool pertenece a un servidor MCP."""
        return tool_name.startswith("mcp__")


# Singleton global
mcp_mgr = MCPManager()
