#!/usr/bin/env bash
set -euo pipefail
umask 077

MINERVA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEGACY_ROOT="${HOME}/.config/minerva_shell/optional/Minerva"
export PYTHONDONTWRITEBYTECODE=1

# La configuración contiene credenciales de servicios de voz y Gemini.
MINERVA_SETTINGS="${HOME}/.config/minerva/settings.json"
if [[ -f "${MINERVA_SETTINGS}" ]]; then
    chmod 600 "${MINERVA_SETTINGS}"
fi
for private_file in \
    "${HOME}/.config/minerva/credentials.json" \
    "${HOME}/.config/minerva/token_cache.json"; do
    if [[ -f "${private_file}" ]]; then
        chmod 600 "${private_file}"
    fi
done

# Los modelos pesan más de 100 MiB. Hasta ejecutar install.sh, se reutilizan
# los de la instalación anterior sin acoplar el código nuevo a esa ruta.
if [[ ! -d "${MINERVA_ROOT}/voice/vosk-model-es" && -d "${LEGACY_ROOT}/voice" ]]; then
    export MINERVA_VOICE_DIR="${LEGACY_ROOT}/voice"
fi

if [[ -x "${MINERVA_ROOT}/.venv/bin/python3" ]]; then
    MINERVA_PYTHON="${MINERVA_ROOT}/.venv/bin/python3"
elif [[ -x "${LEGACY_ROOT}/.venv/bin/python3" ]]; then
    MINERVA_PYTHON="${LEGACY_ROOT}/.venv/bin/python3"
else
    MINERVA_PYTHON="$(command -v python3)"
fi

exec "${MINERVA_PYTHON}" -u "${MINERVA_ROOT}/main.py"
