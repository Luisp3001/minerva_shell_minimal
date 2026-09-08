#!/usr/bin/env bash
set -euo pipefail
umask 077

MINERVA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${MINERVA_ROOT}"

PYTHON_BIN="$(command -v python3)"
PYTHON_VERSION="$(${PYTHON_BIN} -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
case "${PYTHON_VERSION}" in
    3.12|3.13|3.14) ;;
    *)
        echo "Minerva requiere Python 3.12, 3.13 o 3.14; se encontró ${PYTHON_VERSION}." >&2
        exit 1
        ;;
esac

if [[ ! -d .venv ]]; then
    "${PYTHON_BIN}" -m venv .venv
fi

.venv/bin/python3 -m pip install -U pip
.venv/bin/python3 -m pip install -r requirements.txt

mkdir -p voice
if [[ ! -d voice/vosk-model-es ]]; then
    TEMP_DIR="$(mktemp -d)"
    trap 'rm -rf "${TEMP_DIR}"' EXIT
    curl -fL "https://alphacephei.com/vosk/models/vosk-model-small-es-0.42.zip" -o "${TEMP_DIR}/vosk.zip"
    unzip -q "${TEMP_DIR}/vosk.zip" -d "${TEMP_DIR}"
    mv "${TEMP_DIR}/vosk-model-small-es-0.42" voice/vosk-model-es
fi

if [[ ! -f voice/es_MX-claude-high.onnx ]]; then
    curl -fL "https://huggingface.co/rhasspy/piper-voices/resolve/main/es/es_MX/claude/high/es_MX-claude-high.onnx" -o voice/es_MX-claude-high.onnx
fi

if [[ ! -f voice/es_MX-claude-high.onnx.json ]]; then
    curl -fL "https://huggingface.co/rhasspy/piper-voices/resolve/main/es/es_MX/claude/high/es_MX-claude-high.onnx.json" -o voice/es_MX-claude-high.onnx.json
fi

mkdir -p "${HOME}/.config/minerva"
chmod 700 "${HOME}/.config/minerva"
if [[ ! -f "${HOME}/.config/minerva/settings.json" ]]; then
    cp settings.example.json "${HOME}/.config/minerva/settings.json"
fi
chmod 600 "${HOME}/.config/minerva/settings.json"
for private_file in \
    "${HOME}/.config/minerva/credentials.json" \
    "${HOME}/.config/minerva/token_cache.json"; do
    if [[ -f "${private_file}" ]]; then
        chmod 600 "${private_file}"
    fi
done

echo "Minerva instalada. Reinicia Quickshell para usar el entorno local."
