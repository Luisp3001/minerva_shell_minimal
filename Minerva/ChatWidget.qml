// Interfaz de chat de Minerva para la isla dinámica.
// Recibe mensajes del backend vía señal aiWidget.backendMessage y renderiza
// burbujas de chat, tarjetas de comandos y diálogo de confirmación.
import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Qt.labs.folderlistmodel

Item {
    id: root

    // Referencia al servicio Main.qml compartido por todas las pantallas.
    property var aiWidget: null
    property bool settingsOpen: false
    readonly property int settingsImplicitHeight: settingsPanel.contentHeight
    signal closeRequested()

    function takeFocus() {
        if (settingsOpen) settingsPanel.forceActiveFocus()
        else inputField.forceActiveFocus()
    }

    function closeSettings() {
        settingsOpen = false
        Qt.callLater(inputField.forceActiveFocus)
    }

    onVisibleChanged: {
        if (visible) Qt.callLater(root.takeFocus)
    }

    // ── Estado de la conversación y del diálogo ───────────────────────────
    // Ahora todo el estado reside en aiWidget (Main.qml) para persistencia.
    // Solo referenciamos sus propiedades.

    // ── Escuchar mensajes del backend ─────────────────────────────────────
    Connections {
        target: root.aiWidget
        function onBackendMessage(msg) { root.handleMsg(msg) }
    }

    // ── Autocomplete properties ───────────────────────────────────────────
    property bool showSuggestions: false
    property string currentSearchDir: ""
    property string currentSearchFilter: ""
    property int currentCursorStart: -1
    property int currentCursorEnd: -1
    property var pathAliases: ({})

    FolderListModel {
        id: fileSuggestionModel
        folder: root.currentSearchDir ? "file://" + root.currentSearchDir : ""
        showDirsFirst: true
        onStatusChanged: {
            if (status === FolderListModel.Ready) root.updateFuzzyList()
        }
        onCountChanged: root.updateFuzzyList()
    }

    ListModel {
        id: fuzzySuggestionsModel
    }

    function fuzzyMatch(str, pattern) {
        if (!pattern) return true
        pattern = pattern.toLowerCase()
        str = str.toLowerCase()
        var patternIdx = 0
        var strIdx = 0
        while (patternIdx < pattern.length && strIdx < str.length) {
            if (pattern[patternIdx] === str[strIdx]) {
                patternIdx++
            }
            strIdx++
        }
        return patternIdx === pattern.length
    }

    function updateFuzzyList() {
        fuzzySuggestionsModel.clear()
        if (!root.showSuggestions) return
        var filter = root.currentSearchFilter
        var maxResults = 15
        for (var i = 0; i < fileSuggestionModel.count; i++) {
            if (fuzzySuggestionsModel.count >= maxResults) break
            var fileName = fileSuggestionModel.get(i, "fileName")
            var isDir = fileSuggestionModel.get(i, "fileIsDir")
            if (fileName === "." || fileName === "..") continue
            
            if (filter === "" || fuzzyMatch(fileName, filter)) {
                fuzzySuggestionsModel.append({
                    "fileName": fileName,
                    "isDir": isDir
                })
            }
        }
        if (fuzzySuggestionsModel.count > 0 && suggestionsList.currentIndex < 0) {
            suggestionsList.currentIndex = 0
        }
    }

    function checkAutocomplete() {
        var text = inputField.text
        var cpos = inputField.cursorPosition
        
        var start = -1
        var mode = 0 
        for (var i = cpos - 1; i >= 0; i--) {
            if (text[i] === ']' || text[i] === ' ' || text[i] === '\n') {
                break
            }
            if (text[i] === '@') {
                if (i < text.length - 1 && text[i+1] === '[') {
                    start = i
                    mode = 2
                    break
                }
                start = i
                mode = 1
                break
            }
        }

        if (start !== -1) {
            var prefixLen = (mode === 2) ? 2 : 1
            var searchStr = text.substring(start + prefixLen, cpos)
            
            var dir = Quickshell.env("HOME")
            var filter = searchStr
            
            if (searchStr.indexOf('/') !== -1) {
                var lastSlash = searchStr.lastIndexOf('/')
                var subDir = searchStr.substring(0, lastSlash)
                if (subDir.startsWith("/")) {
                    dir = subDir
                } else if (subDir.startsWith("~")) {
                    dir = Quickshell.env("HOME") + subDir.substring(1)
                } else {
                    dir = Quickshell.env("HOME") + "/" + subDir
                }
                filter = searchStr.substring(lastSlash + 1)
            } else if (searchStr.startsWith("~")) {
                dir = Quickshell.env("HOME")
                filter = searchStr.substring(1)
            } else if (searchStr.startsWith("/")) {
                dir = "/"
                filter = searchStr.substring(1)
            }
            
            root.currentSearchDir = dir
            root.currentSearchFilter = filter
            root.currentCursorStart = start
            root.currentCursorEnd = cpos
            root.showSuggestions = true
            root.updateFuzzyList()
        } else {
            root.showSuggestions = false
        }
    }

    function toChipText(str, isDir) {
        var result = "";
        for (var i = 0; i < str.length; i++) {
            var code = str.charCodeAt(i);
            if (code >= 65 && code <= 90) {
                result += String.fromCodePoint(code + 120211);
            } else if (code >= 97 && code <= 122) {
                result += String.fromCodePoint(code + 120205);
            } else if (code >= 48 && code <= 57) {
                result += String.fromCodePoint(code + 120764);
            } else {
                result += str[i];
            }
        }
        var icon = isDir ? "󰉋 " : "󰈔 ";
        return icon + result;
    }

    function acceptSuggestion(fileName, isDir) {
        var text = inputField.text
        var originalSearch = text.substring(root.currentCursorStart, root.currentCursorEnd)
        var lastSlash = originalSearch.lastIndexOf('/')
        var pathPrefix = ""
        if (lastSlash !== -1) {
            pathPrefix = originalSearch.substring(0, lastSlash + 1)
            if (!pathPrefix.startsWith("@[")) {
                pathPrefix = "@[" + pathPrefix.substring(1)
            }
        } else {
            pathPrefix = "@["
        }
        
        var newStr = ""
        if (isDir) {
            newStr = pathPrefix + fileName + "/"
        } else {
            var cleanDir = root.currentSearchDir
            if (cleanDir.endsWith("/")) cleanDir = cleanDir.substring(0, cleanDir.length - 1)
            var fullPath = cleanDir + "/" + fileName
            
            var baseAlias = root.toChipText(fileName, false)
            var aliasKey = baseAlias
            var counter = 1
            while (root.pathAliases[aliasKey] && root.pathAliases[aliasKey] !== "@[" + fullPath + "]") {
                aliasKey = root.toChipText(fileName + " (" + counter + ")", false)
                counter++
            }
            
            root.pathAliases[aliasKey] = "@[" + fullPath + "]"
            newStr = aliasKey + " "
        }
        
        var before = text.substring(0, root.currentCursorStart)
        var after = text.substring(root.currentCursorEnd)
        inputField.text = before + newStr + after
        inputField.cursorPosition = (before + newStr).length
        if (!isDir) {
            root.showSuggestions = false
        }
    }

    // ── Manejadores de mensajes ───────────────────────────────────────────
    function handleMsg(msg) {
        switch (msg.type) {
            case "token":
                onToken(msg.content || "")
                break
            case "done":
                onDone(msg.full_response || "")
                break
            case "tool_start":
                addSystemMsg(toolLabel(msg.tool || "", msg.args || {}))
                break
            case "tool_result":
                break   // interno, no mostrar
            case "spotify_auth_result":
                addSystemMsg(
                    msg.success
                    ? "Spotify quedó conectado correctamente."
                    : "⚠ No se pudo conectar Spotify: "
                      + (msg.message || "error desconocido")
                )
                break
            case "spotify_auth_url":
                addSystemMsg(
                    "Autoriza Spotify en el navegador. Si no se abrió, visita: "
                    + (msg.url || "")
                )
                break
            case "run_command":
                // Compatibilidad con backends antiguos: nunca autoejecutar.
                addCmdCard(msg.command || "", msg.job_id || "", true, false)
                break
            case "confirm_required":
                addCmdCard(msg.command || "", msg.job_id || "", true, false)
                break
            case "sudo_required":
                addCmdCard(msg.command || "", msg.job_id || "", false, true)
                break
            case "command_start": {
                // Marcar la command card como "done" buscando por job_id
                var startJobId = msg.job_id || ""
                for (var ci = aiWidget.msgModel.count - 1; ci >= 0; ci--) {
                    var citem = aiWidget.msgModel.get(ci)
                    if (citem.role === "command" && citem.jobId === startJobId) {
                        aiWidget.msgModel.setProperty(ci, "cmdStatus", "done")
                        break
                    }
                }
                addResultCard(msg.command || "", startJobId, "", "running")
                break
            }
            case "command_output": {
                // Actualizar la result card correcta por job_id
                var outJobId = msg.job_id || ""
                for (var ri = aiWidget.msgModel.count - 1; ri >= 0; ri--) {
                    var ritem = aiWidget.msgModel.get(ri)
                    if (ritem.role === "result" && ritem.jobId === outJobId) {
                        var combined = ritem.content + (msg.text || "")
                        if (combined.length > 131072) {
                            combined = combined.substring(0, 65536)
                                + "\n[… salida recortada en la interfaz …]\n"
                                + combined.substring(combined.length - 65536)
                        }
                        aiWidget.msgModel.setProperty(ri, "content", combined)
                        break
                    }
                }
                scrollToBottom()
                break
            }
            case "command_result": {
                // Finalizar la result card correcta por job_id
                var resJobId = msg.job_id || ""
                var found = false
                for (var resi = aiWidget.msgModel.count - 1; resi >= 0; resi--) {
                    var resitem = aiWidget.msgModel.get(resi)
                    if (resitem.role === "command" && resitem.jobId === resJobId) {
                        aiWidget.msgModel.setProperty(
                            resi,
                            "cmdStatus",
                            msg.cancelled ? "cancelled" : "done"
                        )
                    }
                    if (resitem.role === "result" && resitem.jobId === resJobId) {
                        aiWidget.msgModel.setProperty(resi, "cmdStatus", (msg.success !== false) ? "success" : "error")
                        // Volcar el output solo si la card estaba vacía (sin command_output previo)
                        if (!resitem.content && msg.output) {
                            aiWidget.msgModel.setProperty(resi, "content", msg.output)
                        }
                        found = true
                        break
                    }
                }
                if (!found) {
                    // Fallback: crear result card directamente (no llegó command_start)
                    addResultCard(msg.command || "", resJobId, msg.output || "", (msg.success !== false) ? "success" : "error")
                }
                break
            }
            case "error":
                if (aiWidget.streamingIdx >= 0) {
                    aiWidget.streamingIdx = -1
                    aiWidget.streamingRaw = ""
                }
                addSystemMsg("⚠ " + (msg.message || "Error desconocido"))
                break
        }
    }

    function toolLabel(t, args) {
        if (t === "list_dir") {
            let p = args && args.path ? args.path.split('/').pop() : ""
            return "  Listando directorio" + (p ? " " + p + "…" : "…")
        }
        if (t === "read_file" || t === "read_pdf" || t === "read_docx" || t === "read_pptx" || t === "read_excel") {
            let msg = "󰈙  Leyendo archivo"
            if (args && args.path) {
                let p = args.path.split('/').pop()
                msg += " " + p
            }
            if (args && args.start_line !== undefined && args.end_line !== undefined) {
                msg += " (líneas " + args.start_line + "-" + args.end_line + ")"
            }
            return msg + "…"
        }
        if (t === "run_command") return "  Preparando comando…"
        if (t === "web_search") {
            let q = args && args.query ? args.query : ""
            return "󰖟  Buscando en internet" + (q ? ": " + q + "…" : "…")
        }
        if (t === "update_memory") return "󰋊  Guardando en memoria…"
        if (t === "spotify_music") return "󰓇  Controlando Spotify…"
        if (t === "manage_tasks") return "󰃭  Gestionando tareas…"
        if (t === "capture_screen") return "󰹑  Tomando captura de pantalla…"
        if (t === "write_file") return "  Escribiendo archivo…"
        if (t === "replace_lines") return "  Editando archivo…"
        if (t === "create_docx" || t === "modify_docx") return "  Modificando documento…"
        if (t === "query_document") return "󰈙  Consultando documento…"
        if (t === "launch_app") return "  Lanzando aplicación…"
        if (t === "file_info") return "󰋽  Consultando metadatos…"
        if (t === "generate_image") return "  Generando imagen…"
        return "󱁤  Usando herramienta…"
    }

    // ── Helpers de modelo ─────────────────────────────────────────────────
    function onToken(tok) {
        scrollToBottom()
    }

    function onDone(fullRaw) {
        scrollToBottom()
    }

    function addSystemMsg(text) {
        aiWidget.appendDisplayMessage({
            role: "system", content: text, command: "", cmdStatus: "", jobId: "",
            needsConfirm: false, needsSudo: false, isSystem: true
        })
        scrollToBottom()
    }

    function addCmdCard(cmd, jobId, needsConfirm, needsSudo) {
        aiWidget.appendDisplayMessage({
            role: "command", content: cmd, command: cmd, jobId: jobId,
            cmdStatus: "pending",
            needsConfirm: needsConfirm, needsSudo: needsSudo, isSystem: false
        })
        scrollToBottom()
    }

    function addResultCard(cmd, jobId, output, status) {
        aiWidget.appendDisplayMessage({
            role: "result", content: output, command: cmd, jobId: jobId,
            cmdStatus: status,
            needsConfirm: false, needsSudo: false, isSystem: false
        })
        scrollToBottom()
    }

    function sendMessage() {
        var text = inputField.text.trim()
        if (!text || !root.aiWidget || root.aiWidget.isThinking) return

        inputField.text = ""
        aiWidget.currentUserMsg = text
        
        var textToSend = text
        for (var key in root.pathAliases) {
            textToSend = textToSend.split(key).join(root.pathAliases[key])
        }

        // Añadir burbuja de usuario
        aiWidget.appendDisplayMessage({
            role: "user", content: text, command: "", cmdStatus: "",
            needsConfirm: false, needsSudo: false, isSystem: false
        })
        scrollToBottom()

        // Enviar al backend (historial sin el mensaje actual; backend lo añade)
        root.aiWidget.sendChat(textToSend, aiWidget.conversationHistory.slice())
    }

    function clearChat() {
        aiWidget.msgModel.clear()
        aiWidget.conversationHistory = []
        root.pathAliases = ({})
        aiWidget.currentUserMsg  = ""
        aiWidget.streamingIdx    = -1
        aiWidget.streamingRaw    = ""
        aiWidget.pendingCmd      = ""
        aiWidget.pendingJobId    = ""
        aiWidget.approvalQueue   = []
        aiWidget.showConfirm     = false
        if (root.aiWidget) root.aiWidget.cancelRun()
    }

    function scrollToBottom() {
        chatScrollTimer.restart()
    }

    Timer {
        id: chatScrollTimer
        interval: 32
        repeat: false
        onTriggered: chatFlickable.positionViewAtEnd()
    }

    // ── UI ────────────────────────────────────────────────────────────────
    Column {
        anchors.fill: parent
        spacing: 0

        // ── Header ────────────────────────────────────────────────────────
        Rectangle {
            id: chatHeader
            width:  parent.width
            height: 52
            color:  "transparent"

            // Izquierda: icono + nombre + dot de estado
            Row {
                anchors.left: parent.left
                anchors.leftMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                spacing: 10

                Text {
                    text: root.aiWidget && root.aiWidget.isRecording ? "󰍬" : "󱜚"
                    font.family: Theme.fontMono
                    font.pixelSize: 20
                    color: root.aiWidget && root.aiWidget.isRecording ? Theme.danger : Theme.accent
                    anchors.verticalCenter: parent.verticalCenter
                }

                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    Text {
                        text: "Minerva"
                        font.family: Theme.fontSans
                        font.pixelSize: 13
                        font.weight: Font.Bold
                        color: Theme.textPrimary
                    }
                    Text {
                        text: root.aiWidget ? root.aiWidget.modelName : "…"
                        font.family: Theme.fontMono
                        font.pixelSize: 9
                        color: Theme.textMuted
                    }
                }

                Rectangle {
                    width: 7; height: 7; radius: 3.5
                    anchors.verticalCenter: parent.verticalCenter
                    color: root.aiWidget && root.aiWidget.isRecording ? Theme.danger
                         : root.aiWidget && root.aiWidget.isThinking  ? Theme.warning
                         : root.aiWidget && root.aiWidget.backendReady ? Theme.success
                         : Theme.danger
                    Behavior on color { ColorAnimation { duration: 300 } }
                    SequentialAnimation on opacity {
                        running: root.aiWidget && (root.aiWidget.isThinking || root.aiWidget.isRecording)
                        loops: Animation.Infinite
                        NumberAnimation { to: 0.15; duration: 500 }
                        NumberAnimation { to: 1.0;  duration: 500 }
                        onStopped: opacity = 1.0
                    }
                }
                
                Text {
                    text: "󰍬"
                    font.family: Theme.fontMono
                    font.pixelSize: 14
                    color: Theme.accent
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.aiWidget && root.aiWidget.backendReady && !root.aiWidget.isRecording && !root.aiWidget.isTranscribing && !root.aiWidget.isThinking
                    opacity: 0.5
                }
            }

            // Derecha: configuración, reiniciar conversación y cerrar panel
            Item {
                anchors.right: parent.right
                anchors.rightMargin: 82
                anchors.verticalCenter: parent.verticalCenter
                width: 30; height: 30

                Rectangle {
                    anchors.fill: parent; radius: 8
                    color: settingsHover.containsMouse ? Qt.rgba(1,1,1,0.08) : "transparent"
                    Behavior on color { ColorAnimation { duration: 150 } }
                }
                Text {
                    anchors.centerIn: parent
                    text: "⚙"
                    font.family: Theme.fontSans
                    font.pixelSize: 16
                    color: settingsHover.containsMouse || root.settingsOpen ? Theme.accent : Theme.textMuted
                    Behavior on color { ColorAnimation { duration: 150 } }
                }
                MouseArea {
                    id: settingsHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.settingsOpen = true
                }
            }

            Item {
                anchors.right: parent.right
                anchors.rightMargin: 46
                anchors.verticalCenter: parent.verticalCenter
                width: 30; height: 30

                Rectangle {
                    anchors.fill: parent; radius: 8
                    color: clearHover.containsMouse ? Qt.rgba(1,1,1,0.08) : "transparent"
                    Behavior on color { ColorAnimation { duration: 150 } }
                }
                Text {
                    anchors.centerIn: parent
                    text: "󰑐"
                    font.family: Theme.fontMono
                    font.pixelSize: 15
                    color: clearHover.containsMouse ? Theme.warning : Theme.textMuted
                    Behavior on color { ColorAnimation { duration: 150 } }
                }
                MouseArea {
                    id: clearHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.clearChat()
                }
            }

            Item {
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                width: 30; height: 30

                Rectangle {
                    anchors.fill: parent; radius: 8
                    color: closeHover.containsMouse ? Qt.rgba(1,1,1,0.08) : "transparent"
                    Behavior on color { ColorAnimation { duration: 150 } }
                }
                Text {
                    anchors.centerIn: parent
                    text: "󰅖"
                    font.family: Theme.fontMono
                    font.pixelSize: 15
                    color: closeHover.containsMouse ? Theme.textPrimary : Theme.textMuted
                    Behavior on color { ColorAnimation { duration: 150 } }
                }
                MouseArea {
                    id: closeHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.closeRequested()
                }
            }

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width; height: 1
                color: Qt.rgba(1, 1, 1, 0.07)
            }
        }

        // ── Área de mensajes ──────────────────────────────────────────────
        Item {
            width:  parent.width
            height: parent.height - chatHeader.height - inputBar.height

            // ListView virtualiza: solo instancia los delegates visibles +
            // cacheBuffer. Antes (Repeater+Column) se creaban todos de golpe.
            ListView {
                id: chatFlickable
                anchors.fill: parent
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick
                // ~3 pantallas de buffer: scroll suave sin cargar todo
                cacheBuffer: Math.max(0, height * 3)
                spacing: 14
                topMargin:    16
                bottomMargin: 16
                leftMargin:   16
                rightMargin:  16

                // Al abrir el panel, ir directo al último mensaje
                Component.onCompleted: Qt.callLater(positionViewAtEnd)
                // Auto-scroll cuando llega un mensaje nuevo
                onCountChanged: Qt.callLater(positionViewAtEnd)

                model: root.aiWidget ? root.aiWidget.msgModel : null

                delegate: Item {
                    id: msgDelegate
                    // ListView necesita width explícito en el delegate
                    width: chatFlickable.width - 32
                    height: msgLoader.implicitHeight

                    // Loader: solo instancia el componente correcto según rol.
                    // Evita crear los 3 tipos de burbuja por cada mensaje.
                    Loader {
                        id: msgLoader
                        width: parent.width
                        sourceComponent: {
                            if (model.role === "user")    return userBubbleComp
                            if (model.role === "ai")      return aiBubbleComp
                            if (model.role === "command" || model.role === "result") return cmdCardComp
                            if (model.isSystem)           return sysMsgComp
                            return null
                        }
                    }

                    // ── Burbuja usuario ───────────────────────────────────
                    Component {
                        id: userBubbleComp
                        Item {
                            implicitHeight: _userBubble.implicitHeight
                            Rectangle {
                                id: _userBubble
                                implicitHeight: _userTxt.implicitHeight + 24
                                width: Math.min(_userTxt.implicitWidth + 36, msgDelegate.width * 0.82)
                                anchors.right: parent.right
                                radius: 16
                                color: Theme.accent
                                TextEdit {
                                    id: _userTxt
                                    anchors.centerIn: parent
                                    width: parent.width - 36
                                    text: model.content
                                    font.family: Theme.fontSans
                                    font.pixelSize: 13
                                    color: "#0d0d0d"
                                    wrapMode: TextEdit.Wrap
                                    readOnly: true
                                    selectByMouse: true
                                }
                            }
                        }
                    }

                    // ── Burbuja IA ────────────────────────────────────────
                    Component {
                        id: aiBubbleComp
                        Item {
                            implicitHeight: _aiBubble.implicitHeight
                            Rectangle {
                                id: _aiBubble
                                implicitHeight: _aiCol.implicitHeight + 24
                                width: Math.max(140, Math.min(_aiTxt.implicitWidth + 36, msgDelegate.width * 0.85))
                                anchors.left: parent.left
                                radius: 16
                                color: Qt.rgba(1, 1, 1, 0.07)
                                border.width: 1
                                border.color: Qt.rgba(1, 1, 1, 0.09)
                                
                                Column {
                                    id: _aiCol
                                    anchors.centerIn: parent
                                    width: parent.width - 28
                                    spacing: 12
                                    
                                    Image {
                                        width: parent.width
                                        fillMode: Image.PreserveAspectFit
                                        asynchronous: true
                                        cache: false
                                        sourceSize.width: Math.max(1, width * 2)
                                        property string imgPath: {
                                            var match = model.content.match(/!\[.*?\]\((.*?)\)/);
                                            return match ? Qt.resolvedUrl(match[1]) : "";
                                        }
                                        source: imgPath
                                        visible: imgPath !== ""
                                    }
                                    
                                    TextEdit {
                                        id: _aiTxt
                                        width: parent.width
                                        text: {
                                            var cleanText = model.content.replace(/!\[.*?\]\(.*?\)/g, "").trim();
                                            return cleanText + (root.aiWidget && root.aiWidget.streamingIdx === index && root.aiWidget.isThinking ? "▋" : "")
                                        }
                                        font.family: Theme.fontSans
                                        font.pixelSize: 13
                                        color: Theme.textPrimary
                                        wrapMode: TextEdit.Wrap
                                        textFormat: TextEdit.PlainText
                                        readOnly: true
                                        selectByMouse: true
                                        visible: text !== "" || !parent.children[0].visible
                                    }
                                }
                            }
                        }
                    }

                    // ── Tarjeta de comando / resultado ────────────────────
                    Component {
                        id: cmdCardComp
                        Rectangle {
                            implicitHeight: _cardCol.implicitHeight + 30
                            width: msgDelegate.width
                            radius: 14

                            color: model.role === "result"
                                ? (model.cmdStatus === "success"
                                   ? Qt.rgba(0.08, 0.28, 0.08, 0.55)
                                   : model.cmdStatus === "error"
                                     ? Qt.rgba(0.32, 0.07, 0.07, 0.55)
                                     : Qt.rgba(0.08, 0.15, 0.32, 0.55))
                                : Qt.rgba(1, 1, 1, 0.04)
                            border.width: 1
                            border.color: model.role === "result"
                                ? (model.cmdStatus === "success"
                                   ? Qt.rgba(0.3, 0.7, 0.3, 0.3)
                                   : model.cmdStatus === "error"
                                     ? Qt.rgba(0.8, 0.3, 0.3, 0.3)
                                     : Qt.rgba(0.3, 0.5, 0.8, 0.3))
                                : (model.needsConfirm || model.needsSudo)
                                  ? Qt.rgba(0.95, 0.65, 0.22, 0.45)
                                  : Qt.rgba(1, 1, 1, 0.09)

                            Column {
                                id: _cardCol
                                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 15 }
                                spacing: 12

                                Row {
                                    spacing: 6
                                    Text {
                                        id: _resultIcon
                                        text: model.role === "result"
                                            ? (model.cmdStatus === "success" ? "󰄬" : model.cmdStatus === "error" ? "󰅖" : "󰔟")
                                            : model.needsSudo ? "󰌞"
                                            : model.needsConfirm ? "󰀦"
                                            : "󰆍"
                                        font.family: Theme.fontMono
                                        font.pixelSize: 13
                                        color: model.role === "result"
                                            ? (model.cmdStatus === "success" ? Theme.success : model.cmdStatus === "error" ? Theme.danger : Theme.accent)
                                            : (model.needsSudo || model.needsConfirm) ? Theme.warning : Theme.accent
                                        anchors.verticalCenter: parent.verticalCenter
                                        SequentialAnimation on rotation {
                                            running: model.role === "result" && model.cmdStatus === "running"
                                            loops: Animation.Infinite
                                            NumberAnimation { to: 360; duration: 900; easing.type: Easing.Linear }
                                            onStopped: _resultIcon.rotation = 0
                                        }
                                    }
                                    Text {
                                        text: model.role === "result" ? (model.cmdStatus === "running" ? "Ejecutando..." : "Resultado")
                                            : model.needsSudo ? "Requiere sudo (pkexec)"
                                            : model.needsConfirm ? "Confirmar antes de ejecutar"
                                            : "Ejecutar comando"
                                        font.family: Theme.fontSans; font.pixelSize: 11; font.weight: Font.Bold
                                        color: Theme.textMuted; anchors.verticalCenter: parent.verticalCenter
                                    }
                                }

                                Rectangle {
                                    width: _cardCol.width; height: _cmdLineTxt.implicitHeight + 12
                                    radius: 8; color: Qt.rgba(0, 0, 0, 0.35)
                                    TextEdit {
                                        id: _cmdLineTxt
                                        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 10 }
                                        text: "$ " + (model.role === "result" ? model.command : model.content)
                                        font.family: Theme.fontMono; font.pixelSize: 12
                                        color: (model.needsSudo || model.needsConfirm) ? Theme.warning : Theme.accent
                                        wrapMode: TextEdit.Wrap; readOnly: true; selectByMouse: true
                                    }
                                }

                                Flickable {
                                    visible: model.role === "result" && model.content.length > 0
                                    width: _cardCol.width
                                    height: Math.min(_resultTxtEdit.implicitHeight, 310)
                                    contentWidth: width; contentHeight: _resultTxtEdit.implicitHeight
                                    clip: true; boundsBehavior: Flickable.StopAtBounds
                                    TextEdit {
                                        id: _resultTxtEdit
                                        width: parent.width; text: model.content
                                        font.family: Theme.fontMono; font.pixelSize: 11
                                        color: model.cmdStatus === "success" ? Theme.textPrimary : Theme.danger
                                        wrapMode: TextEdit.Wrap; readOnly: true; selectByMouse: true
                                    }
                                }

                                Row {
                                    visible: model.role === "command" && model.cmdStatus === "pending"
                                    spacing: 8
                                    Rectangle {
                                        height: 30; width: _execLbl.implicitWidth + 24; radius: 8
                                        color: _execMa.containsMouse ? Qt.rgba(0.15,0.5,0.15,0.9) : Qt.rgba(0.08,0.30,0.08,0.8)
                                        border.width: 1; border.color: Qt.rgba(Theme.success.r, Theme.success.g, Theme.success.b, 0.75)
                                        Behavior on color { ColorAnimation { duration: 120 } }
                                        Row {
                                            anchors.centerIn: parent; spacing: 4
                                            Text { text: "󰄬"; font.family: Theme.fontMono; font.pixelSize: 11; color: Theme.success; anchors.verticalCenter: parent.verticalCenter }
                                            Text { id: _execLbl; text: model.needsSudo ? "Ejecutar (sudo)" : "Ejecutar"; font.family: Theme.fontSans; font.pixelSize: 12; color: Theme.success; anchors.verticalCenter: parent.verticalCenter }
                                        }
                                        MouseArea {
                                            id: _execMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                root.aiWidget.pendingCmd = model.content
                                                root.aiWidget.pendingJobId = model.jobId || ""
                                                root.aiWidget.pendingIsSudo = model.needsSudo
                                                root.aiWidget.pendingReason = model.needsSudo
                                                    ? "Este comando requiere permisos de administrador (pkexec)"
                                                    : "Los comandos de shell requieren aprobación explícita"
                                                root.aiWidget.showConfirm = true
                                            }
                                        }
                                    }
                                    Rectangle {
                                        height: 30; width: _cancelLbl.implicitWidth + 24; radius: 8
                                        color: _cancelMa.containsMouse ? Qt.rgba(0.4,0.1,0.1,0.6) : Qt.rgba(0.22,0.05,0.05,0.5)
                                        border.width: 1; border.color: Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.5)
                                        Behavior on color { ColorAnimation { duration: 120 } }
                                        Text { id: _cancelLbl; anchors.centerIn: parent; text: "Cancelar"; font.family: Theme.fontSans; font.pixelSize: 12; color: Theme.danger }
                                        MouseArea {
                                            id: _cancelMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                root.aiWidget.msgModel.setProperty(index, "cmdStatus", "cancelled")
                                                if (model.jobId) {
                                                    root.aiWidget.cancelJob(model.jobId)
                                                    root.aiWidget.resolveApproval(model.jobId)
                                                }
                                            }
                                        }
                                    }
                                }

                                Row {
                                    visible: model.role === "command" && model.cmdStatus === "running"; spacing: 6
                                    Text {
                                        id: _runningIcon; text: "󰔟"; font.family: Theme.fontMono; font.pixelSize: 13; color: Theme.accent; anchors.verticalCenter: parent.verticalCenter
                                        SequentialAnimation on rotation { running: parent.visible; loops: Animation.Infinite; NumberAnimation { to: 360; duration: 900; easing.type: Easing.Linear } onStopped: _runningIcon.rotation = 0 }
                                    }
                                    Text { text: "Ejecutando…"; font.family: Theme.fontSans; font.pixelSize: 12; color: Theme.accent; anchors.verticalCenter: parent.verticalCenter }
                                }

                                Row {
                                    visible: model.role === "command" && model.cmdStatus === "cancelled"; spacing: 6
                                    Text { text: "󰜺"; font.family: Theme.fontMono; font.pixelSize: 12; color: Theme.textMuted; anchors.verticalCenter: parent.verticalCenter }
                                    Text { text: "Cancelado"; font.family: Theme.fontSans; font.pixelSize: 12; color: Theme.textMuted; anchors.verticalCenter: parent.verticalCenter }
                                }
                            }
                        }
                    }

                    // ── Mensaje de sistema ────────────────────────────────
                    Component {
                        id: sysMsgComp
                        Item {
                            implicitHeight: _sysText.implicitHeight + 4
                            width: msgDelegate.width
                            TextEdit {
                                id: _sysText
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: parent.width
                                horizontalAlignment: TextEdit.AlignHCenter
                                text: model.content
                                font.family: Theme.fontSans; font.pixelSize: 11
                                color: Theme.textMuted; opacity: 1
                                readOnly: true; selectByMouse: true
                            }
                        }
                    }
                } // delegate

                // Estado vacío
                Column {
                    anchors.centerIn: parent
                    visible: chatFlickable.count === 0
                    spacing: 12; opacity: 1
                    Text { text: "󱜚"; font.family: Theme.fontMono; font.pixelSize: 46; color: Theme.accent; horizontalAlignment: Text.AlignHCenter; anchors.horizontalCenter: parent.horizontalCenter }
                    Text {
                        text: root.aiWidget && root.aiWidget.backendReady ? "¿En qué puedo ayudarte?" : "Iniciando Minerva…"
                        font.family: Theme.fontSans; font.pixelSize: 13; color: Theme.textMuted
                        horizontalAlignment: Text.AlignHCenter; anchors.horizontalCenter: parent.horizontalCenter
                    }
                    Text { text: "Tengo acceso a tu directorio home y búsqueda web"; font.family: Theme.fontSans; font.pixelSize: 11; color: Theme.textMuted; horizontalAlignment: Text.AlignHCenter; anchors.horizontalCenter: parent.horizontalCenter }
                }
            } // ListView

        }


        // ── Barra de input ────────────────────────────────────────────────
        // ── Barra de input ────────────────────────────────────────────────
        Rectangle {
            id: inputBar
            width:  parent.width
            height: 70
            color:  "transparent"

            Rectangle {
                anchors.top: parent.top
                width: parent.width; height: 1
                color: Qt.rgba(1, 1, 1, 0.07)
            }

            Row {
                anchors {
                    fill: parent
                    topMargin: 10; bottomMargin: 16
                    leftMargin: 16; rightMargin: 16
                }
                spacing: 8

                // Botón imagen
                Rectangle {
                    width:  42
                    height: 42
                    radius: 21
                    color: root.aiWidget && root.aiWidget.pendingImage !== ""
                        ? Qt.rgba(Theme.success.r, Theme.success.g, Theme.success.b, 0.3)
                        : (imgMa.containsMouse ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(1, 1, 1, 0.06))
                    border.width: 1
                    border.color: root.aiWidget && root.aiWidget.pendingImage !== "" ? Theme.success : Qt.rgba(1, 1, 1, 0.08)
                    Behavior on color { ColorAnimation { duration: 150 } }

                    Text {
                        anchors.centerIn: parent
                        text: "󰁦" // Icono adjuntar
                        font.family: Theme.fontMono
                        font.pixelSize: 18
                        color: root.aiWidget && root.aiWidget.pendingImage !== "" ? Theme.success : Theme.textMuted
                    }

                    MouseArea {
                        id: imgMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (root.aiWidget && root.aiWidget.pendingImage !== "") {
                                root.aiWidget.pendingImage = "" // Toggle off
                            } else if (root.aiWidget) {
                                root.aiWidget.selectImage()
                            }
                        }
                    }
                }

                // Campo de texto
                Rectangle {
                    height: 42
                    width:  parent.width - 42 - 42 - 42 - ((root.aiWidget && root.aiWidget.isSpeaking) ? 50 : 0) - 32
                    radius: 21
                    color:  Qt.rgba(1, 1, 1, 0.055)
                    border.width: inputField.activeFocus ? 1.5 : 1
                    border.color: inputField.activeFocus ? Theme.accent : Qt.rgba(1, 1, 1, 0.08)
                    Behavior on border.color { ColorAnimation { duration: 150 } }

                    TextInput {
                        id: inputField
                        anchors { fill: parent; leftMargin: 16; rightMargin: 16; topMargin: 10; bottomMargin: 10 }
                        font.family: Theme.fontSans
                        font.pixelSize: 13
                        color: Theme.textPrimary
                        clip: true
                        readOnly: root.aiWidget && (root.aiWidget.isThinking || root.aiWidget.isRecording || root.aiWidget.isTranscribing)

                        // Placeholder manual
                        Text {
                            visible: !inputField.text && !inputField.activeFocus
                            text: root.aiWidget && root.aiWidget.isRecording
                                ? "🎙 Escuchando… presiona de nuevo para enviar"
                                : root.aiWidget && root.aiWidget.isTranscribing
                                ? "⏳ Transcribiendo…"
                                : root.aiWidget && root.aiWidget.isThinking
                                ? "Esperando respuesta…"
                                : root.aiWidget && root.aiWidget.pendingImage !== ""
                                ? "🖼 Imagen adjunta. Escribe un mensaje…"
                                : "Escribe un mensaje…  Enter para enviar"
                            font: inputField.font
                            color: root.aiWidget && root.aiWidget.isRecording ? Theme.danger : Theme.textMuted
                            anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                        }

                        onCursorPositionChanged: root.checkAutocomplete()
                        onTextChanged: root.checkAutocomplete()

                        Keys.onPressed: function(e) {
                            if ((e.modifiers & Qt.ControlModifier) && e.key === Qt.Key_Comma) {
                                root.settingsOpen = true
                                e.accepted = true
                                return
                            }
                            if (root.showSuggestions && fuzzySuggestionsModel.count > 0) {
                                if (e.key === Qt.Key_Up) {
                                    suggestionsList.currentIndex = Math.max(0, suggestionsList.currentIndex - 1)
                                    e.accepted = true
                                    return
                                }
                                if (e.key === Qt.Key_Down) {
                                    suggestionsList.currentIndex = Math.min(fuzzySuggestionsModel.count - 1, suggestionsList.currentIndex + 1)
                                    e.accepted = true
                                    return
                                }
                                if (e.key === Qt.Key_Tab || e.key === Qt.Key_Return) {
                                    var item = fuzzySuggestionsModel.get(suggestionsList.currentIndex)
                                    if (item) {
                                        root.acceptSuggestion(item.fileName, item.isDir)
                                        e.accepted = true
                                        return
                                    }
                                }
                                if (e.key === Qt.Key_Escape) {
                                    root.showSuggestions = false
                                    e.accepted = true
                                    return
                                }
                            }
                            if (e.key === Qt.Key_Escape) {
                                root.closeRequested()
                                e.accepted = true
                                return
                            }
                            // Delete whole chip (alias) if Backspace or Delete touches it
                            if (e.key === Qt.Key_Backspace || e.key === Qt.Key_Delete) {
                                var txt = inputField.text
                                var cpos = inputField.cursorPosition
                                for (var key in root.pathAliases) {
                                    var idx = 0
                                    while ((idx = txt.indexOf(key, idx)) !== -1) {
                                        var start = idx
                                        var end = idx + key.length
                                        if (e.key === Qt.Key_Backspace && cpos > start && cpos <= end) {
                                            inputField.text = txt.substring(0, start) + txt.substring(end)
                                            inputField.cursorPosition = start
                                            e.accepted = true
                                            return
                                        }
                                        if (e.key === Qt.Key_Delete && cpos >= start && cpos < end) {
                                            inputField.text = txt.substring(0, start) + txt.substring(end)
                                            inputField.cursorPosition = start
                                            e.accepted = true
                                            return
                                        }
                                        idx = end
                                    }
                                }
                            }
                            
                            // Convert typed directory to chip when space is pressed
                            if (e.key === Qt.Key_Space) {
                                var currentTxt = inputField.text
                                var currentCpos = inputField.cursorPosition
                                var lastAt = currentTxt.lastIndexOf("@[", currentCpos - 1)
                                if (lastAt !== -1 && currentTxt.substring(currentCpos - 1, currentCpos) === "/") {
                                    var possibleDir = currentTxt.substring(lastAt, currentCpos)
                                    if (possibleDir.indexOf(" ") === -1) {
                                        var rawPath = possibleDir.substring(2)
                                        var fullPath = ""
                                        if (rawPath.startsWith("/")) {
                                            fullPath = rawPath
                                        } else if (rawPath.startsWith("~")) {
                                            fullPath = Quickshell.env("HOME") + rawPath.substring(1)
                                        } else {
                                            fullPath = Quickshell.env("HOME") + "/" + rawPath
                                        }
                                        
                                        if (fullPath.length > 1 && fullPath.endsWith("/")) {
                                            fullPath = fullPath.substring(0, fullPath.length - 1)
                                        }
                                        
                                        var folderName = fullPath
                                        var lastSlash = fullPath.lastIndexOf('/')
                                        if (lastSlash !== -1 && lastSlash < fullPath.length - 1) {
                                            folderName = fullPath.substring(lastSlash + 1)
                                        } else if (fullPath === "/") {
                                            folderName = "root"
                                        }
                                        
                                        var dirAliasKey = root.toChipText(folderName, true)
                                        var dirCounter = 1
                                        while (root.pathAliases[dirAliasKey] && root.pathAliases[dirAliasKey] !== "@[" + fullPath + "]") {
                                            dirAliasKey = root.toChipText(folderName + " (" + dirCounter + ")", true)
                                            dirCounter++
                                        }
                                        
                                        root.pathAliases[dirAliasKey] = "@[" + fullPath + "]"
                                        
                                        var dirBefore = currentTxt.substring(0, lastAt)
                                        var dirAfter = currentTxt.substring(currentCpos)
                                        
                                        inputField.text = dirBefore + dirAliasKey + " " + dirAfter
                                        inputField.cursorPosition = (dirBefore + dirAliasKey + " ").length
                                        root.showSuggestions = false
                                        e.accepted = true
                                        return
                                    }
                                }
                            }
                            
                            if (e.key === Qt.Key_Return) {
                                if (!(e.modifiers & Qt.ShiftModifier)) {
                                    root.sendMessage()
                                    e.accepted = true
                                }
                            }
                        }
                    }
                }

                // Botón micrófono
                Rectangle {
                    width:  42
                    height: 42
                    radius: 21
                    color: root.aiWidget && root.aiWidget.isRecording
                        ? Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.3)
                        : (micMa.containsMouse ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(1, 1, 1, 0.06))
                    border.width: 1
                    border.color: root.aiWidget && root.aiWidget.isRecording ? Theme.danger : Qt.rgba(1, 1, 1, 0.08)
                    Behavior on color { ColorAnimation { duration: 150 } }

                    Text {
                        anchors.centerIn: parent
                        text: "󰍬" // NerdFont mic
                        font.family: Theme.fontMono
                        font.pixelSize: 18
                        color: root.aiWidget && root.aiWidget.isRecording ? Theme.danger : Theme.textMuted
                        
                        SequentialAnimation on opacity {
                            running: root.aiWidget && root.aiWidget.isRecording
                            loops: Animation.Infinite
                            NumberAnimation { to: 0.3; duration: 600 }
                            NumberAnimation { to: 1.0; duration: 600 }
                            onStopped: opacity = 1.0
                        }
                    }

                    MouseArea {
                        id: micMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: if (root.aiWidget) root.aiWidget.toggleVoice()
                    }
                }

                // Botón detener TTS (silenciar voz)
                Rectangle {
                    width:   (root.aiWidget && root.aiWidget.isSpeaking) ? 42 : 0
                    height:  42
                    radius:  21
                    visible: width > 0
                    clip:    true
                    color:   stopTtsMa.containsMouse 
                        ? Qt.rgba(Theme.warning.r, Theme.warning.g, Theme.warning.b, 0.3)
                        : Qt.rgba(Theme.warning.r, Theme.warning.g, Theme.warning.b, 0.15)
                    border.width: 1
                    border.color: Qt.rgba(Theme.warning.r, Theme.warning.g, Theme.warning.b, 0.3)
                    Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.InOutQuad } }
                    Behavior on color { ColorAnimation  { duration: 150 } }

                    Text {
                        anchors.centerIn: parent
                        text: "󰝟" // NerdFont speaker off
                        font.family: Theme.fontMono
                        font.pixelSize: 18
                        color: Theme.warning
                        
                        SequentialAnimation on opacity {
                            running: root.aiWidget && root.aiWidget.isSpeaking
                            loops: Animation.Infinite
                            NumberAnimation { to: 0.4; duration: 500 }
                            NumberAnimation { to: 1.0; duration: 500 }
                            onStopped: opacity = 1.0
                        }
                    }

                    MouseArea {
                        id: stopTtsMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: if (root.aiWidget) root.aiWidget.stopTTS()
                    }
                }

                // Botón enviar / spinner
                Rectangle {
                    id: sendBtn
                    width:  42
                    height: 42
                    radius: 21
                    readonly property bool hasText: inputField.text.trim() !== ""
                    color: (root.aiWidget && root.aiWidget.isThinking)
                        ? Qt.rgba(1, 1, 1, 0.06)
                        : (hasText
                            ? (sendMa.containsMouse ? "#92e5e7" : Theme.accent)
                            : (sendMa.containsMouse ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(1, 1, 1, 0.06)))
                    border.width: hasText ? 0 : 1
                    border.color: Qt.rgba(1, 1, 1, 0.08)
                    opacity: (root.aiWidget && (root.aiWidget.isThinking || root.aiWidget.isRecording)) ? 0.5 : 1.0
                    Behavior on color   { ColorAnimation  { duration: 150 } }
                    Behavior on opacity { NumberAnimation { duration: 200 } }

                    Text {
                        id: sendIcon
                        anchors.centerIn: parent
                        text: (root.aiWidget && root.aiWidget.isThinking) ? "󰔟" : "󰒊"
                        font.family: Theme.fontMono
                        font.pixelSize: 18
                        color: (root.aiWidget && root.aiWidget.isThinking) ? Theme.accent : (sendBtn.hasText ? "#102526" : Theme.textMuted)
                        Behavior on color { ColorAnimation { duration: 150 } }

                        SequentialAnimation on rotation {
                            running: root.aiWidget && root.aiWidget.isThinking
                            loops: Animation.Infinite
                            NumberAnimation { to: 360; duration: 900; easing.type: Easing.Linear }
                            onStopped: sendIcon.rotation = 0
                        }
                    }

                    MouseArea {
                        id: sendMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        enabled: !(root.aiWidget && (root.aiWidget.isThinking || root.aiWidget.isRecording))
                        onClicked: root.sendMessage()
                    }
                }
            }
        }
    }

    // ── Configuración ─────────────────────────────────────────────────────
    SettingsPanel {
        id: settingsPanel
        anchors.fill: parent
        aiWidget: root.aiWidget
        opacity: root.settingsOpen ? 1 : 0
        visible: opacity > 0
        z: 80
        onCloseRequested: root.closeSettings()

        Behavior on opacity {
            NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
        }
    }

    // ── Autocomplete Overlay ──────────────────────────────────────────────
    Rectangle {
        id: suggestionsPopup
        visible: root.showSuggestions && fuzzySuggestionsModel.count > 0
        width: 320
        height: Math.min(fuzzySuggestionsModel.count * 34 + 12, 220)
        
        anchors.left: parent.left
        anchors.leftMargin: 20
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 60

        radius: 12
        color: Qt.rgba(0.08, 0.08, 0.12, 0.95)
        border.width: 1
        border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.5)

        layer.enabled: true

        ListView {
            id: suggestionsList
            anchors.fill: parent
            anchors.margins: 6
            model: fuzzySuggestionsModel
            clip: true
            spacing: 2
            
            delegate: Rectangle {
                width: ListView.view.width
                height: 32
                color: ListView.isCurrentItem ? Qt.rgba(1, 1, 1, 0.1) : (maSuggestion.containsMouse ? Qt.rgba(1, 1, 1, 0.05) : "transparent")
                radius: 8
                
                Row {
                    anchors.fill: parent
                    anchors.margins: 8
                    spacing: 10
                    Text {
                        text: model.isDir ? "󰉋" : "󰈔"
                        font.family: Theme.fontMono
                        font.pixelSize: 14
                        color: model.isDir ? Theme.accent : Theme.textMuted
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: model.fileName
                        font.family: Theme.fontSans
                        font.pixelSize: 13
                        color: Theme.textPrimary
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
                
                MouseArea {
                    id: maSuggestion
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: {
                        root.acceptSuggestion(model.fileName, model.isDir)
                    }
                    onEntered: suggestionsList.currentIndex = index
                }
            }
        }
    }

    CommandApprovalDialog {
        anchors.fill: parent
        aiWidget: root.aiWidget
    }
}
