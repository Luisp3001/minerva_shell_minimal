# Minerva Shell 🌌

[![Wayland](https://img.shields.io/badge/Wayland-Native-blue.svg)](https://wayland.freedesktop.org/)
[![Hyprland](https://img.shields.io/badge/Hyprland-Compositor-cyan.svg)](https://hyprland.org/)
[![Quickshell](https://img.shields.io/badge/Quickshell-Qt6%20%2F%20QML-purple.svg)](https://github.com/quickshell-mirror/quickshell)
[![Python](https://img.shields.io/badge/Python-3.12%20%7C%203.13%20%7C%203.14-yellow.svg)](https://python.org/)
[![Gemini](https://img.shields.io/badge/AI-Google%20Gemini-orange.svg)](https://aistudio.google.com/)

**Minerva Shell** es un entorno de escritorio (shell) moderno, modular y reactivo para **Wayland**, diseñado a medida para **Hyprland** y construido con **[Quickshell](https://github.com/quickshell-mirror/quickshell)** y **Qt 6 / QML**.

Integra una **Dynamic Island** fluida al estilo de los sistemas modernos, un centro de control con paneles interactivos, lanzador de aplicaciones, selector de fondos de pantalla, pantalla de bloqueo con PAM y una asistente de inteligencia artificial multimodal de última generación: **Minerva**.

---

## 📑 Tabla de Contenidos

1. [Componentes del Shell](#-componentes-del-shell)
2. [Minerva: Asistente IA Integrada](#-minerva-asistente-ia-integrada)
3. [Requisitos del Sistema](#-requisitos-del-sistema)
4. [Instalación Rápida](#-instalación-rápida)
5. [Configuración de Claves de API (`settings.json`)](#-configuración-de-claves-de-api-settingsjson)
6. [Integración con Hyprland y Atajos (Keybinds)](#-integración-con-hyprland-y-atajos-keybinds)
7. [Servicio de Fondos de Pantalla (Wallpaper Watcher)](#-servicio-de-fondos-de-pantalla-wallpaper-watcher)
8. [Estructura del Proyecto](#-estructura-del-proyecto)
9. [Solución de Problemas](#-solución-de-problemas)

---

## 🧩 Componentes del Shell

### 1. Dynamic Island (`Island.qml` y `WorkspaceBubble.qml`)
- **Píldora interactiva modular:** Se adapta en tiempo real a eventos del sistema (reproducción de medios, llamadas de atención de Minerva, notificaciones emergentes).
- **Workspace Bubble:** Micro-burbuja flotante reactiva que indica los escritorios activos de Hyprland sin sobrecargar la pantalla.
- **Reloj y Calendario:** Reloj centralizado de alta precisión con calendario desplegable interactivo.
- **Máscara reactiva Wayland:** Utiliza capas nativas de `wlr-layer-shell` con recorte dinámico de regiones (`mask: Region`), permitiendo que el resto de ventanas reciban clicks excepto donde la isla está expandida.

### 2. Lanzador de Aplicaciones (`AppLauncher.qml`)
- Búsqueda instantánea de aplicaciones de escritorio (`.desktop`).
- Categorización automática, filtrado rápido y gestión de favoritos mediante persistencia SQLite local (a través del plugin Caelestia).

### 3. Centro de Control (`ControlCenter.qml`)
- **Conmutadores rápidos:** Modo No Molestar (DND), silenciar audio, suspender equipo.
- **Sliders reactivos:** Control fluido de volumen (PipeWire/PulseAudio) y brillo de pantalla (`brightnessctl`) con actualización desacoplada.
- **Paneles desplegables:**
  - **Wi-Fi (`WifiPanel.qml`):** Escaneo de redes, intensidad de señal y conexión vía `nmcli`.
  - **Bluetooth (`BluetoothPanel.qml`):** Detección, emparejamiento y conexión de dispositivos con `bluetoothctl`.
- **Historial de Notificaciones (`NotificationHistory.qml`):** Registro de avisos recibidos con posibilidad de descartar individualmente o en grupo.

### 4. Pantalla de Bloqueo (`Lock.qml`)
- Pantalla de bloqueo minimalista para Wayland con autenticación PAM nativa (`Quickshell.Services.Pam`).
- Indicadores de batería, hora, fecha y estado de bloqueo seguro.

### 5. Menú de Energía (`PowerMenu.qml`)
- Diálogo modal accesible para suspender, bloquear pantalla, cerrar sesión, reiniciar o apagar el equipo.

### 6. Herramienta de Capturas (`ScreenshotTool.qml`)
- Selección interactiva de región o pantalla completa mediante Quickshell Wayland Screencopy.
- Copia automática al portapapeles (`wl-copy`) y guardado organizado con fecha en `~/Pictures/Screenshots`.

### 7. Selector de Fondos de Pantalla (`WallpaperPicker.qml`)
- Visualización de fondos de pantalla estáticos (JPG, PNG, WebP) y animados en video (MP4, MKV, WebM).
- Compatibilidad con `linux-wallpaperengine` para fondos interactivos.
- Detección de nuevos fondos y generación automática de miniaturas en caché (`~/.cache/wallpaper/`).

---

## 🤖 Minerva: Asistente IA Integrada

Minerva (`Minerva/`) es una asistente inteligente diseñada específicamente para el escritorio Linux:

- **Motor Multimodal Gemini:** Respuestas con streaming de tokens en tiempo real, análisis visual de capturas de pantalla y razonamiento avanzado.
- **Ejecución de Comandos Asíncrona (`JobManager`):** Minerva puede sugerir y ejecutar comandos en el sistema operativo. Cada comando requiere confirmación explícita del usuario a través de un diálogo de aprobación visual (`CommandApprovalDialog.qml`). Los comandos con privilegios se ejecutan mediante `pkexec`.
- **Sistema de Voz Completo:**
  - *Wake Word:* Detección local en segundo plano con **Vosk** en español ("Minerva").
  - *STT (Transcripción):* Reconocimiento de voz local con **Whisper** (`pywhispercpp`).
  - *TTS Triple:* Síntesis de voz local con **Piper** (alta velocidad y privacidad), en la nube con **Fish Audio** (emociones dinámicas) o **Google Gemini TTS** (~30 voces neurales).
- **SiriOrb (`SiriOrb.qml`):** Visualizador de audio acelerado por GPU (fragment shader GLSL) que reacciona a los armónicos y volumen de la voz en tiempo real con RMS y 4 bandas FFT.
- **Control del Entorno Hyprland:** Cambio y consulta de workspaces, movimiento de ventanas y análisis del estado del escritorio.
- **Documentos y RAG:** Lectura y edición inteligente de documentos PDF, Word (`.docx`), PowerPoint (`.pptx`) y Excel (`.xlsx`), así como creación de archivos Word desde Markdown.
- **Memoria Persistente y Tareas:** Perfil de preferencias continuo (`~/.config/minerva/memory/`) y gestión de recordatorios recurrentes.

Para más detalles específicos del backend de IA, consulta la documentación dedicada en [`Minerva/README.md`](file:///home/luisp/.config/minerva_shell/Minerva/README.md).

---

## 📦 Requisitos del Sistema

### Paquetes Principales
| Paquete | Descripción | Requerido |
| :--- | :--- | :---: |
| **quickshell** | Runtime del shell para Wayland/Qt6 | Sí |
| **python3** (3.12, 3.13 o 3.14) | Backend de Minerva y automatizaciones | Sí |
| **curl**, **unzip** | Descarga e instalación de modelos de voz | Sí |
| **wl-clipboard** (`wl-copy`) | Gestión del portapapeles Wayland | Recomendado |
| **pipewire** / **pulseaudio-utils** (`pactl`) | Control de audio y volumen | Recomendado |
| **brightnessctl** | Ajuste de brillo en el Centro de Control | Recomendado |
| **networkmanager** (`nmcli`) | Gestión de redes inalámbricas | Recomendado |
| **bluez-utils** (`bluetoothctl`) | Gestión de Bluetooth | Recomendado |
| **inotify-tools** (`inotifywait`) | Monitor de nuevos fondos de pantalla | Recomendado |
| **imagemagick** / **ffmpeg** | Generación de miniaturas de fondos | Recomendado |
| **linux-wallpaperengine** | Fondos animados interactivos | Opcional |

> **Tip para Arch Linux:**
> ```bash
> sudo pacman -S python curl unzip wl-clipboard pipewire pulseaudio-utils \
>                brightnessctl networkmanager bluez-utils inotify-tools \
>                imagemagick ffmpeg
> # Quickshell está disponible en AUR:
> yay -S quickshell-git
> ```

---

## 🚀 Instalación Rápida

1. **Clonar el repositorio** en la ruta estándar de configuración de usuario:
   ```bash
   git clone https://github.com/tu-usuario/minerva_shell.git ~/.config/minerva_shell
   cd ~/.config/minerva_shell
   ```

2. **Ejecutar el instalador automático:**
   ```bash
   ./install.sh
   ```

El script de instalación realiza automáticamente las siguientes acciones:
- Comprueba la versión de Python y las herramientas del sistema.
- Crea el entorno virtual aislado en `Minerva/.venv/` e instala las dependencias de `Minerva/requirements.txt`.
- Descarga los modelos de voz locales (Vosk STT para wake word y Piper TTS en español).
- Inicializa el directorio de configuración segura en `~/.config/minerva/` con permisos estrictos (`700` y `600`).
- Configura e inicia el servicio de usuario systemd para el monitor de fondos de pantalla.
- Te permite ingresar tu clave de Google Gemini de forma interactiva si lo deseas.

---

## 🔑 Configuración de Claves de API (`settings.json`)

Los ajustes privados y las claves de los servicios de IA se almacenan fuera del repositorio para garantizar su seguridad:

📂 **Ruta del archivo:** `~/.config/minerva/settings.json`

### Ejemplo de Configuración:
```json
{
  "aiProvider": "Gemini",
  "geminiApiKey": "AIzaSyTuClaveDeGoogleGeminiAqui",
  "geminiModel": "gemini-2.5-flash",
  "aiTemperature": "0.7",
  "ttsProvider": "piper",
  "fishApiKey": "",
  "fishVoiceId": "",
  "fishModel": "s2-pro",
  "geminiTtsVoice": "Kore",
  "geminiTtsModel": "gemini-2.5-flash-tts"
}
```

### Opciones de Configuración:
- **`geminiApiKey`**: Tu clave de API de Google Gemini. Puedes obtener una clave gratuita en **[Google AI Studio](https://aistudio.google.com/)**.
- **`geminiModel`**: Modelo de lenguaje (ejemplo: `gemini-2.5-flash`, `gemini-2.5-pro`).
- **`ttsProvider`**: Motor de síntesis de voz:
  - `"piper"`: **Local y privado**. No consume cuota de API, utiliza el modelo ONNX descargado.
  - `"gemini"`: Voz neural en la nube con Google Gemini (~30 voces disponibles).
  - `"fish"`: Voz en la nube con Fish Audio (soporta Emotion Tags en las respuestas).
- **`fishApiKey`**: Clave de API de [Fish Audio](https://fish.audio/) (solo si seleccionas `fish` como proveedor).

> [!NOTE]
> También puedes cambiar el modelo de IA o el proveedor de voz directamente desde la interfaz gráfica de Minerva pulsando el botón de engranaje (o con `Ctrl+,`) dentro del chat.

---

## ⌨️ Integración con Hyprland y Atajos (Keybinds)

Minerva Shell expone un controlador IPC (`IpcHandler`) que permite disparar cualquier acción desde tu gestor de ventanas mediante llamadas al comando:

```bash
quickshell ipc call shell <ACCION>
```

### Tabla de Acciones IPC Disponibles:

| Acción IPC | Descripción |
| :--- | :--- |
| `toggleLauncher` | Despliega o cierra el lanzador de aplicaciones |
| `toggleMinerva` | Abre o cierra el chat / asistente Minerva |
| `openMinervaSettings` | Abre directamente el panel de ajustes de Minerva |
| `toggleControlCenter` | Alterna el Centro de Control (Wi-Fi, volumen, brillo, etc.) |
| `toggleWallpaper` | Abre el selector interactivo de fondos de pantalla |
| `togglePowerMenu` | Abre o cierra el menú de energía (apagar, reiniciar, etc.) |
| `launchScreenshot` | Inicia la herramienta interactiva de capturas de pantalla |
| `lockscreen` | Bloquea la pantalla inmediatamente |
| `closeControlCenter` | Cierre seguro y forzado de paneles abiertos |

---

### Ejemplos de Configuración en Hyprland

> [!TIP]
> Debido a que Hyprland soporta múltiples métodos y lenguajes de configuración (como configuraciones en Lua o sintaxis nativa), utiliza estos ejemplos como referencia para mapear las llamadas IPC a tus atajos preferidos.

#### 1. Autoinicio del Shell
Asegúrate de iniciar Quickshell al entrar en la sesión gráfica:
```bash
exec-once = quickshell
```
*(o si ejecutas un script de inicio o gestor en Lua, invoca el comando `quickshell`).*

#### 2. Mapeo de Atajos de Teclado
Ejemplo de asignación de teclas rápidas recomendadas:

| Atajo | Acción | Comando de ejecución |
| :--- | :--- | :--- |
| `Super + Espacio` | Lanzador de Apps | `quickshell ipc call shell toggleLauncher` |
| `Super + M` | Asistente Minerva | `quickshell ipc call shell toggleMinerva` |
| `Super + Shift + M` | Ajustes de Minerva | `quickshell ipc call shell openMinervaSettings` |
| `Super + C` | Centro de Control | `quickshell ipc call shell toggleControlCenter` |
| `Super + W` | Selector de Fondos | `quickshell ipc call shell toggleWallpaper` |
| `Super + Escape` | Menú de Energía | `quickshell ipc call shell togglePowerMenu` |
| `Super + Shift + S` | Captura de Pantalla | `quickshell ipc call shell launchScreenshot` |
| `Super + L` | Bloquear Pantalla | `quickshell ipc call shell lockscreen` |

#### 3. Reglas de Capa (Layer Rules) para Efectos Visuales
Para habilitar difuminado (blur) y bordes limpios en la barra y las ventanas flotantes del shell, puedes añadir las siguientes reglas de capa en tu compositor:

```ini
layerrule = blur, minerva-shell
layerrule = ignorezero, minerva-shell
layerrule = noanim, minerva-bar
```

---

## 🖼️ Servicio de Fondos de Pantalla (Wallpaper Watcher)

El shell incluye un script de monitoreo (`components/Wallpaper/wallpaper_watcher.sh`) que vigila la carpeta `~/wallpaper`. Cada vez que guardas, mueves o descargas una imagen o video allí, genera su miniatura automáticamente en caché mediante `inotifywait`.

El instalador configura una unidad de servicio de usuario en systemd:
`~/.config/systemd/user/minerva-wallpaper-watcher.service`

### Comandos útiles para gestionar el servicio:
```bash
# Ver estado del servicio
systemctl --user status minerva-wallpaper-watcher.service

# Iniciar o reiniciar el servicio
systemctl --user restart minerva-wallpaper-watcher.service

# Detener el servicio
systemctl --user stop minerva-wallpaper-watcher.service
```

---

## 📁 Estructura del Proyecto

```text
minerva_shell/
├── shell.qml                     # Raíz de Quickshell, ventanas LayerShell e IPC handlers
├── install.sh                    # Script integral de instalación y comprobaciones
├── README.md                     # Documentación general del repositorio
│
├── components/                   # Componentes y widgets del shell
│   ├── Island.qml                # Dynamic Island central y barra superior
│   ├── WorkspaceBubble.qml       # Burbuja reactiva de escritorios de Hyprland
│   ├── AppLauncher.qml           # Lanzador de aplicaciones y búsqueda
│   ├── ControlCenter.qml         # Centro de control (sliders, toggles y paneles)
│   ├── WifiPanel.qml             # Panel de selección y conexión Wi-Fi
│   ├── BluetoothPanel.qml        # Panel de dispositivos Bluetooth
│   ├── MediaWidget.qml           # Widget de reproducción multimedia
│   ├── ClockCalendar.qml         # Widget de reloj y vista de calendario
│   ├── NotificationToast.qml     # Notificaciones emergentes
│   ├── NotificationHistory.qml   # Historial persistente de notificaciones
│   ├── Lock.qml                  # Pantalla de bloqueo nativa Wayland (PAM)
│   ├── PowerMenu.qml             # Menú de acciones de energía
│   └── Wallpaper/                # Módulo de fondos de pantalla
│       ├── WallpaperPicker.qml   # Interfaz gráfica de selección de fondos
│       ├── wallpaper_watcher.sh  # Script daemon con inotifywait
│       ├── generate_thumbnails.sh# Generación de miniaturas (magick / ffmpeg)
│       └── minerva-wallpaper-watcher.service # Unidad de servicio systemd
│
├── Minerva/                      # Módulo de IA y Asistente Minerva
│   ├── Main.qml                  # Conexión IPC con el subproceso backend Python
│   ├── ChatWidget.qml            # Interfaz de chat con streaming de tokens e imágenes
│   ├── CommandApprovalDialog.qml # Modal seguro de aprobación de comandos
│   ├── SettingsPanel.qml         # Ajustes de modelo, temperatura y voz
│   ├── SiriOrb.qml               # Orbe reactivo acelerado por GPU
│   ├── shaders/                  # Fragment shaders GLSL para el SiriOrb
│   ├── main.py                   # Coordinador Python JSON Lines
│   ├── run-backend.sh            # Lanzador del entorno virtual de Python
│   ├── requirements.txt          # Librerías de Python requeridas
│   ├── settings.example.json     # Plantilla para ~/.config/minerva/settings.json
│   ├── voice/                    # Modelos locales de voz (Vosk y Piper)
│   └── backend/                  # Motores de IA, voz, comandos y herramientas
│
├── HyprQuickFrame/               # Herramienta de capturas de pantalla integrada
│   └── ScreenshotTool.qml        # Interfaz de selección de región y guardado
│
├── Caelestia/                    # Módulo QML / Plugin compilado para SQLite y utilidades
└── plugin/                       # Código fuente C++ / CMake del plugin Caelestia
```

---

## ❓ Solución de Problemas

### 1. Los atajos de teclado no abren las ventanas
- Comprueba que Quickshell esté corriendo: `pgrep quickshell`
- Ejecuta manualmente un comando IPC en tu terminal para ver si hay mensajes de error:
  ```bash
  quickshell ipc call shell toggleLauncher
  ```

### 2. Minerva dice "Clave de API no configurada"
- Asegúrate de haber completado el archivo `~/.config/minerva/settings.json` con tu clave de Google Gemini:
  ```bash
  nano ~/.config/minerva/settings.json
  ```
- Verifica que el archivo tenga permisos de lectura para tu usuario (`chmod 600 ~/.config/minerva/settings.json`).

### 3. No se escucha la voz de Minerva o falla el micrófono
- Verifica que tengas instalado el modelo de voz en `Minerva/voice/` ejecutando `./install.sh`.
- Comprueba que tu servidor de sonido (PipeWire / WirePlumber) tenga un micrófono predeterminado activo:
  ```bash
  wpctl status
  ```

### 4. El control de brillo no responde
- Asegúrate de tener instalado `brightnessctl` y de que tu usuario pertenezca al grupo `video` o `input`:
  ```bash
  sudo pacman -S brightnessctl
  sudo usermod -aG video $USER
  ```

---

## 📄 Licencia

Este proyecto está disponible para la comunidad bajo los términos del repositorio. ¡Disfruta de una experiencia moderna y fluida en Hyprland!
