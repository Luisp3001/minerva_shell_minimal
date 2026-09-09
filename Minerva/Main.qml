// Servicio raíz de Minerva para minerva_shell_v2.
// Mantiene una sola instancia del backend y el estado compartido entre pantallas.
import QtQuick
import Quickshell
import Quickshell.Io

Item {
    id: widget

    property var    shellRoot:  null

    // ── Configuración de IA (Gemini es el único motor de texto) ───────────
    readonly property string aiProvider: "Gemini"
    property string geminiApiKey: ""
    property string geminiModel: "gemini-2.5-flash"
    property string aiTemperature: "0.7"

    // ── Configuración de TTS ──────────────────────────────────────────────────────
    property string ttsProvider:  "piper"   // "piper" (local) | "fish" (Fish Audio API) | "gemini" (Gemini TTS)
    property string fishApiKey:   ""
    property string fishVoiceId:  "15e8b140868348538ab2d7d887060e78"
    property string fishModel:    "s2-pro"  // speech-1.5 | speech-1.6 | s2-pro | s1 | s1-mini | agent-x0
    property string geminiTtsVoice: "Kore"                 // Kore, Aoede, Puck, Charon, Zephyr, etc.
    property string geminiTtsModel: "gemini-2.5-flash-tts"  // gemini-2.5-flash-tts | gemini-2.5-pro-tts

    // Los secretos permanecen fuera del repositorio. El formato preferido es
    // ~/.config/minerva/settings.json; durante la transición también se lee la
    // configuración del gestor de plugins del shell anterior.
    property bool _primarySettingsLoaded: false

    function applySettings(settings) {
        if (!settings) return
        if (settings.geminiApiKey !== undefined)   geminiApiKey = settings.geminiApiKey
        if (settings.geminiModel !== undefined)    geminiModel = settings.geminiModel
        if (settings.aiTemperature !== undefined)  aiTemperature = String(settings.aiTemperature)
        if (settings.ttsProvider !== undefined)    ttsProvider = settings.ttsProvider
        if (settings.fishApiKey !== undefined)     fishApiKey = settings.fishApiKey
        if (settings.fishVoiceId !== undefined)    fishVoiceId = settings.fishVoiceId
        if (settings.fishModel !== undefined)      fishModel = settings.fishModel
        if (settings.geminiTtsVoice !== undefined) geminiTtsVoice = settings.geminiTtsVoice
        if (settings.geminiTtsModel !== undefined) geminiTtsModel = settings.geminiTtsModel
    }

    function saveSettings() {
        var data = {
            aiProvider: "Gemini",
            geminiApiKey: widget.geminiApiKey,
            geminiModel: widget.geminiModel,
            aiTemperature: widget.aiTemperature,
            ttsProvider: widget.ttsProvider,
            fishApiKey: widget.fishApiKey,
            fishVoiceId: widget.fishVoiceId,
            fishModel: widget.fishModel,
            geminiTtsVoice: widget.geminiTtsVoice,
            geminiTtsModel: widget.geminiTtsModel
        }
        sendToBackend({ type: "save_settings", settings: data })
        widget._primarySettingsLoaded = true
    }

    FileView {
        id: settingsFile
        path: Quickshell.env("HOME") + "/.config/minerva/settings.json"
        printErrors: false
        onLoaded: {
            try {
                var data = JSON.parse(text())
                widget.applySettings(data["com.luisp.minerva"] || data)
                widget._primarySettingsLoaded = true
            } catch (error) {
                console.warn("Minerva: settings.json no contiene JSON válido")
            }
        }
    }

    FileView {
        path: Quickshell.env("HOME") + "/.config/minerva_shell/plugin_settings.json"
        printErrors: false
        onLoaded: {
            if (widget._primarySettingsLoaded) return
            try {
                var data = JSON.parse(text())
                widget.applySettings(data["com.luisp.minerva"])
                // Migración real: conservar claves, voces y modelos fuera del
                // shell antiguo para que este pueda eliminarse con seguridad.
                Qt.callLater(widget.saveSettings)
            } catch (error) {
                console.warn("Minerva: no se pudieron importar los ajustes heredados")
            }
        }
    }

    // ── Estado del backend ────────────────────────────────────────────────
    property bool   backendReady:  false
    property bool   isThinking:    false
    property bool   isSpeaking:    false
    property bool   hasPendingTasks: false
    property bool   hasUrgentTasks: false
    property string taskUrgency: "low"
    property bool   showPendingOrb: false
    property string lastAISnippet: "Minerva"
    readonly property string modelName: geminiModel
    
    Timer {
        id: pendingOrbTimer
        interval: 20000 // Mostrar el orbe central por 20 segundos
        onTriggered: {
            widget.showPendingOrb = false
            widget._updateMinervaState()
        }
    }

    // ── Estado de la UI persistente ───────────────────────────────────────
    property var    conversationHistory: []
    property string currentUserMsg: ""
    property int    streamingIdx: -1
    property string streamingRaw: ""
    property string pendingCmd: ""
    property string pendingJobId: ""
    property bool   pendingIsSudo: false
    property string pendingReason: ""
    property bool   showConfirm: false
    property var    approvalQueue: []
    property bool   isRecording: false
    property bool   isTranscribing: false
    property string pendingImage: ""
    property string activeRequestId: ""
    property string pendingTokenBuffer: ""
    property int    backendRestartAttempts: 0
    readonly property int maxDisplayMessages: 300
    readonly property int maxHistoryMessages: 80

    ListModel { id: globalMsgModel }
    property alias msgModel: globalMsgModel

    function appendDisplayMessage(message) {
        if (globalMsgModel.count >= maxDisplayMessages) {
            globalMsgModel.remove(
                0,
                globalMsgModel.count - maxDisplayMessages + 1
            )
        }
        globalMsgModel.append(message)
    }


    // ── Señal reenviada a ChatWidget ──────────────────────────────────────
    signal backendMessage(var msg)
    signal attentionRequested()

    // ── Ruta al backend Python ────────────────────────────────────────────
    readonly property string pluginDir:
        Quickshell.shellDir + "/Minerva"

    // ── Proceso backend persistente ───────────────────────────────────────
    Process {
        id: backendProc
        command: [widget.pluginDir + "/run-backend.sh"]
        workingDirectory: widget.pluginDir
        stdinEnabled: true
        running: true

        onStarted: console.info("Minerva: backend iniciado")

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: function(line) {
                var trimmed = line.trim()
                if (!trimmed) return
                try {
                    var parsed = JSON.parse(trimmed)
                    widget.onBackendLine(parsed)
                } catch (error) {
                    console.warn("Minerva: evento JSON inválido en stdout")
                }
            }
        }


        stderr: SplitParser {
            splitMarker: "\n"
            onRead: function(line) {
                var trimmed = line.trim()
                if (!trimmed) return
                if (trimmed.startsWith("LOG (VoskAPI:"))
                    console.debug("Minerva backend: " + trimmed)
                else
                    console.warn("Minerva backend: " + trimmed)
            }
        }

        onExited: function(code) {
            console.warn("Minerva: backend finalizó con código " + code)
            widget.backendReady = false
            widget.isThinking   = false
            widget.backendMessage({ type: "error",
                message: "Backend terminó (código " + code + "). Intentando reiniciar." })
            if (widget.backendRestartAttempts < 3) {
                widget.backendRestartAttempts++
                backendRestartTimer.restart()
            }
        }
    }

    Timer {
        id: backendRestartTimer
        interval: 1500
        repeat: false
        onTriggered: backendProc.running = true
    }

    // ── Proceso de selección de imagen ────────────────────────────────────
    Process {
        id: imageDialogProc
        command: ["zenity", "--file-selection", "--title=Selecciona una imagen", "--file-filter=*.png *.jpg *.jpeg *.webp"]
        running: false
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: function(line) {
                var path = line.trim()
                if (path) {
                    widget.pendingImage = path
                }
            }
        }
    }

    function selectImage() {
        imageDialogProc.running = true
    }

    // ── Comunicación directa con el proceso (JSON Lines por stdin) ────────
    function sendToBackend(obj) {
        if (!backendProc.running || !backendProc.stdinEnabled) {
            widget.isThinking = false
            widget._updateMinervaState()
            widget.backendMessage({
                type: "error",
                message: "El backend no está disponible."
            })
            return false
        }
        backendProc.write(JSON.stringify(obj) + "\n")
        return true
    }

    function nextRequestId() {
        return Date.now().toString(16) + "-" + Math.random().toString(16).slice(2)
    }

    function flushPendingTokens() {
        if (!pendingTokenBuffer) return
        if (streamingIdx === -1) {
            appendDisplayMessage({
                role: "ai", content: "", command: "", cmdStatus: "",
                jobId: "", needsConfirm: false, needsSudo: false, isSystem: false
            })
            streamingIdx = globalMsgModel.count - 1
            streamingRaw = ""
        }
        streamingRaw += pendingTokenBuffer
        pendingTokenBuffer = ""
        globalMsgModel.setProperty(streamingIdx, "content", streamingRaw)
    }

    Timer {
        id: tokenFlushTimer
        interval: 32
        repeat: false
        onTriggered: widget.flushPendingTokens()
    }

    function enqueueApproval(command, jobId, isSudo, reason) {
        var queue = approvalQueue.slice()
        for (var i = 0; i < queue.length; i++) {
            if (queue[i].jobId === jobId) return
        }
        queue.push({
            command: command,
            jobId: jobId,
            isSudo: isSudo,
            reason: reason
        })
        approvalQueue = queue
        if (!showConfirm) activateNextApproval()
    }

    function activateNextApproval() {
        if (approvalQueue.length === 0) {
            showConfirm = false
            pendingCmd = ""
            pendingJobId = ""
            pendingReason = ""
            pendingIsSudo = false
            return
        }
        var approval = approvalQueue[0]
        pendingCmd = approval.command
        pendingJobId = approval.jobId
        pendingIsSudo = approval.isSudo
        pendingReason = approval.reason
        showConfirm = true
    }

    function resolveApproval(jobId) {
        var activeWasResolved = !showConfirm || pendingJobId === jobId
        var queue = []
        for (var i = 0; i < approvalQueue.length; i++) {
            if (approvalQueue[i].jobId !== jobId) queue.push(approvalQueue[i])
        }
        approvalQueue = queue
        if (activeWasResolved) {
            showConfirm = false
            Qt.callLater(widget.activateNextApproval)
        }
    }

    function abandonPendingApprovals() {
        for (var i = 0; i < globalMsgModel.count; i++) {
            var item = globalMsgModel.get(i)
            // Solo cancelar comandos que aún no fueron confirmados (sin proceso real).
            // Los comandos "running" tienen un proceso en ejecución en el backend
            // y se actualizarán solos cuando llegue command_result.
            if (item.role === "command" && item.cmdStatus === "pending") {
                globalMsgModel.setProperty(i, "cmdStatus", "cancelled")
            }
        }
        approvalQueue = []
        showConfirm = false
        pendingCmd = ""
        pendingJobId = ""
        pendingReason = ""
        pendingIsSudo = false
    }

    // ── Helpers para actualizar estado global de voz ───────────────────────
    function _updateMinervaState() {
        if (!widget.shellRoot) return
        var active = widget.isRecording || widget.isTranscribing || widget.isThinking || widget.isSpeaking || widget.showPendingOrb
        widget.shellRoot.minervaActive = active
        if (widget.isRecording)         widget.shellRoot.minervaState = "recording"
        else if (widget.isTranscribing) widget.shellRoot.minervaState = "transcribing"
        else if (widget.isThinking)     widget.shellRoot.minervaState = "thinking"
        else if (widget.isSpeaking)     widget.shellRoot.minervaState = "speaking"
        else if (widget.showPendingOrb) {
            if (widget.hasUrgentTasks || widget.taskUrgency === "urgent")
                widget.shellRoot.minervaState = "urgent_task"
            else if (widget.taskUrgency === "medium")
                widget.shellRoot.minervaState = "pending_task_medium"
            else
                widget.shellRoot.minervaState = "pending_task_low"
        }
        else widget.shellRoot.minervaState = "idle"
    }

    function onBackendLine(msg) {
        if (msg.request_id && activeRequestId
                && msg.request_id !== activeRequestId
                && (msg.type === "token" || msg.type === "done"
                    || msg.type === "error" || msg.type === "cancelled"
                    || msg.type === "tool_start" || msg.type === "tool_result"
                    || msg.type === "run_command"
                    || msg.type === "confirm_required"
                    || msg.type === "sudo_required"
                    || msg.type === "command_start"
                    || msg.type === "command_output"
                    || msg.type === "command_result")) {
            return
        }
        // Actualizar estado del widget
        switch (msg.type) {
            case "tasks_pending":
                hasPendingTasks = true
                taskUrgency = msg.urgency ? msg.urgency : (msg.urgent ? "urgent" : "low")
                hasUrgentTasks = (taskUrgency === "urgent")
                showPendingOrb = true
                pendingOrbTimer.restart()
                _updateMinervaState()
                break
            case "tasks_cleared":
                hasPendingTasks = false
                hasUrgentTasks = false
                taskUrgency = ""
                showPendingOrb = false
                pendingOrbTimer.stop()
                _updateMinervaState()
                break
            case "ready":
                backendReady = true
                backendRestartAttempts = 0
                console.info("Minerva: backend listo (" + (msg.model || "modelo sin nombre") + ")")
                break
            case "token":
                isThinking = true
                _updateMinervaState()
                pendingTokenBuffer += (msg.content || "")
                if (!tokenFlushTimer.running) tokenFlushTimer.start()
                break
            case "done":
                tokenFlushTimer.stop()
                flushPendingTokens()
                isThinking = false
                _updateMinervaState()
                // Guardar en historial si no lo hizo ChatWidget (panel cerrado)
                if (streamingIdx >= 0) {
                    conversationHistory.push(
                        { role: "user",      content: currentUserMsg },
                        { role: "assistant", content: msg.full_response || streamingRaw }
                    )
                    if (conversationHistory.length > maxHistoryMessages) {
                        conversationHistory = conversationHistory.slice(
                            -maxHistoryMessages
                        )
                    }
                    streamingIdx = -1
                    streamingRaw = ""
                }
                // Extraer snippet visible (sin líneas TOOL_CALL)
                if (msg.full_response) {
                    var lines = msg.full_response.split("\n")
                    for (var i = 0; i < lines.length; i++) {
                        var l = lines[i].trim()
                        if (l && !l.startsWith("TOOL_CALL:")) {
                            lastAISnippet = l.length > 40 ? l.substring(0, 40) + "…" : l
                            break
                        }
                    }
                }
                break
            case "error":
                tokenFlushTimer.stop()
                flushPendingTokens()
                if (streamingIdx >= 0) {
                    streamingIdx = -1
                    streamingRaw = ""
                }
                isThinking = false
                _updateMinervaState()
                break
            case "cancelled":
                tokenFlushTimer.stop()
                pendingTokenBuffer = ""
                streamingIdx = -1
                streamingRaw = ""
                isThinking = false
                _updateMinervaState()
                break
            case "run_command":
                isThinking = false
                _updateMinervaState()
                enqueueApproval(
                    msg.command || "",
                    msg.job_id || "",
                    false,
                    "Los comandos de shell requieren aprobación explícita"
                )
                widget.attentionRequested()
                break
            case "confirm_required":
                enqueueApproval(
                    msg.command || "",
                    msg.job_id || "",
                    false,
                    msg.reason || "El comando requiere aprobación explícita"
                )
                isThinking = false
                _updateMinervaState()
                widget.attentionRequested()
                break
            case "sudo_required":
                enqueueApproval(
                    msg.command || "",
                    msg.job_id || "",
                    true,
                    "Este comando requiere permisos de administrador (pkexec)"
                )
                isThinking = false
                _updateMinervaState()
                // La confirmación nunca debe quedar escondida en un panel cerrado.
                widget.attentionRequested()
                break
            case "command_result":
                resolveApproval(msg.job_id || "")
                break
            case "wake_word_detected":
                if (!isRecording) {
                    toggleVoice()
                }
                break
            case "silence_detected":
                if (isRecording) {
                    toggleVoice()
                }
                break
            case "voice_recording_started":
                isRecording = true
                _updateMinervaState()
                break
            case "voice_recording_stopped":
                isRecording = false
                _updateMinervaState()
                break
            case "voice_transcribing":
                isTranscribing = true
                _updateMinervaState()
                break
            case "voice_recognized":
                isRecording = false
                isTranscribing = false
                if (msg.text) {
                    // Simular que el usuario escribió el texto
                    currentUserMsg = msg.text
                    appendDisplayMessage({
                        role: "user", content: msg.text, command: "", cmdStatus: "",
                        needsConfirm: false, needsSudo: false, isSystem: false
                    })
                    sendChat(msg.text, conversationHistory.slice())
                } else {
                    _updateMinervaState()
                }
                break
            case "voice_speaking_started":
                isSpeaking = true
                _updateMinervaState()
                break
            case "voice_speaking_stopped":
                isSpeaking = false
                // Resetear métricas de audio al dejar de hablar
                if (widget.shellRoot) {
                    widget.shellRoot.audioRms   = 0.0
                    widget.shellRoot.audioBand0 = 0.0
                    widget.shellRoot.audioBand1 = 0.0
                    widget.shellRoot.audioBand2 = 0.0
                    widget.shellRoot.audioBand3 = 0.0
                }
                _updateMinervaState()
                break
            case "audio_data":
                // Métricas de audio en tiempo real → Minerva_waveform shader
                if (widget.shellRoot) {
                    widget.shellRoot.audioRms   = msg.rms   || 0.0
                    widget.shellRoot.audioBand0 = msg.band0 || 0.0
                    widget.shellRoot.audioBand1 = msg.band1 || 0.0
                    widget.shellRoot.audioBand2 = msg.band2 || 0.0
                    widget.shellRoot.audioBand3 = msg.band3 || 0.0
                }
                break
        }
        // Reenviar a ChatWidget
        widget.backendMessage(msg)
    }

    function sendChat(message, history) {
        if (isRecording) { toggleVoice() }
        abandonPendingApprovals()
        isThinking = true
        _updateMinervaState()
        activeRequestId = nextRequestId()
        sendToBackend({
            type: "chat", 
            request_id: activeRequestId,
            message: message, 
            history: history,
            image: widget.pendingImage,
            settings: {
                provider:       "Gemini",
                gemini_api_key: widget.geminiApiKey,
                gemini_model:   widget.geminiModel,
                temperature:    widget.aiTemperature,
                tts_provider:     widget.ttsProvider,
                fish_api_key:     widget.fishApiKey,
                fish_voice_id:    widget.fishVoiceId,
                fish_model:       widget.fishModel,
                gemini_tts_voice: widget.geminiTtsVoice,
                gemini_tts_model: widget.geminiTtsModel
            }
        })
        widget.pendingImage = ""
    }

    function confirmRun(cmd, jobId) { sendToBackend({ type: "run_confirmed", job_id: jobId || "", command: cmd }) }
    function cancelRun()            { sendToBackend({ type: "cancel" }) }
    function sudoRun(cmd, jobId)    { sendToBackend({ type: "run_sudo",      job_id: jobId || "", command: cmd }) }
    function cancelJob(jobId)       { sendToBackend({ type: "job_cancelled", job_id: jobId || "" }) }
    function toggleVoice()          { sendToBackend({ type: "toggle_voice" }) }
    function stopTTS()              { sendToBackend({ type: "stop_tts" }) }

    // ── IPC Handler (qs ipc call minerva) ─────────────────────────────────
    IpcHandler {
        target: "minerva"
        function status(): string {
            return JSON.stringify({
                ready: widget.backendReady,
                provider: widget.aiProvider,
                model: widget.modelName,
                recording: widget.isRecording,
                thinking: widget.isThinking,
                speaking: widget.isSpeaking
            })
        }
        function toggle_voice(): string {
            widget.toggleVoice()
            return widget.isRecording ? "Grabación de voz detenida" : "Iniciando grabación de voz..."
        }
        function stop_tts(): string {
            widget.stopTTS()
            return "Voz detenida"
        }
    }
}
