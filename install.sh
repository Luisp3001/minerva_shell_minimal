#!/usr/bin/env bash
# ==============================================================================
# Minerva Shell - Script de Instalación y Configuración
# ==============================================================================
set -euo pipefail
umask 077

# Colores y formato
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_YELLOW="\033[1;33m"
CLR_BLUE="\033[1;34m"
CLR_CYAN="\033[1;36m"
CLR_RED="\033[1;31m"
CLR_DIM="\033[2m"

info()    { echo -e "${CLR_CYAN}[INFO]${CLR_RESET} $*"; }
success() { echo -e "${CLR_GREEN}[OK]${CLR_RESET} $*"; }
warn()    { echo -e "${CLR_YELLOW}[AVISO]${CLR_RESET} $*"; }
error()   { echo -e "${CLR_RED}[ERROR]${CLR_RESET} $*" >&2; }

echo -e "${CLR_BOLD}${CLR_BLUE}======================================================"
echo -e "         Instalador de Minerva Shell                "
echo -e "======================================================${CLR_RESET}\n"

# Rutas del proyecto
MINERVA_SHELL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MINERVA_DIR="${MINERVA_SHELL_ROOT}/Minerva"
CONFIG_DIR="${HOME}/.config/minerva"
SETTINGS_FILE="${CONFIG_DIR}/settings.json"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"

cd "${MINERVA_SHELL_ROOT}"

# ── 1. Verificación de Python ──────────────────────────────────────────────────
info "Verificando versión de Python..."
if ! command -v python3 &>/dev/null; then
    error "python3 no está instalado. Por favor instala Python 3.12, 3.13 o 3.14."
    exit 1
fi

PYTHON_BIN="$(command -v python3)"
PYTHON_VERSION="$(${PYTHON_BIN} -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"

case "${PYTHON_VERSION}" in
    3.12|3.13|3.14)
        success "Python detectado: v${PYTHON_VERSION}"
        ;;
    *)
        error "Minerva requiere Python 3.12, 3.13 o 3.14; se encontró ${PYTHON_VERSION}."
        exit 1
        ;;
esac

# ── 2. Verificación de herramientas del sistema ────────────────────────────────
info "Comprobando herramientas del sistema..."

check_tool() {
    local cmd="$1"
    local desc="$2"
    local required="$3"
    if command -v "$cmd" &>/dev/null; then
        echo -e "  ${CLR_GREEN}✔${CLR_RESET} ${CLR_BOLD}${cmd}${CLR_RESET} - ${desc}"
        return 0
    else
        if [ "$required" = "true" ]; then
            echo -e "  ${CLR_RED}✘${CLR_RESET} ${CLR_BOLD}${cmd}${CLR_RESET} - ${desc} ${CLR_RED}(Requerido)${CLR_RESET}"
            return 1
        else
            echo -e "  ${CLR_YELLOW}!${CLR_RESET} ${CLR_BOLD}${cmd}${CLR_RESET} - ${desc} ${CLR_DIM}(Opcional / Recomendado)${CLR_RESET}"
            return 0
        fi
    fi
}

REQ_ERRORS=0
check_tool "quickshell"    "Runtime del shell para Wayland"          "true" || REQ_ERRORS=$((REQ_ERRORS + 1))
check_tool "curl"          "Descarga de modelos y dependencias"      "true" || REQ_ERRORS=$((REQ_ERRORS + 1))
check_tool "unzip"         "Extracción de modelos de voz"            "true" || REQ_ERRORS=$((REQ_ERRORS + 1))
check_tool "wl-copy"       "Copiar al portapapeles (wl-clipboard)"   "false"
check_tool "pactl"         "Control de audio / volumen (Pulse/Pipe)" "false"
check_tool "brightnessctl" "Control de brillo de pantalla"           "false"
check_tool "nmcli"         "Gestión de redes Wi-Fi (NetworkManager)" "false"
check_tool "bluetoothctl"  "Gestión de dispositivos Bluetooth"       "false"
check_tool "inotifywait"   "Detección de nuevos fondos de pantalla"  "false"
check_tool "magick"        "Generación de miniaturas (ImageMagick)"  "false"
check_tool "ffmpeg"        "Miniaturas de fondos animados en video"  "false"

if [ $REQ_ERRORS -gt 0 ]; then
    error "Faltan paquetes esenciales requeridos para continuar. Por favor instálalos antes de volver a ejecutar."
    exit 1
fi

# ── 3. Entorno virtual de Python para Minerva ──────────────────────────────────
info "Configurando entorno virtual de Python en Minerva/.venv..."
if [[ ! -d "${MINERVA_DIR}/.venv" ]]; then
    "${PYTHON_BIN}" -m venv "${MINERVA_DIR}/.venv"
    success "Entorno virtual creado en ${MINERVA_DIR}/.venv"
fi

info "Instalando / actualizando librerías de Python desde Minerva/requirements.txt..."
"${MINERVA_DIR}/.venv/bin/python3" -m pip install -q -U pip
"${MINERVA_DIR}/.venv/bin/python3" -m pip install -q -r "${MINERVA_DIR}/requirements.txt"
success "Dependencias de Python instaladas correctamente."

# ── 4. Modelos de voz locales (Vosk STT y Piper TTS) ───────────────────────────
mkdir -p "${MINERVA_DIR}/voice"

if [[ ! -d "${MINERVA_DIR}/voice/vosk-model-es" ]]; then
    info "Descargando modelo de reconocimiento de voz Vosk para wake word (español)..."
    TEMP_DIR="$(mktemp -d)"
    trap 'rm -rf "${TEMP_DIR}"' EXIT
    curl -fL "https://alphacephei.com/vosk/models/vosk-model-small-es-0.42.zip" -o "${TEMP_DIR}/vosk.zip"
    unzip -q "${TEMP_DIR}/vosk.zip" -d "${TEMP_DIR}"
    mv "${TEMP_DIR}/vosk-model-small-es-0.42" "${MINERVA_DIR}/voice/vosk-model-es"
    success "Modelo Vosk instalado."
else
    success "Modelo Vosk ya presente en Minerva/voice/vosk-model-es"
fi

if [[ ! -f "${MINERVA_DIR}/voice/es_MX-claude-high.onnx" ]]; then
    info "Descargando modelo de voz Piper TTS (es_MX-claude-high)..."
    curl -fL "https://huggingface.co/rhasspy/piper-voices/resolve/main/es/es_MX/claude/high/es_MX-claude-high.onnx" -o "${MINERVA_DIR}/voice/es_MX-claude-high.onnx"
    success "Modelo ONNX de Piper instalado."
else
    success "Modelo ONNX de Piper ya presente."
fi

if [[ ! -f "${MINERVA_DIR}/voice/es_MX-claude-high.onnx.json" ]]; then
    info "Descargando configuración de Piper TTS..."
    curl -fL "https://huggingface.co/rhasspy/piper-voices/resolve/main/es/es_MX/claude/high/es_MX-claude-high.onnx.json" -o "${MINERVA_DIR}/voice/es_MX-claude-high.onnx.json"
    success "Configuración JSON de Piper instalada."
fi

# ── 5. Configuración de claves y ajustes en ~/.config/minerva ─────────────────
info "Configurando directorio de ajustes privados en ~/.config/minerva..."
mkdir -p "${CONFIG_DIR}"
chmod 700 "${CONFIG_DIR}"

if [[ ! -f "${SETTINGS_FILE}" ]]; then
    cp "${MINERVA_DIR}/settings.example.json" "${SETTINGS_FILE}"
    chmod 600 "${SETTINGS_FILE}"
    success "Plantilla de configuración creada en: ${SETTINGS_FILE}"
else
    chmod 600 "${SETTINGS_FILE}"
    success "Archivo de configuración existente detectado: ${SETTINGS_FILE}"
fi

# Proteger otros archivos sensibles si existen
for priv in "${CONFIG_DIR}/credentials.json" "${CONFIG_DIR}/token_cache.json" "${CONFIG_DIR}/.env"; do
    if [[ -f "${priv}" ]]; then
        chmod 600 "${priv}"
    fi
done

# ── 6. Servicio de Systemd para Wallpaper Watcher ──────────────────────────────
info "Configurando servicio de systemd para el monitor de wallpapers..."
mkdir -p "${SYSTEMD_USER_DIR}"
cp "${MINERVA_SHELL_ROOT}/components/Wallpaper/minerva-wallpaper-watcher.service" "${SYSTEMD_USER_DIR}/minerva-wallpaper-watcher.service"

if command -v systemctl &>/dev/null; then
    systemctl --user daemon-reload || true
    # Intentar habilitar e iniciar si es posible
    if systemctl --user enable --now minerva-wallpaper-watcher.service &>/dev/null; then
        success "Servicio minerva-wallpaper-watcher habilitado y en ejecución."
    else
        warn "No se pudo habilitar automáticamente el servicio. Puedes activarlo con:"
        echo -e "       ${CLR_CYAN}systemctl --user enable --now minerva-wallpaper-watcher.service${CLR_RESET}"
    fi
fi

# ── 7. Comprobación del plugin Caelestia ───────────────────────────────────────
if [[ ! -f "${MINERVA_SHELL_ROOT}/Caelestia/libcaelestiaplugin.so" ]]; then
    if command -v cmake &>/dev/null; then
        info "Compilando plugin Caelestia..."
        cmake -B "${MINERVA_SHELL_ROOT}/plugin/build" -S "${MINERVA_SHELL_ROOT}/plugin"
        cmake --build "${MINERVA_SHELL_ROOT}/plugin/build"
        success "Plugin Caelestia compilado."
    else
        warn "libcaelestiaplugin.so no encontrado y cmake no está instalado. Si experimentas problemas en el Launcher, compila el plugin en plugin/."
    fi
else
    success "Plugin Caelestia presente (libcaelestiaplugin.so)."
fi

# ── 8. Asegurar permisos de ejecución en scripts ──────────────────────────────
chmod +x "${MINERVA_DIR}/run-backend.sh"
chmod +x "${MINERVA_SHELL_ROOT}/components/Wallpaper/wallpaper_watcher.sh"
chmod +x "${MINERVA_SHELL_ROOT}/components/Wallpaper/generate_thumbnails.sh"

# ── 9. Asistente de Clave API de Gemini ────────────────────────────────────────
HAS_API_KEY=false
if grep -q '"geminiApiKey": "AIza' "${SETTINGS_FILE}" 2>/dev/null; then
    HAS_API_KEY=true
elif grep -q '"geminiApiKey": ""' "${SETTINGS_FILE}" 2>/dev/null; then
    HAS_API_KEY=false
fi

echo ""
echo -e "${CLR_BOLD}${CLR_YELLOW}================================================================"
echo -e "           CONFIGURACIÓN DE CLAVES DE API (IA)"
echo -e "================================================================${CLR_RESET}"
echo -e "El archivo de configuración principal de Minerva se encuentra en:"
echo -e "  ${CLR_BOLD}${CLR_CYAN}${SETTINGS_FILE}${CLR_RESET}\n"
echo -e "Allí se configuran:"
echo -e "  - ${CLR_BOLD}geminiApiKey${CLR_RESET}  : Tu API Key de Google Gemini (Gratis en https://aistudio.google.com/)"
echo -e "  - ${CLR_BOLD}geminiModel${CLR_RESET}   : Modelo predeterminado (ej: gemini-2.5-flash)"
echo -e "  - ${CLR_BOLD}ttsProvider${CLR_RESET}   : Motor de voz (piper [local], gemini, fish)"
echo -e "  - ${CLR_BOLD}fishApiKey${CLR_RESET}    : Opcional, si utilizas Fish Audio para TTS con emociones"
echo -e "${CLR_BOLD}${CLR_YELLOW}----------------------------------------------------------------${CLR_RESET}"

if [ "$HAS_API_KEY" = "false" ] && [ -t 0 ]; then
    echo -e "\n¿Deseas ingresar tu clave de API de Google Gemini ahora mismo? [s/N]: "
    read -r resp
    if [[ "$resp" =~ ^[sSyY]$ ]]; then
        echo -e "Pega tu clave de API de Gemini (la entrada será visible): "
        read -r input_key
        if [[ -n "$input_key" ]]; then
            "${PYTHON_BIN}" -c "
import json, sys
path = '${SETTINGS_FILE}'
with open(path, 'r', encoding='utf-8') as f:
    data = json.load(f)
data['geminiApiKey'] = sys.argv[1].strip()
with open(path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
" "$input_key"
            chmod 600 "${SETTINGS_FILE}"
            success "Clave de API guardada con éxito en ${SETTINGS_FILE}"
            HAS_API_KEY=true
        fi
    fi
fi

if [ "$HAS_API_KEY" = "false" ]; then
    warn "Aún no has configurado 'geminiApiKey'. Recuerda añadirla en:"
    echo -e "       ${CLR_BOLD}${CLR_CYAN}${SETTINGS_FILE}${CLR_RESET}"
fi

# ── 9. Resumen final ──────────────────────────────────────────────────────────
echo ""
echo -e "${CLR_BOLD}${CLR_GREEN}================================================================"
echo -e "          ¡Instalación completada con éxito!"
echo -e "================================================================${CLR_RESET}"
echo -e "Pasos siguientes para usar Minerva Shell:\n"
echo -e "1. Probar el shell manualmente:"
echo -e "     ${CLR_CYAN}quickshell$ -p ~/.config/minerva_shell_minimal${CLR_RESET}\n"
echo -e "2. Iniciar el monitor de wallpapers (si no se activó antes):"
echo -e "     ${CLR_CYAN}systemctl --user enable --now minerva-wallpaper-watcher.service${CLR_RESET}\n"
echo -e "3. Configurar tus atajos de teclado e inicio automático en tu gestor (Hyprland)."
echo -e "   Consulta todos los comandos IPC y detalles en el archivo ${CLR_BOLD}README.md${CLR_RESET}.\n"
