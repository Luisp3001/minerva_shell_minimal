#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Definiciones de herramientas y system prompt de Minerva.
"""
from ..core.config import HOME

# ─────────────────────────────────────────────────────────────────────────────
# System prompt
# ─────────────────────────────────────────────────────────────────────────────
SYSTEM_PROMPT = f"""Eres Minerva, una asistente inteligente integrada en el escritorio del usuario. Tu nombre viene de la diosa romana de la sabiduría.

## Tu personalidad
- Eres directa, eficiente y con un toque de ingenio sutil. No eres fría ni robótica — eres como una amiga técnica que sabe mucho.
- Respondes de forma natural y concisa. Nada de relleno.
- Tienes sentido del humor ligero cuando la situación lo permite, pero nunca forzado.

## Reglas CRÍTICAS de comunicación
- **NUNCA narres tus acciones.** No digas cosas como "Voy a ejecutar el siguiente comando", "Procederé a realizar esta acción", "Para hacer esto necesito ejecutar...", "Primero voy a verificar...". Simplemente HAZLO. Usa las herramientas directamente sin anunciarlas.
- Si el usuario te pide algo, actúa primero y después explica brevemente el resultado si es necesario.
- No hagas preguntas innecesarias. Si puedes resolver algo con la información disponible, hazlo.
- Sé breve. Las respuestas largas y redundantes aburren. Ve al grano.
- **NUNCA uses formato markdown (como asteriscos, negritas o cursivas).** El usuario te escucha a través de voz y los símbolos se leerían en voz alta (ej: "asterisco hola asterisco"). Genera solo texto plano.

## Herramientas disponibles
- **Filesystem**: Puedes listar directorios (list_dir), leer archivos (read_file, read_pdf, read_docx, read_pptx, read_excel), inspeccionar metadatos (file_info), crear/sobreescribir archivos (write_file), crear documentos Word desde markdown (create_docx), modificar documentos Word añadiendo texto (modify_docx) y editar líneas específicas (replace_lines) dentro de {HOME}. IMPORTANTE: Para cualquier archivo PDF, DOCX, PPTX o Excel usa SIEMPRE la herramienta específica. Si debes crear o modificar Word, llama directamente a create_docx o modify_docx: NUNCA escribas ni ejecutes un script Python, ni uses run_command, Bash o LibreOffice para sustituir esas herramientas. create_docx ya aplica una plantilla editorial cuidada y acepta Markdown internamente aunque tus respuestas al usuario sean texto plano. Para archivos grandes de texto, primero usa file_info para conocer el total de líneas, luego lee con read_file en bloques (start_line, end_line) de hasta 200 líneas. Usa replace_lines para ediciones quirúrgicas sin reescribir el archivo completo. Si intentas leer o editar más allá del final del archivo, recibirás una señal [EOF]. Para buscar información concreta dentro de un PDF/DOCX/PPTX largo sin leerlo completo, usa query_document con una pregunta específica (RAG efímero). Para MD/TXT usa read_file; para Excel/CSV usa read_excel.
- **Comandos**: Puedes proponer comandos bash con run_command. Todos requieren confirmación explícita del usuario; los que usan sudo se autentican con pkexec. Tras aprobarse, se ejecutan en segundo plano de forma asíncrona y puedes usar check_job_status para consultar su estado, salida y código de retorno.
- **Búsqueda web** (web_search): Tienes acceso a internet en tiempo real. Úsala cuando:
  - El usuario pregunte por noticias, eventos recientes o información que puede haber cambiado.
  - Necesites precios, versiones de software, estadísticas actuales, o cualquier dato perecedero.
  - Tu conocimiento interno pueda estar desactualizado.
  - Te pregunten "¿cuál es la última versión de...?", "¿qué pasó con...?", "precio de...", etc.
  - NO la uses para información atemporal o conceptual que ya conoces.
- **Memoria a largo plazo** (update_memory): Tienes acceso a dos archivos de memoria en texto plano que puedes leer y escribir: 'user_profile.md' (datos estables del usuario: nombre, entorno, proyectos) y 'preferences.md' (preferencias configurables: lenguajes, herramientas, estilo).
  - ERES PROACTIVA: Usa esta herramienta POR TU CUENTA sin pedir permiso, CADA VEZ que el usuario mencione preferencias, datos personales, su entorno de trabajo, gustos, o contexto importante de sus proyectos.
  - NO esperes a que el usuario te diga "recuerda esto". Si notas información que podría ser útil a largo plazo, guárdala usando esta herramienta.
  - Usa file_key='profile' para datos personales y del entorno; usa file_key='preferences' para preferencias de herramientas, lenguajes o estilo.
  - El contenido de ambos archivos ya se inyecta automáticamente en tu contexto al inicio de cada sesión.
- **Captura de pantalla** (capture_screen): Toma una captura de pantalla en tiempo real para ver exactamente lo que el usuario tiene en su monitor. Usala cuando:
  - El usuario te pida analizar, describir o evaluar lo que hay en su pantalla.
  - Necesites contexto visual para responder (ej: "que ves en mi pantalla", "que app tengo abierta", "mira esto", "que dice ahi").
  - El usuario quiera que compruebes algo visual sin tener que describirlo.
  - Opcionalmente puedes especificar el nombre del monitor (output) si el usuario lo indica.
- **Generación de imágenes** (generate_image): Genera una imagen a partir de una descripción usando un modelo.
  - Usa esto SIEMPRE que el usuario te pida generar, crear, o dibujar una imagen.
  - Si el usuario menciona una resolución como "2K", pásala al parámetro `resolution`. Por defecto usa "1K".
  - IMPORTANTE: Cuando uses esta herramienta y te devuelva un código markdown (ej: ![Imagen Generada](/ruta/..)), TIENES QUE INCLUIR esa cadena tal cual en tu respuesta final. De lo contrario el usuario no verá la imagen.
- **Control de Hyprland** (hyprland_control): Controla el escritorio Hyprland. Úsala cuando el usuario te pida navegar entre workspaces o mover ventanas. Acciones disponibles:
  - "switch_workspace": Ir a un workspace específico. Requiere "workspace" (número 1-10). Ej: "muévete al workspace 2", "cambia al workspace 3".
  - "move_window": Mover una ventana a otro workspace. Requiere "workspace" y "window_query" (nombre de la app, como "Spotify", "firefox", "kitty"). Ej: "mueve Spotify al workspace 1", "pon Firefox en el workspace 4".
  - "list_windows": Listar todas las ventanas abiertas con su workspace actual. Útil para saber qué hay abierto antes de mover cosas.
  - Usa "list_windows" si no sabes exactamente el nombre de la ventana antes de moverla.
- **Spotify** (spotify_music): Controla Spotify del usuario. Acciones disponibles:
  - "search": Buscar canciones, artistas, albums o playlists. Requiere "query".
  - "play": Reproducir. Puedes pasar un "uri" de Spotify o un "query" para buscar y reproducir directamente.
  - "pause": Pausar la reproduccion actual.
  - "resume": Reanudar la reproduccion.
  - "next": Saltar a la siguiente cancion.
  - "previous": Volver a la cancion anterior.
  - "volume": Cambiar volumen. Requiere "volume" (0-100).
  - "current": Ver que se esta reproduciendo ahora.
  - "queue": Agregar una cancion a la cola. Usa "uri" o "query".
  - Si el usuario pide musica de un artista o cancion especifica, usa "play" con query directamente.
  - Requiere Spotify Premium para controles de reproduccion.
- **Gestión de Tareas** (manage_tasks): Tienes acceso a una base de datos de tareas pendientes del usuario (PostgreSQL). ES TU UNICA FUENTE DE VERDAD para todo lo relacionado con tareas, pendientes y fechas de cobro o vencimiento.
  - "add": Agregar una tarea. Requiere "description" y opcionalmente "due_date" (formato YYYY-MM-DD HH:MM:SS). Para tareas que se repiten, usa "recurrence" ('daily', 'weekly', 'monthly', 'yearly'), "recurrence_day" (ej: 11 para "el día 11 de cada mes") y "recurrence_month" (1-12, para fijar un mes específico en tareas 'yearly').
  - "complete": Marcar como completada. Requiere "task_id".
  - "list": Listar tareas pendientes con su due_date, recurrencia, day y month. USA ESTA ACCION SIEMPRE que el usuario pregunte por sus tareas, pendientes, "¿cuánto falta para X?", "¿cuándo es el próximo cobro?", "¿qué tengo pendiente?", o cualquier pregunta sobre fechas de vencimiento. NO uses run_command ni web_search para responder sobre tareas.
  - "edit": Modificar una tarea existente. Requiere "task_id" y los campos que deseas actualizar ("description", "due_date", "recurrence", "recurrence_day", "recurrence_month"). Para quitar la fecha o recurrencia pasa 'none'.
  - "delete": Eliminar una tarea. Requiere "task_id". REGLA DE SEGURIDAD CRÍTICA: NUNCA uses confirm=true en tu primera llamada; llama primero con confirm=false (o sin él) para obtener los detalles de la tarea, muéstraselos al usuario y pídele confirmación expresa en el chat. Solo cuando el usuario confirme explícitamente que desea borrarla, llama de nuevo con confirm=true.
  - "clear_completed": Limpiar del historial todas las tareas completadas que no sean recurrentes. Las tareas periódicas se conservan intactas para su auto-renovación.
  - El sistema te inyectará automáticamente las tareas pendientes en tu prompt, así que **puedes ser proactiva** y recordarle al usuario sus tareas de manera casual si es un buen momento.
- **Estado de comandos en segundo plano** (check_job_status): Consulta el estado y salida de comandos bash ejecutados con run_command. Úsala cuando:
  - El usuario pregunte "¿cómo va el comando?", "¿terminó el sleep?", "¿hay algo corriendo?", "¿qué pasó con la descarga?", o similar.
  - Quieras comprobar el resultado de un comando reciente antes de responder algo.
  - Si no sabes el job_id, llámala sin argumentos para listar todos los comandos registrados en esta sesión.

## Reglas de seguridad
- Solo puedes acceder a archivos dentro de {HOME}
- Todos los comandos de shell pedirán confirmación explícita al usuario
- Los comandos con sudo usarán pkexec (polkit) para autenticación gráfica
- Nunca inventes el contenido de archivos; usa read_file si necesitas ver uno
- Responde siempre en el idioma que use el usuario

## Contexto del sistema
- Home del usuario: {HOME}
- Sistema operativo: Arch Linux
- Shell: bash
- Fecha/hora actual: {{fecha_actual}}
"""
# ─────────────────────────────────────────────────────────────────────────────
# Emotion tags para Fish Audio TTS
# Se inyecta al system prompt solo cuando ttsProvider == "fish"
# ─────────────────────────────────────────────────────────────────────────────
FISH_AUDIO_EMOTION_PROMPT = """
## Expresión emocional con voz (Fish Audio)
Estás usando un motor de síntesis de voz que soporta emotion tags. Úsalos para dar vida a tus respuestas — la IA que te escucha suena muchísimo más natural cuando expresas emociones adecuadas.

Cómo usar los emotion tags:
- Pon el tag al INICIO de la oración o fragmento en el que aplica.
- Solo usa UN tag por fragmento. Si la emoción cambia en mitad de la respuesta, inicia un nuevo fragmento con su tag.
- Los tags NO se muestran al usuario en el chat, solo guían la entonación del sintetizador de voz.
- Usa SIEMPRE el tag que mejor refleje el tono natural de ese fragmento.

Tags disponibles (usa solo estos, en minúsculas y con corchetes):
- [happy]       — buenas noticias, tono positivo, alegre o cálido.
- [sad]         — algo salió mal, condolencias, tristeza o desánimo.
- [angry]       — tono firme, molesto, enfadado o de advertencia.
- [excited]     — entusiasmo, emoción, celebraciones o energía alta.
- [calm]        — tono tranquilo, sereno, pausado o pacífico.
- [nervous]     — duda, incertidumbre, vacilación o inquietud ligera.
- [confident]   — seguridad, determinación, firmeza o convicción.
- [surprised]   — asombro, sorpresa o extrañeza ante algo inesperado.
- [disgusted]   — desagrado, repulsión o rechazo.

Ejemplos correctos:
[happy] Tu carpeta fue creada exitosamente.
[excited] Encontré exactamente lo que buscabas.
[sad] Parece que el proceso falló. Revisemos juntos.
[surprised] No esperaba encontrar esto aquí.
[confident] No te preocupes, resolveremos esto rápidamente.

REGLA: toda respuesta debe comenzar con al menos un emotion tag. Si una respuesta tiene varias oraciones con tonos distintos, usa un tag por fragmento.
"""


TOOL_DEFINITIONS = [
    {
        "type": "function",
        "function": {
            "name": "list_dir",
            "description": "Lista el contenido de un directorio en el sistema de archivos",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "La ruta absoluta del directorio a listar"
                    }
                },
                "required": ["path"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "read_file",
            "description": "Lee el contenido de texto de un archivo en el sistema por rangos de líneas. Por defecto lee las primeras 200 líneas. Para archivos grandes, usa file_info primero para conocer el total de líneas y luego llama a read_file con start_line y end_line para leer en chunks. Si start_line supera el total de líneas, retorna [EOF].",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "La ruta absoluta del archivo a leer"
                    },
                    "start_line": {
                        "type": "integer",
                        "minimum": 1,
                        "description": "Línea inicial a leer (1-indexado). Por defecto 1."
                    },
                    "end_line": {
                        "type": "integer",
                        "minimum": 1,
                        "description": "Última línea a leer (1-indexado, inclusivo). Por defecto start_line + 199 (chunk de 200 líneas)."
                    }
                },
                "required": ["path"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "file_info",
            "description": "Devuelve metadatos de un archivo: total de líneas y tamaño en disco. Úsala antes de read_file cuando el archivo pueda ser grande, para saber cuántas líneas tiene y decidir qué rango pedir.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "La ruta absoluta del archivo a inspeccionar"
                    }
                },
                "required": ["path"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "create_docx",
            "description": "Crea directamente un archivo de Microsoft Word (.docx) elegante a partir de Markdown. Aplica automáticamente hoja tamaño Carta, tipografía editorial, texto justificado con espaciado cómodo, títulos sobrios, márgenes equilibrados, citas, tablas y paginación. Úsala siempre para crear Word: no generes scripts Python ni uses run_command como sustituto.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Ruta absoluta donde se guardará el archivo .docx."
                    },
                    "markdown_content": {
                        "type": "string",
                        "description": "Contenido estructurado en Markdown que se convertirá a Word. Puedes usar un bloque YAML inicial con title, subtitle, author y date para una portada tipográfica más cuidada."
                    },
                    "overwrite": {
                        "type": "boolean",
                        "description": "Si true, reemplaza un DOCX existente. Por defecto false."
                    }
                },
                "required": ["path", "markdown_content"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "modify_docx",
            "description": "Añade Markdown al final de un archivo de Microsoft Word (.docx) existente conservando su estilo visual, márgenes, encabezados y pies. Úsala siempre para ampliar Word: no generes scripts Python ni uses run_command como sustituto.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Ruta absoluta del archivo .docx existente."
                    },
                    "instruction": {
                        "type": "string",
                        "description": "Texto a añadir al final del documento."
                    }
                },
                "required": ["path", "instruction"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "write_file",
            "description": "Crea un archivo nuevo o sobreescribe uno existente con el contenido proporcionado. Usa esta herramienta en lugar de 'echo' o redirecciones de shell para crear archivos. Por defecto falla si el archivo ya existe para evitar sobreescrituras accidentales; pasa overwrite=true para sobreescribir intencionalmente.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Ruta absoluta del archivo a crear o sobreescribir"
                    },
                    "content": {
                        "type": "string",
                        "description": "Contenido completo a escribir en el archivo"
                    },
                    "overwrite": {
                        "type": "boolean",
                        "description": "Si true, sobreescribe el archivo si ya existe. Por defecto false."
                    }
                },
                "required": ["path", "content"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "replace_lines",
            "description": "Reemplaza un rango de líneas específicas en un archivo existente sin tocar el resto. Equivalente a un patch quirúrgico. Ideal para editar funciones, corregir errores o modificar configuraciones sin reescribir el archivo completo. Usará el número de línea exacto que viste con read_file.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Ruta absoluta del archivo a modificar"
                    },
                    "start_line": {
                        "type": "integer",
                        "minimum": 1,
                        "description": "Primera línea a reemplazar (1-indexado, inclusivo)"
                    },
                    "end_line": {
                        "type": "integer",
                        "minimum": 1,
                        "description": "Última línea a reemplazar (1-indexado, inclusivo)"
                    },
                    "new_content": {
                        "type": "string",
                        "description": "Texto de reemplazo. Puede contener múltiples líneas separadas por \\n."
                    }
                },
                "required": ["path", "start_line", "end_line", "new_content"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "read_pdf",
            "description": "Lee y extrae el contenido de archivos PDF. Úsala cuando el usuario pida abrir, leer, revisar o consultar documentos PDF. NO uses run_command para esto.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "La ruta absoluta del archivo PDF a leer"
                    }
                },
                "required": ["path"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "read_docx",
            "description": "Lee y extrae el texto de documentos de Word (DOCX, DOC). Úsala cuando el usuario pida abrir, leer, consultar o analizar documentos de texto o formato Word. NO uses run_command para esto.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "La ruta absoluta del archivo DOCX a leer"
                    }
                },
                "required": ["path"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "read_pptx",
            "description": "Lee y extrae el contenido de presentaciones de PowerPoint o diapositivas (PPTX, PPT). Úsala cuando el usuario pida abrir, leer, revisar o resumir diapos, presentaciones, filminas o archivos .pptx. NO uses run_command para esto.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "La ruta absoluta del archivo PPTX a leer"
                    }
                },
                "required": ["path"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "read_excel",
            "description": "Lee y extrae el contenido de archivos de Excel (XLSX, XLS), libros, hojas de cálculo, datos o tablas CSV. Úsala cuando el usuario pida abrir, leer, consultar o revisar hojas de cálculo, tablas, matrices o archivos .xlsx/.csv. NO uses run_command para esto.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "La ruta absoluta del archivo Excel o CSV a leer"
                    }
                },
                "required": ["path"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "run_command",
            "description": "Ejecuta un comando de bash en el sistema. NO la uses para leer o inspeccionar archivos (PDF, Word, Excel, PowerPoint, texto), listar directorios ni crear o modificar DOCX mediante scripts Python; usa siempre las herramientas específicas como create_docx, modify_docx, read_excel, read_pptx, read_docx, read_pdf o read_file.",
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {
                        "type": "string",
                        "description": "El comando de bash a ejecutar"
                    }
                },
                "required": ["command"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "web_search",
            "description": "Busca información actualizada en internet usando DuckDuckGo. Úsala para noticias, versiones de software, precios, eventos recientes, o cualquier información que pueda haber cambiado desde tu entrenamiento.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "La consulta de búsqueda en lenguaje natural o palabras clave"
                    },
                    "max_results": {
                        "type": "integer",
                        "minimum": 1,
                        "maximum": 10,
                        "description": "Número máximo de resultados a devolver (1-10, por defecto 5)"
                    }
                },
                "required": ["query"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "spotify_music",
            "description": "Controla Spotify: buscar musica, reproducir, pausar, saltar cancion, volumen, ver que suena. Requiere Spotify Premium para reproduccion.",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {
                        "type": "string",
                        "description": "La accion a realizar: 'search', 'play', 'pause', 'resume', 'next', 'previous', 'volume', 'current', 'queue'",
                        "enum": ["search", "play", "pause", "resume", "next", "previous", "volume", "current", "queue"]
                    },
                    "query": {
                        "type": "string",
                        "description": "Texto de busqueda (para 'search', 'play', 'queue'). Ej: 'Bohemian Rhapsody Queen'"
                    },
                    "uri": {
                        "type": "string",
                        "description": "URI de Spotify (ej: 'spotify:track:xxx'). Opcional si se proporciona query."
                    },
                    "search_type": {
                        "type": "string",
                        "description": "Tipo de busqueda: 'track', 'artist', 'album', 'playlist'. Por defecto 'track'.",
                        "enum": ["track", "artist", "album", "playlist"]
                    },
                    "volume": {
                        "type": "integer",
                        "minimum": 0,
                        "maximum": 100,
                        "description": "Nivel de volumen 0-100 (solo para accion 'volume')"
                    }
                },
                "required": ["action"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "update_memory",
            "description": "Actualiza la memoria permanente del asistente. Hay dos archivos: 'profile' para datos del usuario (nombre, entorno, proyectos) y 'preferences' para preferencias (lenguajes, herramientas, estilo). Cada archivo tiene secciones con cabeceras; puedes crear nuevas o reemplazar el contenido de las existentes.",
            "parameters": {
                "type": "object",
                "properties": {
                    "file_key": {
                        "type": "string",
                        "description": "Archivo de destino: 'profile' (user_profile.md, para datos personales y del entorno) o 'preferences' (preferences.md, para preferencias configurables).",
                        "enum": ["profile", "preferences"]
                    },
                    "section": {
                        "type": "string",
                        "description": "Nombre de la sección a crear o actualizar (ej: 'Lenguajes de Programación', 'Editor Favorito', 'Proyectos Activos'). No incluyas los símbolos ##."
                    },
                    "content": {
                        "type": "string",
                        "description": "Contenido a guardar bajo esa sección. Puede ser texto libre o una lista con guiones (- item). Reemplaza completamente el contenido previo de la sección."
                    }
                },
                "required": ["file_key", "section", "content"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "launch_app",
            "description": "Busca y abre una aplicación gráfica en el sistema (ej: navegador, discord, spotify, calculadora). Entiende sinónimos y categorías.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "El nombre, sinónimo o tipo de aplicación a abrir (ej: 'discord', 'navegador', 'vesktop')"
                    }
                },
                "required": ["query"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "capture_screen",
            "description": "Toma una captura de pantalla en tiempo real para ver lo que el usuario tiene en su monitor. Úsala cuando el usuario pida analizar, describir o evaluar su pantalla, o cuando necesites contexto visual.",
            "parameters": {
                "type": "object",
                "properties": {
                    "output": {
                        "type": "string",
                        "description": "Nombre del monitor Wayland a capturar (ej: 'DP-1', 'HDMI-A-1'). Omite este parámetro para capturar toda la pantalla."
                    }
                }
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "generate_image",
            "description": "Genera una imagen a partir de un texto (prompt). IMPORTANTE: Si la herramienta te devuelve un código markdown con la imagen (ej: ![Imagen...](/ruta/...)), DEBES incluir esa misma cadena markdown textualmente en tu respuesta final al usuario para que pueda ver la imagen en su pantalla. De lo contrario, no verá nada.",
            "parameters": {
                "type": "object",
                "properties": {
                    "prompt": {
                        "type": "string",
                        "description": "Descripción detallada de la imagen que quieres generar."
                    },
                    "resolution": {
                        "type": "string",
                        "description": "Resolución de la imagen. Puede ser '1K' o '2K'. Por defecto es '1K'. Si el usuario pide explícitamente alta resolución o 2K, usa '2K'.",
                        "enum": ["1K", "2K"]
                    }
                },
                "required": ["prompt"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "query_document",
            "description": "Busca información específica dentro de un documento grande (PDF, DOCX, PPTX) usando RAG semántico efímero. Úsala cuando el usuario pregunte algo concreto sobre el contenido de un documento sin necesitar leerlo completo (ej: '¿qué dice el contrato sobre garantías?', 'busca en el PDF la sección de precios', 'encuentrame los requisitos en el documento'). NO soporta Excel/XLSX/CSV (usa read_excel) ni archivos de texto plano como .md o .txt (para esos usa read_file con start_line/end_line). Para leer un documento completo sin consulta específica, usa read_pdf, read_docx o read_pptx.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Ruta absoluta del documento a consultar (PDF, DOCX o PPTX)"
                    },
                    "query": {
                        "type": "string",
                        "description": "La pregunta o búsqueda semántica a resolver dentro del documento. Sé específico para obtener mejores resultados."
                    },
                    "top_k": {
                        "type": "integer",
                        "minimum": 1,
                        "maximum": 10,
                        "description": "Número de fragmentos relevantes a devolver (1-10, por defecto 5). Usa menos si quieres respuestas más precisas; más si el contexto puede estar disperso."
                    }
                },
                "required": ["path", "query"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "manage_tasks",
            "description": "Gestiona las tareas del usuario en PostgreSQL. Úsala como fuente de verdad para responder CUALQUIER pregunta sobre tareas, pendientes, fechas de vencimiento, cobros o recordatorios. Soporta añadir, completar, listar pendientes, editar, eliminar con confirmación y limpiar tareas completadas no recurrentes.",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {
                        "type": "string",
                        "description": "La acción a realizar: 'add', 'complete', 'list', 'edit', 'delete', 'clear_completed'",
                        "enum": ["add", "complete", "list", "edit", "delete", "clear_completed"]
                    },
                    "description": {
                        "type": "string",
                        "description": "Descripción de la tarea a añadir o nuevo texto al editar (para 'add' o 'edit')"
                    },
                    "task_id": {
                        "type": "integer",
                        "minimum": 1,
                        "description": "ID de la tarea a completar, editar o eliminar (para 'complete', 'edit', 'delete')"
                    },
                    "due_date": {
                        "type": "string",
                        "description": "Fecha y hora límite de la tarea en formato YYYY-MM-DD HH:MM:SS (opcional para 'add' o 'edit'). Para quitar la fecha en 'edit' pasa 'none'."
                    },
                    "recurrence": {
                        "type": "string",
                        "description": "Frecuencia de repetición de la tarea (para 'add' o 'edit'). Valores: 'daily' (diaria), 'weekly' (semanal), 'monthly' (mensual), 'yearly' (anual). Para quitar la recurrencia al editar usa 'none'.",
                        "enum": ["daily", "weekly", "monthly", "yearly", "none"]
                    },
                    "recurrence_day": {
                        "type": "integer",
                        "minimum": 0,
                        "maximum": 31,
                        "description": "Día de anclaje para la recurrencia (para 'add' o 'edit'). Para 'monthly'/'yearly': día del mes (1-31). Para 'weekly': día de la semana (0=lunes, 1=martes, ..., 6=domingo)."
                    },
                    "recurrence_month": {
                        "type": "integer",
                        "minimum": 1,
                        "maximum": 12,
                        "description": "Mes de anclaje para la recurrencia (para 'add' o 'edit' con 'yearly'). Mes del año (1-12)."
                    },
                    "confirm": {
                        "type": "boolean",
                        "description": "Confirmación explícita para eliminar una tarea (solo para 'delete'). Si es false o se omite, la herramienta devolverá los datos de la tarea para solicitar confirmación al usuario antes de borrarla definitivamente."
                    }
                },
                "required": ["action"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "hyprland_control",
            "description": "Controla el escritorio Hyprland: cambia de workspace, mueve ventanas entre workspaces o lista las ventanas abiertas. Úsala cuando el usuario diga cosas como 'muévete al workspace 2', 'cambia al espacio de trabajo 3', 'mueve Spotify al workspace 1', 'pon Firefox en el workspace 4', o 'qué ventanas tengo abiertas'. NO uses run_command para esto.",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {
                        "type": "string",
                        "description": "La acción a realizar: 'switch_workspace' (ir a un workspace), 'move_window' (mover una ventana a un workspace), 'list_windows' (listar ventanas abiertas con su workspace actual).",
                        "enum": ["switch_workspace", "move_window", "list_windows"]
                    },
                    "workspace": {
                        "type": "integer",
                        "minimum": 1,
                        "maximum": 10,
                        "description": "Número del workspace de destino (1-10). Requerido para 'switch_workspace' y 'move_window'."
                    },
                    "window_query": {
                        "type": "string",
                        "description": "Nombre (o parte del nombre) de la clase o título de la ventana a mover. Ej: 'Spotify', 'firefox', 'kitty', 'discord'. Solo para 'move_window'."
                    }
                },
                "required": ["action"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "check_job_status",
            "description": "Consulta el estado y la salida de comandos bash ejecutados en segundo plano (run_command). Úsala cuando el usuario pregunte '¿cómo va el comando?', '¿terminó?', '¿qué está corriendo?', '¿hay procesos en curso?', o cuando necesites saber el resultado de un run_command reciente. Si no tienes el job_id, llámala sin argumentos para ver todos los comandos de la sesión.",
            "parameters": {
                "type": "object",
                "properties": {
                    "job_id": {
                        "type": "string",
                        "description": "ID completo del job a consultar (32 caracteres hexadecimales). Si se omite, se listan todos los comandos registrados en la sesión."
                    }
                }
            }
        }
    }
]


# Gemini acepta JSON Schema. Rechazar campos inventados reduce ambigüedad y
# evita que argumentos inesperados lleguen accidentalmente a los handlers.
for _tool in TOOL_DEFINITIONS:
    _tool["function"]["parameters"]["additionalProperties"] = False
