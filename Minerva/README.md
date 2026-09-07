# Minerva

Minerva es una asistente de inteligencia artificial integrada directamente en `minerva_shell_v2` con [Quickshell](https://github.com/quickshell-mirror/quickshell). Combina un frontend QML nativo de Wayland con un backend Python basado en Gemini y herramientas del sistema operativo: ejecución de comandos asíncronos, sistema de archivos, búsqueda web, generación de imágenes, control de Hyprland, control de Spotify, captura de pantalla, gestión proactiva de tareas y memoria persistente a largo plazo.

El nombre viene de la diosa romana de la sabiduría.

---

## Uso en minerva_shell_v2

- El orbe de Minerva vive en la isla. Al pulsarlo abre el chat de `600 × 560`.
- El panel también se alterna con `qs ipc call shell toggleMinerva` (añade `-p /ruta/al/shell` si la configuración no es la predeterminada).
- `Esc` o el botón de cerrar devuelven la isla al estado compacto.
- El engranaje del encabezado —o `Ctrl+,`— abre los selectores de modelo y voz.
- El backend es único para todas las pantallas y conserva conversación, tareas y estado de voz al cambiar de monitor.
- Todos los comandos de shell abren automáticamente el chat para pedir confirmación; los privilegiados se autentican mediante `pkexec`.

Los ajustes privados se leen de `~/.config/minerva/settings.json`. Si todavía no existe, durante la migración se importan en memoria desde `~/.config/minerva_shell/plugin_settings.json`; ninguna clave se copia al repositorio. Usa `settings.example.json` como plantilla.

La primera ejecución reutiliza el entorno virtual y los modelos de voz del shell anterior, si existen. Para hacer el módulo completamente independiente:

```bash
./Minerva/install.sh
```

Después reinicia Quickshell. El instalador conserva un entorno local existente y descarga los modelos sólo si faltan.

---

## Características principales

- **Gemini con streaming:** Motor de texto en la nube con streaming de tokens, visión y tool calls.
- **Agentic loop:** La IA puede invocar herramientas de forma iterativa (hasta 12 turnos) para completar tareas complejas.
- **Ejecución de comandos asíncrona:** Coordinada vía `JobManager` thread-safe con rastreo por `job_id`, turnos multi-comando, streaming de salida en tiempo real e inspección de estado con `check_job_status` — no se congela mientras espera.
- **Sistema de voz completo:** Wake word ("Minerva"), STT (Whisper), TTS triple (**Piper** local, **Fish Audio** en la nube con **Emotion Tags** y **Google Gemini TTS** con ~30 voces) y detección de silencio.
- **Generación de imágenes:** Integración nativa con Gemini (`gemini-3.1-flash-image`) para generar imágenes a partir de descripciones de texto en resoluciones 1K (previsualizable en el chat) y 2K (guardado directo en disco en `~/Pictures/minerva`).
- **Control de entorno de escritorio (Hyprland):** Navegación entre workspaces (1-10), reubicación de ventanas entre workspaces por clase o título y listado de ventanas activas vía `hyprctl`.
- **Herramientas de documentos y RAG Efímero:** Creación de documentos Word (`.docx`) formateados desde Markdown con `pandoc`, edición quirúrgica de Word con `python-docx` y consulta semántica puntual (`query_document`) en PDF, DOCX y PPTX con `MarkItDown` + `ChromaDB` sin necesidad de leer todo el archivo.
- **SiriOrb:** Visualización animada por GPU (fragment shader) que reacciona al audio en tiempo real con RMS y 4 bandas FFT.
- **Memoria a largo plazo:** Archivos Markdown (`user_profile.md` y `preferences.md`) para almacenar el perfil del usuario y sus preferencias entre sesiones, actualizables proactivamente con `update_memory`.
- **Proactividad (Tareas):** Conexión a PostgreSQL para gestionar tareas con alertas visuales sutiles en el SiriOrb. Soporta **tareas recurrentes** (diaria, semanal, mensual, anual con `recurrence_month`) con auto-renovación en segundo plano.
- **Herramientas de archivos avanzadas:** Lectura inteligente por rangos de líneas (`read_file`), metadatos (`file_info`), creación directa (`write_file`), edición quirúrgica (`replace_lines`) y conversión a Markdown para PDF, Word (`.docx`), PowerPoint (`.pptx`) y Excel/CSV (`.xlsx`/`.csv`).
- **Tool RAG:** Selección inteligente de herramientas relevantes vía embedding semántico para no saturar el contexto.
- **Seguridad:** Todos los comandos requieren confirmación; la clasificación `safe / destructive / sudo` solo ajusta la advertencia y el canal de privilegios.
- **Captura de pantalla:** Visión multimodal — Minerva puede ver tu pantalla y analizarla.
- **Spotify:** Control completo vía OAuth2 PKCE; solo abre un callback loopback temporal durante la autenticación.
- **Directorio de configuración unificado:** Centralización de variables de entorno (`.env`), credenciales y tokens de caché en `~/.config/minerva/`.

---

## Estructura del proyecto

```text
Minerva/
│
│  ── Frontend (QML) ──────────────────────────────────────────────────
│
├── qmldir                       # Registro de los componentes QML del módulo
├── Theme.qml                    # Paleta local desacoplada del estilo del shell anterior
├── Main.qml                     # Servicio compartido:
│                                #   - Inicia el proceso Python como subproceso
│                                #   - IPC bidireccional JSON Lines por stdin/stdout
│                                #   - Estado global: configuración IA, grabación, transcripción
├── ChatWidget.qml               # Interfaz de chat completa:
│                                #   - Burbujas de usuario e IA con streaming de tokens
│                                #   - Tarjetas de comando (pending / running / success / error)
│                                #   - Streaming de salida de comandos en tiempo real
│                                #   - Previsualización de imágenes generadas por IA
│                                #   - Input con micrófono, adjuntar imagen, placeholder dinámico
├── CommandApprovalDialog.qml    # Cola y diálogo de aprobación para todo comando shell
├── SettingsPanel.qml            # Selector persistente de modelo y configuración TTS
├── SiriOrb.qml                  # Orbe animado tipo Siri (GPU ShaderEffect):
│                                #   - Estados: idle, recording, transcribing, thinking, speaking
│                                #   - Recibe audioRms + 4 bandas FFT como uniforms
│                                #   - Acumulador de fase continuo (~60fps) para evitar saltos
│
├── shaders/
│   ├── siri_orb.frag            # Fragment shader GLSL: Simplex Noise + 4 ondas de color
│   └── siri_orb.frag.qsb       # Shader precompilado (Qt Shader Baker)
│
├── voice/                       # Modelos locales de voz (creados por install.sh)
│   ├── es_MX-claude-high.onnx   # Modelo Piper TTS (español México, calidad alta)
│   ├── es_MX-claude-high.onnx.json
│   └── vosk-model-es/           # Modelo Vosk STT para wake word
│
│  ── Backend (Python) ────────────────────────────────────────────────
│
├── main.py                      # Punto de entrada del backend:
│                                #   - Coordinador JSONL sin servidor ni puerto local
│                                #   - Bucle principal: despacha mensajes (chat, run_confirmed,
│                                #     run_sudo, toggle_voice, cancel, ping, stop_tts)
│                                #   - Pools y colas acotados para chat, comandos, voz y transcripción
│                                #   - Transcripción de voz (Whisper)
├── requirements.txt             # Dependencias pip del entorno virtual
├── settings.example.json        # Plantilla sin secretos para ~/.config/minerva
├── run-backend.sh               # Selección segura del entorno Python y assets
├── install.sh                   # Instalación autocontenida, idempotente
├── .venv/                       # Entorno virtual local opcional (generado)
│
└── backend/
    ├── __init__.py
    ├── core/                    # Lógica central y motores de IA
    │   ├── config.py            # Constantes globales y directorio ~/.config/minerva/:
    │   │                        #   - MODEL, HOME, MAX_FILE, MAX_DIR
    │   │                        #   - Paths de Spotify, voz y .env unificado
    │   │                        #   - Flags de disponibilidad (VOICE_AVAILABLE, FISH_AUDIO_AVAILABLE, GEMINI_TTS_AVAILABLE, etc.)
    │   ├── io.py                # Comunicación con QML:
    │   │                        #   - emit() / emit_error() → JSON Lines a stdout
    │   │                        #   - is_safe_path() → verificación $HOME
    │   │                        #   - classify_cmd() → safe / destructive / sudo
    │   ├── job_manager.py       # JobManager (singleton job_mgr):
    │   │                        #   - CommandJob con UUID, salida acotada y cancelación real
    │   │                        #   - Turnos multi-comando aislados por request_id
    │   ├── gemini_engine.py     # Engine de chat con Gemini (API OpenAI-compatible / GenAI):
    │   │                        #   - SSE streaming, tool calls incrementales (delta chunks)
    │   │                        #   - Soporte multimodal (imágenes en base64) y desconcatenación de calls
    │   ├── voice.py             # VoiceManager (singleton voice_mgr):
    │   │                        #   - TTS triple: Piper (local ONNX), Fish Audio (nube con Emotion Tags)
    │   │                        #     o Google Gemini TTS (~30 voces neurales)
    │   │                        #   - STT: Whisper (pywhispercpp)
    │   │                        #   - Wake word: Vosk con stream de audio continuo
    │   │                        #   - StreamEmotionStripper para limpiar tags en tiempo real
    │   ├── audio_analyzer.py    # AudioAnalyzer: RMS + FFT de 4 bandas
    │   │                        #   - Suavizado exponencial
    │   │                        #   - Ventana Hann para reducir spectral leakage
    │   │                        #   - Alimenta los uniforms del shader SiriOrb
    │   ├── memory.py            # Lectura y actualización de archivos Markdown (user_profile.md / preferences.md)
    │   │                        #   - get_memory_context() para inyección en el system prompt
    │   │                        #   - update_memory_section() para guardado quirúrgico de secciones
    │   └── tasks_db.py          # Conexión a PostgreSQL (CRUD de tareas + recurrencia):
    │                            #   - init_db(): crea tabla y columnas de recurrencia
    │                            #   - renew_recurring_tasks(): renueva tareas vencidas en segundo plano
    │
    └── tools/                   # Herramientas que la IA puede invocar
        ├── __init__.py          # Exporta dispatch_tool() (despachador centralizado),
        │                        # TOOL_DEFINITIONS, SYSTEM_PROMPT, get_relevant_tools() (RAG)
        ├── definitions.py       # SYSTEM_PROMPT (personalidad, reglas, contexto, FISH_AUDIO_EMOTION_PROMPT)
        │                        # TOOL_DEFINITIONS (esquemas JSON de todas las herramientas)
        ├── registry.py          # Registro de handlers y validación de JSON Schema
        ├── filesystem.py        # list_dir, file_info, read_file, write_file, replace_lines,
        │                        # read_pdf, read_docx, read_pptx, read_excel (vía MarkItDown),
        │                        # create_docx, modify_docx, query_document (RAG efímero)
        ├── system.py            # web_search (DuckDuckGo), launch_app (busca .desktop),
        │                        # hyprland_control (workspaces/ventanas), check_job_status
        ├── imagen.py            # tool_generate_image: Gemini 3.1 Flash Image (1K/2K) en ~/Pictures/minerva
        ├── spotify.py           # spotify_music: OAuth2 completo, control de reproducción
        ├── screen.py            # capture_screen: grim → base64 → visión multimodal
        ├── memory_tool.py       # update_memory: modifica secciones en user_profile.md y preferences.md
        └── tasks.py             # manage_tasks: Gestiona tareas en PostgreSQL (add, complete, list)
                                 #   - Soporte de recurrence ('daily','weekly','monthly','yearly'),
                                 #     recurrence_day y recurrence_month
```

---

## Flujo de comunicación

El frontend y el backend se comunican por el mismo subproceso, sin abrir un puerto:

```
┌──────────────────────┐       stdin (JSON Lines)      ┌──────────────────────┐
│      QML (Main.qml)  │  ──────────────────────────▶  │   Python (main.py)   │
│                      │  ◀──────────────────────────  │                      │
└──────────────────────┘       stdout (JSON Lines)     └──────────────────────┘
```

**QML → Python (peticiones):** La interfaz escribe un objeto JSON por línea en stdin. Los tipos de mensaje incluyen:

| Tipo              | Descripción                                          |
|-------------------|------------------------------------------------------|
| `chat`            | Mensaje del usuario con historial, imagen y settings |
| `run_confirmed`   | Confirmación para ejecutar un comando normal (pasa `job_id`) |
| `run_sudo`        | Confirmación para ejecutar un comando con pkexec (pasa `job_id`) |
| `job_cancelled`   | Notifica que un comando fue cancelado por el usuario (pasa `job_id`) |
| `toggle_voice`    | Iniciar/detener grabación de voz                     |
| `cancel`          | Cancelar operación en curso                          |
| `stop_tts`        | Detener la síntesis de voz                           |
| `ping`            | Health check (retorna `ready`)                       |
| `save_settings`   | Guardado atómico de ajustes privados                 |

**Python → QML (eventos):** El backend escribe una línea JSON por evento a stdout, que QML lee vía `SplitParser`. Los tipos de evento incluyen:

| Tipo                     | Descripción                                            |
|--------------------------|--------------------------------------------------------|
| `tasks_pending`          | Señal silenciosa: hay tareas pendientes (incluye `urgent: bool`, `urgency: string`) |
| `tasks_cleared`          | Señal silenciosa: no hay tareas pendientes             |
| `ready`                  | Backend inicializado, modelo y home disponibles        |
| `token`                  | Token de texto generado por la IA (streaming)          |
| `done`                   | Respuesta completa de la IA                            |
| `tool_start`             | La IA comienza a usar una herramienta                  |
| `tool_result`            | Resultado de la herramienta (interno)                  |
| `command_start`          | Inicio de ejecución asíncrona de un comando (`job_id`) |
| `command_output`         | Línea de salida parcial del comando en ejecución (`job_id`) |
| `command_result`         | Resultado final del comando (`job_id`, output, returncode) |
| `confirm_required`       | Comando normal que necesita confirmación (`job_id`)    |
| `sudo_required`          | Comando que necesita privilegios elevados (`job_id`)   |
| `voice_recording_started`| Grabación de micrófono iniciada                        |
| `voice_recording_stopped`| Grabación detenida                                     |
| `voice_transcribing`     | Transcribiendo audio con Whisper                       |
| `voice_recognized`       | Texto transcrito listo                                 |
| `wake_word_detected`     | Se detectó "Minerva" via Vosk                          |
| `silence_detected`       | Silencio detectado, fin de dictado                     |
| `voice_speaking_started` | TTS comienza a hablar                                  |
| `voice_speaking_stopped` | TTS terminó de hablar                                  |
| `audio_data`             | Métricas de audio en tiempo real (rms + 4 bandas FFT)  |
| `error`                  | Error genérico                                         |

---

## Flujo de un mensaje de chat

```
Usuario escribe → QML escribe JSONL {"type":"chat"} → main.py recibe
    │
    ├── Inyecta fecha al SYSTEM_PROMPT
    ├── Inyecta memoria (user_profile.md y preferences.md) al prompt
    ├── Inyecta tareas pendientes proactivamente (si aplican)
    ├── Construye historial [system, ...history, user]
    │
    └── pool de chat → do_chat_gemini() con streaming y tool calls
            │
            ├── Emite tokens → QML los muestra en la burbuja de IA
            │
            ├── Si la IA decide usar tool_calls:
            │       ├── dispatch_tool() ejecuta la herramienta
            │       ├── Si es run_command:
            │       │       ├── Crea CommandJob y registra en JobManager
            │       │       ├── normal/destructivo → emite "confirm_required"
            │       │       ├── sudo → emite "sudo_required"
            │       │       └── Aísla el turno por request_id y retoma cuando TODOS terminan
            │       ├── Si es otra tool → ejecuta, inyecta resultado, reitera
            │       └── Máximo 12 iteraciones
            │
            └── Sin tool calls → emite "done" → fin del turno
```

---

## Sistema de voz

Minerva tiene un pipeline de voz completo con tres subsistemas independientes:

**Wake word (siempre activo):** Un hilo dedicado escucha el micrófono continuamente usando Vosk con un modelo de español. Cuando detecta la palabra "minerva" en el flujo de audio, emite `wake_word_detected` y la UI activa la grabación automáticamente.

**STT (Speech-to-Text):** Al activar la grabación (botón de micrófono o wake word), el audio del micrófono se acumula en un búfer. Cuando se detiene la grabación (manual o por detección de silencio), el audio se transcribe con Whisper (pywhispercpp, modelo small) y el texto resultante se envía como si el usuario lo hubiera escrito.

**TTS (Text-to-Speech):** Motor triple configurable desde la UI:
- **Piper (local ONNX):** Síntesis offline rápida con modelo ONNX en español (`es_MX-claude-high`).
- **Fish Audio (API en la nube):** Síntesis neural de alta calidad con soporte de **Emotion Tags** (`[happy]`, `[sad]`, `[excited]`, `[confident]`, `[neutral]`, etc.). Un procesador en streaming (`StreamEmotionStripper`) limpia los tags en tiempo real antes de emitir los tokens a la UI, asegurando que la voz exprese entonación sin mostrar símbolos en el chat.
- **Google Gemini TTS (API en la nube):** Síntesis neural multilingüe con la API oficial de Google (`google-genai`). Admite modelos `gemini-2.5-flash-tts` y `gemini-2.5-pro-tts` con ~30 voces preconstruidas (ej: `Kore`, `Aoede`, `Puck`, `Charon`, `Zephyr`, etc.) convertidas directamente a audio PCM 24kHz.

Durante la reproducción de cualquier motor, un `AudioAnalyzer` calcula métricas (RMS + FFT) que se envían al frontend para animar el SiriOrb en sincronía con la voz.

---

## Herramientas disponibles para la IA

| Herramienta       | Archivo                | Descripción                                                      |
|-------------------|------------------------|------------------------------------------------------------------|
| `list_dir`        | `tools/filesystem.py`  | Lista el contenido de un directorio (dentro de $HOME)            |
| `file_info`       | `tools/filesystem.py`  | Devuelve metadatos del archivo (total de líneas y tamaño)        |
| `read_file`       | `tools/filesystem.py`  | Lee un archivo por rangos de líneas (`start_line`, `end_line`)   |
| `write_file`      | `tools/filesystem.py`  | Crea o sobreescribe un archivo de forma directa (`overwrite`)    |
| `replace_lines`   | `tools/filesystem.py`  | Reemplazo quirúrgico de líneas específicas en un archivo         |
| `read_pdf`        | `tools/filesystem.py`  | Extrae texto de un PDF a Markdown (vía MarkItDown)              |
| `read_docx`       | `tools/filesystem.py`  | Extrae contenido de un archivo Word (.docx) a Markdown           |
| `read_pptx`       | `tools/filesystem.py`  | Extrae texto de presentaciones PowerPoint (.pptx) a Markdown     |
| `read_excel`      | `tools/filesystem.py`  | Extrae contenido de hojas Excel (.xlsx) y CSV a Markdown         |
| `create_docx`     | `tools/filesystem.py`  | Crea un archivo Word (.docx) formateado desde Markdown (pandoc)  |
| `modify_docx`     | `tools/filesystem.py`  | Añade párrafos de texto al final de un archivo Word (.docx)      |
| `query_document`  | `tools/filesystem.py`  | Búsqueda semántica (RAG efímero) en PDF, DOCX, PPTX con ChromaDB |
| `run_command`     | `tools/__init__.py`    | Ejecuta un comando bash (asíncrono, rastreado por `job_id`)      |
| `check_job_status`| `tools/system.py`      | Consulta el estado y salida de comandos en segundo plano         |
| `web_search`      | `tools/system.py`      | Busca en internet via DuckDuckGo (ddgs)                          |
| `launch_app`      | `tools/system.py`      | Busca y abre una app gráfica por nombre o sinónimo               |
| `hyprland_control`| `tools/system.py`      | Controla workspaces y mueve ventanas en Hyprland vía `hyprctl`   |
| `generate_image`  | `tools/imagen.py`      | Genera imágenes con Gemini 3.1 Flash Image (1K/2K) en ~/Pictures |
| `spotify_music`   | `tools/spotify.py`     | Control de Spotify (play, pause, search, queue, volume, etc.)    |
| `capture_screen`  | `tools/screen.py`      | Captura la pantalla con grim → base64 → visión multimodal       |
| `update_memory`   | `tools/memory_tool.py` | Modifica quirúrgicamente `user_profile.md` o `preferences.md`    |
| `manage_tasks`    | `tools/tasks.py`       | Gestiona tareas en PostgreSQL (`add`, `complete`, `list`) con soporte de recurrencia (`recurrence`, `recurrence_day`, `recurrence_month`) |

---

## Proactividad y Tareas (PostgreSQL)

Minerva puede gestionar tus pendientes usando una base de datos PostgreSQL remota o local (configurada en `~/.config/minerva/.env`). Esto le permite funcionar como un asistente proactivo real:

1. **Inyección de Contexto**: Al chatear, Minerva lee tus tareas pendientes y las inyecta en su `SYSTEM_PROMPT` para conocerlas y recordártelas de forma natural.
2. **Worker en Segundo Plano**: Un hilo en `main.py` sondea la BD cada 10 minutos. Antes de consultar pendientes, llama a `renew_recurring_tasks()` para renovar automáticamente cualquier tarea recurrente vencida.
3. **Indicador Visual Silencioso**: QML captura el evento y muestra el SiriOrb en el centro de tu pantalla por 20 segundos y deja un aviso en el widget. El orbe reacciona visualmente según el nivel de urgencia máximo con tinte de color en GPU y una animación de respiración/pulso: **Verde esmeralda** (baja urgencia, > 3 días), **Amarillo/Ámbar** (media urgencia, 1 a 3 días) o **Rojo vibrante parpadeante** (alta urgencia / vencida, < 24 horas).
4. **Herramienta IA**: Minerva tiene la tool `manage_tasks` para añadir nuevas tareas, ponerles fecha de vencimiento (`due_date`) o marcarlas como completadas. `manage_tasks` está **siempre disponible** en el Tool RAG para garantizar que la IA la use ante cualquier pregunta sobre fechas o cobros.

### Tareas recurrentes

Las tareas pueden repetirse automáticamente configurando campos adicionales:

| Campo            | Tipo        | Descripción                                                                                  |
|------------------|-------------|----------------------------------------------------------------------------------------------|
| `recurrence`     | `VARCHAR(10)` | Frecuencia: `'daily'`, `'weekly'`, `'monthly'`, `'yearly'`. `NULL` = tarea única.          |
| `recurrence_day` | `INTEGER`   | Día de anclaje. Para `monthly`/`yearly`: día del mes (1-31). Para `weekly`: día de semana (0=lun…6=dom). |
| `recurrence_month` | `INTEGER` | Mes de anclaje (1-12). Solo usado para recurrencia `'yearly'` (ej. cumpleaños). |

---

## Seguridad de comandos y JobManager

El módulo `io.py` clasifica cada comando para escoger la advertencia y el canal de ejecución. Esa clasificación no concede permiso para ejecutar:

- **safe**: Requiere confirmación explícita igual que cualquier otro comando libre.
- **destructive** (rm, dd, mkfs, shred, etc.): Muestra una advertencia reforzada antes de confirmar.
- **sudo** (sudo, pkexec, pacman -S, systemctl start/stop, etc.): Se ejecuta via `pkexec` (polkit) tras confirmación.

Cada comando emitido se registra en el singleton **`JobManager`** (`job_mgr`) como un **`CommandJob`** con un UUID hexadecimal completo.
- **Estados del job:** `queued` → `running` → `completed` / `failed` / `cancelled` (si el usuario cancela en la UI).
- **Gestión por turnos:** Cada conjunto se abre y sella de forma atómica bajo su `request_id`. El backend espera a que todos sus jobs alcancen un estado terminal antes de reanudar solo esa conversación.
- **Recursos acotados:** Los pools tienen límites de workers y pendientes; la salida retenida, las colas IPC/TTS y el historial también tienen topes explícitos.

---

## Memoria y RAG

Minerva usa almacenamiento estructurado y ChromaDB para dos propósitos:

1. **Memoria a largo plazo** (`user_profile.md` y `preferences.md`): Almacena hechos, datos personales y preferencias del usuario. Al inicio de cada chat, se inyectan en el system prompt. La IA usa `update_memory` para guardar o actualizar secciones proactivamente.

2. **Tool RAG** (colección efímera `minerva_tools`): Evita enviar todas las definiciones en cada request. Usa embeddings para seleccionar las herramientas relevantes; `manage_tasks`, `run_command` y `check_job_status` permanecen siempre disponibles.

3. **RAG Efímero de Documentos** (`query_document`): Permite consultar información puntual en PDF, DOCX y PPTX dividiendo el texto en chunks y creando una colección ChromaDB temporal en memoria.

Directorio de configuración e historias: `~/.config/minerva/`

---

## Dependencias opcionales

El backend detecta automáticamente qué dependencias están instaladas y desactiva funcionalidades que no estén disponibles:

| Flag                     | Dependencias requeridas                  | Funcionalidad             |
|--------------------------|------------------------------------------|---------------------------|
| `VOICE_AVAILABLE`        | sounddevice, soundfile, pywhispercpp     | Grabación y transcripción (STT) |
| `VOSK_AVAILABLE`         | vosk                                     | Wake word ("Minerva")     |
| `FISH_AUDIO_AVAILABLE`   | fish_audio_sdk                           | TTS en la nube con Emotion Tags |
| `GEMINI_TTS_AVAILABLE`   | google-genai                             | TTS en la nube con Google Gemini (~30 voces) |
| `WEB_SEARCH_AVAILABLE`   | ddgs                                     | Búsqueda web              |
| `CHROMADB_AVAILABLE`     | chromadb                                 | RAG efímero y Tool RAG    |
| *(Google GenAI)*         | google-genai                             | Generación de imágenes (`generate_image`) y Gemini TTS |
| *(Documentos Word)*      | pandoc (sistema), python-docx | Creación (`create_docx`) y edición (`modify_docx`) de Word |
| *(MarkItDown opcional)*  | markitdown                               | Extracción de texto de PDF, DOCX, PPTX y Excel/CSV |

Piper TTS se carga bajo demanda (lazy-load) al primer uso de voz local.

---

## Configuración

Los ajustes de IA, voz e imágenes se cargan desde `~/.config/minerva/settings.json` y se pasan al backend en cada petición. La base de datos y la integración de Spotify continúan usando `~/.config/minerva/.env` y los archivos de ese mismo directorio:

| Ajuste            | Propiedad QML   | Descripción                                     |
|-------------------|-----------------|--------------------------------------------------|
| API Key Gemini    | `geminiApiKey`  | Clave de API para Google Generative AI (Chat, Visión, Imágenes y TTS) |
| Modelo Gemini     | `geminiModel`   | Ej: `gemini-2.5-flash`                           |
| Temperatura       | `aiTemperature` | Creatividad del modelo (0.0 – 1.0)              |
| Proveedor TTS     | `ttsProvider`   | `"piper"` (local), `"fish"` (Fish Audio) o `"gemini"` (Google Gemini TTS) |
| Voz Gemini TTS    | `geminiTtsVoice`| Voz preconstruida de Google (ej: `Kore`, `Aoede`, `Puck`, `Charon`) |
| Modelo Gemini TTS | `geminiTtsModel`| Modelo de TTS (ej: `gemini-2.5-flash-tts`, `gemini-2.5-pro-tts`) |
| API Key Fish      | `fishApiKey`    | API Key de Fish Audio                            |
| Voice ID Fish     | `fishVoiceId`   | ID de voz de referencia en Fish Audio            |
| Modelo Fish       | `fishModel`     | Ej: `s2-pro`, `speech-1.6`, etc.                 |
