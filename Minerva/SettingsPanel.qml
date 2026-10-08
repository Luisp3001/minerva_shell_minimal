import QtQuick

Item {
    id: root

    property var aiWidget: null
    property string draftPersonality: "minerva"
    property string draftTextModel: ""
    property string draftTtsProvider: "fish"
    property string draftTtsModel: ""
    property string draftGeminiVoice: "Kore"
    property bool   draftLiveMode: false
    signal closeRequested()

    // ── Pestaña Activa ────────────────────────────────────────────────────────
    property string currentTab: "general" // "general" | "mcp"

    // ── Estado de Servidores MCP ──────────────────────────────────────────────
    property bool   showAddServerForm: false
    property string editServerId: ""
    property string draftServerName: ""
    property string draftServerTransport: "http"   // "http" | "stdio"
    property string draftServerUrl: ""
    property string draftServerCommand: ""
    property string draftServerEnvVars: ""          // KEY=VALUE por linea
    property string draftServerAuthType: "none"    // "none" | "bearer" | "oauth2"
    property string draftServerBearerToken: ""
    property string draftServerClientId: ""
    property string draftServerClientSecret: ""
    property string draftServerAuthUrl: ""
    property string draftServerTokenUrl: ""
    property string draftServerScopes: ""
    property var    expandedServerIds: ({})
    property string mcpStatusBannerText: ""
    property string mcpStatusBannerType: "info" // "info" | "success" | "error"

    readonly property int contentHeight: currentTab === "general"
        ? (settingsHeader.height + settingsContent.implicitHeight + 48)
        : (settingsHeader.height + mcpContent.implicitHeight + 48)

    function uniqueOptions(options, currentValue) {
        var result = options.slice()
        if (currentValue && result.indexOf(currentValue) === -1)
            result.unshift(currentValue)
        return result
    }

    readonly property var textModelOptions: uniqueOptions([
        "gemini-3.6-flash",
        "gemini-2.5-pro",
        "gemini-2.5-flash"
    ], draftTextModel)

    readonly property var ttsModelOptions: {
        var models
        if (draftTtsProvider === "fish") {
            models = ["s2.1-pro", "s2-pro", "speech-1.6"]
        } else if (draftTtsProvider === "gemini") {
            models = [
                "gemini-2.5-flash-preview-tts",
                "gemini-2.5-pro-preview-tts",
                "gemini-2.5-flash-tts"
            ]
        } else {
            models = ["es_MX-claude-high"]
        }
        return uniqueOptions(models, draftTtsModel)
    }

    function syncFromService() {
        if (!aiWidget) return
        draftPersonality = aiWidget.activePersonality
        draftTextModel = aiWidget.geminiModel
        draftTtsProvider = aiWidget.ttsProvider
        draftGeminiVoice = aiWidget.geminiTtsVoice
        draftLiveMode = aiWidget.liveMode
        if (draftTtsProvider === "fish")
            draftTtsModel = aiWidget.fishModel
        else if (draftTtsProvider === "gemini")
            draftTtsModel = aiWidget.geminiTtsModel
        else
            draftTtsModel = "es_MX-claude-high"

        if (aiWidget.fetchMcpServers)
            aiWidget.fetchMcpServers()
    }

    function selectTtsProvider(provider) {
        draftTtsProvider = provider
        if (!aiWidget) return
        if (provider === "fish")
            draftTtsModel = aiWidget.fishModel
        else if (provider === "gemini")
            draftTtsModel = aiWidget.geminiTtsModel
        else
            draftTtsModel = "es_MX-claude-high"
    }

    function save() {
        if (!aiWidget) return
        var textModel = draftTextModel.trim()
        var ttsModel = draftTtsModel.trim()
        if (textModel) aiWidget.geminiModel = textModel
        aiWidget.personality = draftPersonality
        aiWidget.liveMode = draftLiveMode
        if (draftPersonality === "minerva") {
            aiWidget.ttsProvider = draftTtsProvider
            if (draftTtsProvider === "fish" && ttsModel)
                aiWidget.fishModel = ttsModel
            else if (draftTtsProvider === "gemini" && ttsModel) {
                aiWidget.geminiTtsModel = ttsModel
                aiWidget.geminiTtsVoice = draftGeminiVoice.trim() || "Kore"
            }
        }
        aiWidget.saveSettings()
        closeRequested()
    }

    // ── MCP Form Helpers ──────────────────────────────────────────────────────

    function openAddServer() {
        editServerId = ""
        draftServerName = ""
        draftServerTransport = "http"
        draftServerUrl = ""
        draftServerCommand = ""
        draftServerEnvVars = ""
        draftServerAuthType = "none"
        draftServerBearerToken = ""
        draftServerClientId = ""
        draftServerClientSecret = ""
        draftServerAuthUrl = ""
        draftServerTokenUrl = ""
        draftServerScopes = ""
        showAddServerForm = true
    }

    function openEditServer(server) {
        if (!server) return
        editServerId = server.id || ""
        draftServerName = server.name || ""
        draftServerTransport = server.transport || "http"
        draftServerUrl = server.url || ""
        draftServerCommand = server.command || ""
        var ev = server.env_vars || {}
        var evLines = []
        for (var k in ev) evLines.push(k + "=" + ev[k])
        draftServerEnvVars = evLines.join("\n")
        draftServerAuthType = server.auth_type || "none"
        draftServerBearerToken = server.bearer_token || ""
        var o = server.oauth2 || {}
        draftServerClientId = o.client_id || ""
        draftServerClientSecret = o.client_secret || ""
        draftServerAuthUrl = o.auth_url || ""
        draftServerTokenUrl = o.token_url || ""
        draftServerScopes = o.scopes || ""
        showAddServerForm = true
    }

    function applyOAuthPreset(preset) {
        if (preset === "google") {
            draftServerAuthUrl = "https://accounts.google.com/o/oauth2/v2/auth"
            draftServerTokenUrl = "https://oauth2.googleapis.com/token"
            draftServerScopes = "https://www.googleapis.com/auth/drive.readonly https://www.googleapis.com/auth/gmail.readonly"
            if (!draftServerName) draftServerName = "Google Drive / Gmail"
        } else if (preset === "github") {
            draftServerAuthUrl = "https://github.com/login/oauth/authorize"
            draftServerTokenUrl = "https://github.com/login/oauth/access_token"
            draftServerScopes = "repo,read:user"
            if (!draftServerName) draftServerName = "GitHub MCP"
        }
    }

    function saveDraftServer() {
        if (!aiWidget) return
        var name = draftServerName.trim() || "Servidor MCP"

        if (draftServerTransport === "stdio") {
            var cmd = draftServerCommand.trim()
            if (!cmd) {
                setBanner("Por favor ingresa el comando del servidor STDIO.", "error")
                return
            }
            var envObj = {}
            var evLines = draftServerEnvVars.split("\n")
            for (var i = 0; i < evLines.length; i++) {
                var evLine = evLines[i].trim()
                if (!evLine || evLine.charAt(0) === "#") continue
                var sep = evLine.indexOf("=")
                if (sep > 0) {
                    var evKey = evLine.substring(0, sep).trim()
                    var evVal = evLine.substring(sep + 1).trim()
                    if (evKey) envObj[evKey] = evVal
                }
            }
            var stdioData = {
                id: editServerId || undefined,
                name: name,
                transport: "stdio",
                command: cmd,
                env_vars: envObj,
                url: "",
                enabled: true,
                auth_type: "none",
                bearer_token: "",
                oauth2: {}
            }
            aiWidget.saveMcpServer(stdioData)
        } else {
            var url = draftServerUrl.trim()
            if (!url) {
                setBanner("Por favor ingresa la URL del servidor.", "error")
                return
            }
            var httpData = {
                id: editServerId || undefined,
                name: name,
                transport: "http",
                url: url,
                enabled: true,
                auth_type: draftServerAuthType,
                bearer_token: draftServerBearerToken.trim(),
                oauth2: {
                    client_id: draftServerClientId.trim(),
                    client_secret: draftServerClientSecret.trim(),
                    auth_url: draftServerAuthUrl.trim(),
                    token_url: draftServerTokenUrl.trim(),
                    scopes: draftServerScopes.trim()
                }
            }
            aiWidget.saveMcpServer(httpData)
        }
        showAddServerForm = false
        setBanner("Servidor guardado. Conectando...", "info")
    }

    function triggerOAuthFromForm() {
        if (!aiWidget) return
        if (!draftServerClientId.trim() || !draftServerAuthUrl.trim() || !draftServerTokenUrl.trim()) {
            setBanner("Completa Client ID, Auth URL y Token URL antes de autenticar.", "error")
            return
        }
        saveDraftServer()
        if (editServerId) {
            aiWidget.startMcpOAuth(editServerId)
        }
    }

    function toggleExpandTools(serverId) {
        var copy = Object.assign({}, expandedServerIds)
        if (copy[serverId]) {
            delete copy[serverId]
        } else {
            copy[serverId] = true
        }
        expandedServerIds = copy
    }

    function setBanner(text, type) {
        mcpStatusBannerText = text
        mcpStatusBannerType = type || "info"
        bannerTimer.restart()
    }

    Timer {
        id: bannerTimer
        interval: 6000
        onTriggered: root.mcpStatusBannerText = ""
    }

    // ── Conexiones a Eventos OAuth de aiWidget ────────────────────────────────
    Connections {
        target: root.aiWidget
        ignoreUnknownSignals: true
        function onMcpOAuthStarted(serverId, authUrl) {
            root.setBanner("Navegador abierto para autorizar la cuenta. Completa el inicio de sesión...", "info")
        }
        function onMcpOAuthSuccess(serverId) {
            root.setBanner("¡Cuenta autorizada con éxito en Minerva!", "success")
        }
        function onMcpOAuthError(serverId, error) {
            root.setBanner("Error al autorizar cuenta: " + error, "error")
        }
    }

    onVisibleChanged: {
        if (visible) {
            syncFromService()
            forceActiveFocus()
        }
    }

    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
            if (root.showAddServerForm) {
                root.showAddServerForm = false
                event.accepted = true
                return
            }
            root.closeRequested()
            event.accepted = true
        }
    }

    // Impide que clicks sobre espacios vacíos alcancen el chat que está debajo.
    MouseArea {
        anchors.fill: parent
    }

    Rectangle {
        id: panelCard
        anchors.fill: parent
        color: "#0c0c12"
        radius: 22
        clip: true
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.08)

        // ── Encabezado con Tabs Segmentadas ───────────────────────────────────
        Rectangle {
            id: settingsHeader
            anchors { left: parent.left; right: parent.right; top: parent.top }
            height: 60
            color: "transparent"

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width; height: 1
                color: Qt.rgba(1, 1, 1, 0.07)
            }

            // Tabs Segmentadas
            Row {
                anchors { left: parent.left; leftMargin: 18; verticalCenter: parent.verticalCenter }
                spacing: 8

                // Tab General
                Rectangle {
                    height: 36
                    width: tabGeneralText.implicitWidth + 28
                    radius: 12
                    color: root.currentTab === "general"
                        ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.16)
                        : (tabGenArea.containsMouse ? Qt.rgba(1,1,1,0.08) : Qt.rgba(1,1,1,0.03))
                    border.width: 1
                    border.color: root.currentTab === "general" ? Theme.accent : Qt.rgba(1,1,1,0.08)
                    Behavior on color { ColorAnimation { duration: 150 } }
                    Behavior on border.color { ColorAnimation { duration: 150 } }

                    Row {
                        id: tabGeneralText
                        anchors.centerIn: parent
                        spacing: 6
                        Text {
                            text: "⚙"
                            font.family: Theme.fontSans
                            font.pixelSize: 13
                            color: root.currentTab === "general" ? Theme.accent : Theme.textMuted
                        }
                        Text {
                            text: "General"
                            font.family: Theme.fontSans
                            font.pixelSize: 12
                            font.weight: root.currentTab === "general" ? Font.Bold : Font.Normal
                            color: root.currentTab === "general" ? Theme.textPrimary : Theme.textMuted
                        }
                    }

                    MouseArea {
                        id: tabGenArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.currentTab = "general"
                    }
                }

                // Tab Servidores MCP
                Rectangle {
                    height: 36
                    width: tabMcpRow.implicitWidth + 28
                    radius: 12
                    color: root.currentTab === "mcp"
                        ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.16)
                        : (tabMcpArea.containsMouse ? Qt.rgba(1,1,1,0.08) : Qt.rgba(1,1,1,0.03))
                    border.width: 1
                    border.color: root.currentTab === "mcp" ? Theme.accent : Qt.rgba(1,1,1,0.08)
                    Behavior on color { ColorAnimation { duration: 150 } }
                    Behavior on border.color { ColorAnimation { duration: 150 } }

                    Row {
                        id: tabMcpRow
                        anchors.centerIn: parent
                        spacing: 6
                        Text {
                            text: "🔌"
                            font.family: Theme.fontSans
                            font.pixelSize: 13
                            color: root.currentTab === "mcp" ? Theme.accent : Theme.textMuted
                        }
                        Text {
                            text: "Servidores MCP"
                            font.family: Theme.fontSans
                            font.pixelSize: 12
                            font.weight: root.currentTab === "mcp" ? Font.Bold : Font.Normal
                            color: root.currentTab === "mcp" ? Theme.textPrimary : Theme.textMuted
                        }
                        // Badge con número de servidores
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.max(mcpBadgeText.implicitWidth + 8, 18)
                            height: 18
                            radius: 9
                            color: root.currentTab === "mcp"
                                ? Theme.accent
                                : Qt.rgba(1, 1, 1, 0.12)
                            Text {
                                id: mcpBadgeText
                                anchors.centerIn: parent
                                text: (root.aiWidget && root.aiWidget.mcpServers) ? root.aiWidget.mcpServers.length : "0"
                                font.family: Theme.fontMono
                                font.pixelSize: 10
                                font.weight: Font.Bold
                                color: root.currentTab === "mcp" ? "#0c0c12" : Theme.textPrimary
                            }
                        }
                    }

                    MouseArea {
                        id: tabMcpArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.currentTab = "mcp"
                            if (root.aiWidget && root.aiWidget.fetchMcpServers)
                                root.aiWidget.fetchMcpServers()
                        }
                    }
                }
            }

            // Botón Cerrar
            Rectangle {
                anchors { right: parent.right; rightMargin: 16; verticalCenter: parent.verticalCenter }
                width: 32; height: 32; radius: 16
                color: settingsCloseArea.containsMouse ? Qt.rgba(1,1,1,0.12) : Qt.rgba(1,1,1,0.04)
                Behavior on color { ColorAnimation { duration: 150 } }

                Text {
                    anchors.centerIn: parent
                    text: "󰅖"
                    font.family: Theme.fontMono
                    font.pixelSize: 15
                    color: settingsCloseArea.containsMouse ? Theme.textPrimary : Theme.textMuted
                    Behavior on color { ColorAnimation { duration: 150 } }
                }
                MouseArea {
                    id: settingsCloseArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.closeRequested()
                }
            }
        }

        // ══════════════════════════════════════════════════════════════════════
        // VISTA 1: CONFIGURACIÓN GENERAL
        // ══════════════════════════════════════════════════════════════════════
        Flickable {
            id: generalFlickable
            visible: root.currentTab === "general"
            anchors {
                left: parent.left; right: parent.right
                top: settingsHeader.bottom; bottom: parent.bottom
            }
            contentWidth: width
            contentHeight: settingsContent.implicitHeight + 48
            boundsBehavior: Flickable.StopAtBounds
            clip: true

            Column {
                id: settingsContent
                width: parent.width - 48
                x: 24
                y: 24
                spacing: 14

                Text {
                    text: "Personalidad"
                    font.family: Theme.fontSans
                    font.pixelSize: 13
                    font.weight: Font.Bold
                    color: Theme.textPrimary
                }
                Text {
                    width: parent.width
                    text: "El perfil cambia la identidad, el trato, la voz y la palabra de activación."
                    font.family: Theme.fontSans
                    font.pixelSize: 11
                    color: Theme.textMuted
                    wrapMode: Text.Wrap
                }
                Flow {
                    width: parent.width
                    spacing: 8
                    Repeater {
                        model: [
                            { value: "minerva", label: "Minerva" },
                            { value: "jarvis", label: "JARVIS" }
                        ]
                        delegate: OptionChip {
                            value: modelData.value
                            label: modelData.label
                            selected: root.draftPersonality === modelData.value
                            onChosen: root.draftPersonality = value
                        }
                    }
                }

                Rectangle {
                    width: parent.width
                    height: jarvisProfileText.implicitHeight + 24
                    radius: 14
                    visible: root.draftPersonality === "jarvis"
                    color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.09)
                    border.width: 1
                    border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.24)

                    Text {
                        id: jarvisProfileText
                        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 12 }
                        text: "JARVIS usa Fish Audio con su voz dedicada y responde al decir \"Jarvis\". Requiere que tu API key de Fish Audio esté configurada."
                        font.family: Theme.fontSans
                        font.pixelSize: 11
                        color: Theme.textMuted
                        wrapMode: Text.Wrap
                    }
                }

                // ── Modo Live (solo JARVIS) ───────────────────────────────────
                Column {
                    width: parent.width
                    spacing: 10
                    visible: root.draftPersonality === "jarvis"

                    Rectangle { width: parent.width; height: 1; color: Qt.rgba(1,1,1,0.07) }

                    Text {
                        text: "⚡ Modo Live"
                        font.family: Theme.fontSans
                        font.pixelSize: 13
                        font.weight: Font.Bold
                        color: root.draftLiveMode ? Theme.accent : Theme.textPrimary
                        Behavior on color { ColorAnimation { duration: 200 } }
                    }

                    Text {
                        width: parent.width
                        text: "Conversación en tiempo real usando Gemini Live API y Fish Audio WebSocket. El wake word \"Jarvis\" activa la sesión Live directamente."
                        font.family: Theme.fontSans
                        font.pixelSize: 11
                        color: Theme.textMuted
                        wrapMode: Text.Wrap
                    }

                    // Toggle ON/OFF
                    Rectangle {
                        width: 56; height: 28
                        radius: 14
                        color: root.draftLiveMode
                            ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.25)
                            : Qt.rgba(1, 1, 1, 0.07)
                        border.width: 1
                        border.color: root.draftLiveMode ? Theme.accent : Qt.rgba(1,1,1,0.15)
                        Behavior on color { ColorAnimation { duration: 200 } }
                        Behavior on border.color { ColorAnimation { duration: 200 } }

                        Rectangle {
                            id: liveToggleKnob
                            width: 20; height: 20
                            radius: 10
                            color: root.draftLiveMode ? Theme.accent : Qt.rgba(1,1,1,0.5)
                            anchors.verticalCenter: parent.verticalCenter
                            x: root.draftLiveMode ? parent.width - width - 4 : 4
                            Behavior on x     { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                            Behavior on color { ColorAnimation { duration: 200 } }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.draftLiveMode = !root.draftLiveMode
                        }
                    }

                    // Aviso cuando está activo
                    Rectangle {
                        width: parent.width
                        height: liveModeNote.implicitHeight + 18
                        radius: 12
                        visible: root.draftLiveMode
                        color: Qt.rgba(0.06, 0.55, 0.56, 0.12)
                        border.width: 1
                        border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.3)

                        Text {
                            id: liveModeNote
                            anchors { left: parent.left; right: parent.right;
                                      verticalCenter: parent.verticalCenter; margins: 10 }
                            text: "⚡ Di \"Jarvis\" para iniciar una sesión de voz en tiempo real. La sesión se cierra automáticamente tras 2 minutos de inactividad."
                            font.family: Theme.fontSans
                            font.pixelSize: 10
                            color: Theme.accent
                            wrapMode: Text.Wrap
                        }
                    }
                }

                Rectangle { width: parent.width; height: 1; color: Qt.rgba(1,1,1,0.07) }

                Text {
                    text: "Modelo de texto"
                    font.family: Theme.fontSans
                    font.pixelSize: 13
                    font.weight: Font.Bold
                    color: Theme.textPrimary
                }
                Text {
                    width: parent.width
                    text: (root.draftPersonality === "jarvis" ? "JARVIS" : "Minerva") + " usa exclusivamente Gemini. Puedes elegir un modelo conocido o escribir uno nuevo."
                    font.family: Theme.fontSans
                    font.pixelSize: 11
                    color: Theme.textMuted
                    wrapMode: Text.Wrap
                }
                Rectangle {
                    width: parent.width
                    height: 44
                    radius: 14
                    color: Qt.rgba(1, 1, 1, 0.055)
                    border.width: textModelInput.activeFocus ? 1.5 : 1
                    border.color: textModelInput.activeFocus ? Theme.accent : Qt.rgba(1, 1, 1, 0.08)
                    Behavior on border.color { ColorAnimation { duration: 150 } }

                    TextInput {
                        id: textModelInput
                        anchors { fill: parent; margins: 12 }
                        text: root.draftTextModel
                        onTextEdited: root.draftTextModel = text
                        font.family: Theme.fontMono
                        font.pixelSize: 12
                        color: Theme.textPrimary
                        selectionColor: Theme.accent
                        selectedTextColor: "#101013"
                        clip: true
                    }
                }
                Flow {
                    width: parent.width
                    spacing: 8
                    Repeater {
                        model: root.textModelOptions
                        delegate: OptionChip {
                            label: modelData
                            selected: root.draftTextModel === modelData
                            onChosen: root.draftTextModel = value
                        }
                    }
                }

                Rectangle { width: parent.width; height: 1; color: Qt.rgba(1,1,1,0.07) }

                Text {
                    text: "Proveedor de voz"
                    visible: root.draftPersonality === "minerva"
                    font.family: Theme.fontSans
                    font.pixelSize: 13
                    font.weight: Font.Bold
                    color: Theme.textPrimary
                }
                Flow {
                    visible: root.draftPersonality === "minerva"
                    width: parent.width
                    spacing: 8
                    Repeater {
                        model: [
                            { value: "fish", label: "Fish Audio" },
                            { value: "gemini", label: "Gemini TTS" },
                            { value: "piper", label: "Piper local" }
                        ]
                        delegate: OptionChip {
                            value: modelData.value
                            label: modelData.label
                            selected: root.draftTtsProvider === modelData.value
                            onChosen: root.selectTtsProvider(value)
                        }
                    }
                }

                Text {
                    text: "Modelo de voz"
                    visible: root.draftPersonality === "minerva"
                    font.family: Theme.fontSans
                    font.pixelSize: 13
                    font.weight: Font.Bold
                    color: Theme.textPrimary
                }
                Rectangle {
                    visible: root.draftPersonality === "minerva"
                    width: parent.width
                    height: 44
                    radius: 14
                    color: Qt.rgba(1, 1, 1, 0.055)
                    border.width: ttsModelInput.activeFocus ? 1.5 : 1
                    border.color: ttsModelInput.activeFocus ? Theme.accent : Qt.rgba(1, 1, 1, 0.08)
                    Behavior on border.color { ColorAnimation { duration: 150 } }

                    TextInput {
                        id: ttsModelInput
                        anchors { fill: parent; margins: 12 }
                        text: root.draftTtsModel
                        onTextEdited: root.draftTtsModel = text
                        readOnly: root.draftTtsProvider === "piper"
                        font.family: Theme.fontMono
                        font.pixelSize: 12
                        color: root.draftTtsProvider === "piper" ? Theme.textMuted : Theme.textPrimary
                        selectionColor: Theme.accent
                        selectedTextColor: "#101013"
                        clip: true
                    }
                }
                Flow {
                    visible: root.draftPersonality === "minerva"
                    width: parent.width
                    spacing: 8
                    Repeater {
                        model: root.ttsModelOptions
                        delegate: OptionChip {
                            label: modelData
                            selected: root.draftTtsModel === modelData
                            onChosen: root.draftTtsModel = value
                        }
                    }
                }

                Column {
                    width: parent.width
                    spacing: 8
                    visible: root.draftPersonality === "minerva" && root.draftTtsProvider === "gemini"
                    Text {
                        text: "Voz de Gemini TTS"
                        font.family: Theme.fontSans
                        font.pixelSize: 13
                        font.weight: Font.Bold
                        color: Theme.textPrimary
                    }
                    Rectangle {
                        width: parent.width
                        height: 44
                        radius: 14
                        color: Qt.rgba(1, 1, 1, 0.055)
                        border.width: geminiVoiceInput.activeFocus ? 1.5 : 1
                        border.color: geminiVoiceInput.activeFocus ? Theme.accent : Qt.rgba(1, 1, 1, 0.08)
                        Behavior on border.color { ColorAnimation { duration: 150 } }

                        TextInput {
                            id: geminiVoiceInput
                            anchors { fill: parent; margins: 12 }
                            text: root.draftGeminiVoice
                            onTextEdited: root.draftGeminiVoice = text
                            font.family: Theme.fontMono
                            font.pixelSize: 12
                            color: Theme.textPrimary
                            clip: true
                        }
                    }
                }

                Text {
                    width: parent.width
                    text: root.draftPersonality === "jarvis"
                        ? "La API key de Fish Audio y los demás secretos se conservan sin mostrarse aquí."
                        : "Las API keys, Voice ID y demás valores existentes se conservan sin mostrarse aquí."
                    font.family: Theme.fontSans
                    font.pixelSize: 10
                    color: Theme.textMuted
                    wrapMode: Text.Wrap
                }

                Item {
                    width: parent.width
                    height: 40
                    Row {
                        anchors.right: parent.right
                        spacing: 10

                        ActionButton {
                            label: "Cancelar"
                            onTriggered: root.closeRequested()
                        }
                        ActionButton {
                            label: "Guardar cambios"
                            primary: true
                            onTriggered: root.save()
                        }
                    }
                }
            }
        }

        // ══════════════════════════════════════════════════════════════════════
        // VISTA 2: GESTOR DE SERVIDORES MODEL CONTEXT PROTOCOL (MCP)
        // ══════════════════════════════════════════════════════════════════════
        Flickable {
            id: mcpFlickable
            visible: root.currentTab === "mcp"
            anchors {
                left: parent.left; right: parent.right
                top: settingsHeader.bottom; bottom: parent.bottom
            }
            contentWidth: width
            contentHeight: mcpContent.implicitHeight + 48
            boundsBehavior: Flickable.StopAtBounds
            clip: true

            Column {
                id: mcpContent
                width: parent.width - 48
                x: 24
                y: 20
                spacing: 16

                // Banner de Notificación de Estado / OAuth
                Rectangle {
                    width: parent.width
                    height: bannerText.implicitHeight + 18
                    radius: 12
                    visible: root.mcpStatusBannerText.length > 0
                    color: root.mcpStatusBannerType === "success"
                        ? Qt.rgba(0.55, 0.83, 0.61, 0.15)
                        : (root.mcpStatusBannerType === "error"
                            ? Qt.rgba(0.93, 0.53, 0.59, 0.15)
                            : Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.15))
                    border.width: 1
                    border.color: root.mcpStatusBannerType === "success"
                        ? Theme.success
                        : (root.mcpStatusBannerType === "error" ? Theme.danger : Theme.accent)

                    Text {
                        id: bannerText
                        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 12 }
                        text: root.mcpStatusBannerText
                        font.family: Theme.fontSans
                        font.pixelSize: 11
                        color: root.mcpStatusBannerType === "success"
                            ? Theme.success
                            : (root.mcpStatusBannerType === "error" ? Theme.danger : Theme.accent)
                        wrapMode: Text.Wrap
                    }
                }

                // Encabezado de la Sección MCP
                Row {
                    width: parent.width
                    Item {
                        width: parent.width - mcpActionRow.width
                        height: mcpTitleCol.implicitHeight
                        Column {
                            id: mcpTitleCol
                            width: parent.width
                            spacing: 4
                            Text {
                                text: "Conexiones MCP"
                                font.family: Theme.fontSans
                                font.pixelSize: 15
                                font.weight: Font.Bold
                                color: Theme.textPrimary
                            }
                            Text {
                                width: parent.width - 10
                                text: "Conecta servidores HTTP/SSE o comandos locales STDIO (npx, uvx, python) con herramientas externas."
                                font.family: Theme.fontSans
                                font.pixelSize: 11
                                color: Theme.textMuted
                                wrapMode: Text.Wrap
                            }
                        }
                    }

                    Row {
                        id: mcpActionRow
                        spacing: 8
                        anchors.verticalCenter: parent.verticalCenter

                        // Botón Sincronizar / Refrescar
                        Rectangle {
                            width: 36; height: 36; radius: 10
                            color: refreshArea.containsMouse ? Qt.rgba(1,1,1,0.1) : Qt.rgba(1,1,1,0.04)
                            border.width: 1; border.color: Qt.rgba(1,1,1,0.08)
                            Text {
                                anchors.centerIn: parent
                                text: "↻"
                                font.family: Theme.fontMono
                                font.pixelSize: 15
                                color: refreshArea.containsMouse ? Theme.accent : Theme.textMuted
                            }
                            MouseArea {
                                id: refreshArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (root.aiWidget && root.aiWidget.fetchMcpServers)
                                        root.aiWidget.fetchMcpServers()
                                }
                            }
                        }

                        // Botón Nuevo Servidor
                        ActionButton {
                            label: "+ Conectar servidor"
                            primary: true
                            onTriggered: root.openAddServer()
                        }
                    }
                }

                // ──────────────────────────────────────────────────────────────
                // FORMULARIO: AÑADIR O EDITAR SERVIDOR MCP
                // ──────────────────────────────────────────────────────────────
                Rectangle {
                    id: mcpFormCard
                    visible: root.showAddServerForm
                    width: parent.width
                    height: formCol.implicitHeight + 32
                    radius: 16
                    color: "#13131e"
                    border.width: 1
                    border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.35)

                    Column {
                        id: formCol
                        width: parent.width - 32
                        x: 16
                        y: 16
                        spacing: 12

                        // Cabecera del formulario
                        Row {
                            width: parent.width
                            Text {
                                text: root.editServerId ? "Editar Conexión MCP" : "Conectar Nuevo Servidor MCP"
                                font.family: Theme.fontSans
                                font.pixelSize: 13
                                font.weight: Font.Bold
                                color: Theme.accent
                            }
                            Item { width: parent.width - 24 - 150; height: 1 }
                        }

                        // 1. Nombre descriptivo
                        Text {
                            text: "Nombre descriptivo"
                            font.family: Theme.fontSans
                            font.pixelSize: 11
                            font.weight: Font.DemiBold
                            color: Theme.textPrimary
                        }
                        Rectangle {
                            width: parent.width; height: 38; radius: 10
                            color: Qt.rgba(1,1,1,0.05)
                            border.width: 1; border.color: nameInput.activeFocus ? Theme.accent : Qt.rgba(1,1,1,0.1)
                            TextInput {
                                id: nameInput
                                anchors { fill: parent; margins: 10 }
                                text: root.draftServerName
                                onTextEdited: root.draftServerName = text
                                font.family: Theme.fontSans
                                font.pixelSize: 12
                                color: Theme.textPrimary
                                clip: true
                            }
                        }

                        // 2. Tipo de transporte
                        Text {
                            text: "Transporte"
                            font.family: Theme.fontSans
                            font.pixelSize: 11
                            font.weight: Font.DemiBold
                            color: Theme.textPrimary
                        }
                        Row {
                            spacing: 8
                            Repeater {
                                model: [
                                    { value: "http",  label: "HTTP / SSE",        icon: "\U0001F310" },
                                    { value: "stdio", label: "STDIO (npx / uvx)", icon: "\U0001F4BB" }
                                ]
                                delegate: Rectangle {
                                    width: trRow.implicitWidth + 20
                                    height: 34
                                    radius: 9
                                    color: root.draftServerTransport === modelData.value
                                        ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
                                        : (trHov.containsMouse ? Qt.rgba(1,1,1,0.07) : Qt.rgba(1,1,1,0.04))
                                    border.width: 1
                                    border.color: root.draftServerTransport === modelData.value
                                        ? Theme.accent : Qt.rgba(1,1,1,0.09)
                                    Row {
                                        id: trRow
                                        anchors.centerIn: parent
                                        spacing: 6
                                        Text {
                                            text: modelData.icon
                                            font.pixelSize: 12
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                        Text {
                                            text: modelData.label
                                            font.family: Theme.fontSans
                                            font.pixelSize: 11
                                            font.weight: root.draftServerTransport === modelData.value ? Font.DemiBold : Font.Normal
                                            color: root.draftServerTransport === modelData.value ? Theme.accent : Theme.textMuted
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                    }
                                    MouseArea {
                                        id: trHov
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.draftServerTransport = modelData.value
                                    }
                                }
                            }
                        }

                        // 3a. URL del servidor (solo HTTP)
                        Column {
                            width: parent.width
                            spacing: 6
                            visible: root.draftServerTransport === "http"
                            Text {
                                text: "URL del servidor (HTTP o SSE)"
                                font.family: Theme.fontSans
                                font.pixelSize: 11
                                font.weight: Font.DemiBold
                                color: Theme.textPrimary
                            }
                            Rectangle {
                                width: parent.width; height: 38; radius: 10
                                color: Qt.rgba(1,1,1,0.05)
                                border.width: 1; border.color: urlInput.activeFocus ? Theme.accent : Qt.rgba(1,1,1,0.1)
                                TextInput {
                                    id: urlInput
                                    anchors { fill: parent; margins: 10 }
                                    text: root.draftServerUrl
                                    onTextEdited: root.draftServerUrl = text
                                    font.family: Theme.fontMono
                                    font.pixelSize: 11
                                    color: Theme.textPrimary
                                    clip: true
                                }
                            }
                        }

                        // 3b. Comando + Env Vars (solo STDIO)
                        Column {
                            width: parent.width
                            spacing: 6
                            visible: root.draftServerTransport === "stdio"

                            Text {
                                text: "Comando"
                                font.family: Theme.fontSans
                                font.pixelSize: 11
                                font.weight: Font.DemiBold
                                color: Theme.textPrimary
                            }
                            Rectangle {
                                width: parent.width; height: 38; radius: 10
                                color: Qt.rgba(1,1,1,0.05)
                                border.width: 1; border.color: cmdInput.activeFocus ? Theme.accent : Qt.rgba(1,1,1,0.1)
                                TextInput {
                                    id: cmdInput
                                    anchors { fill: parent; margins: 10 }
                                    text: root.draftServerCommand
                                    onTextEdited: root.draftServerCommand = text
                                    font.family: Theme.fontMono
                                    font.pixelSize: 11
                                    color: Theme.textPrimary
                                    clip: true
                                }
                            }
                            Text {
                                width: parent.width
                                text: "Ejemplos: npx -y @modelcontextprotocol/server-github    uvx mcp-server-fetch    python -m myserver"
                                font.family: Theme.fontSans
                                font.pixelSize: 10
                                color: Theme.textMuted
                                wrapMode: Text.Wrap
                            }

                            Text {
                                text: "Variables de entorno (API keys para el proceso)"
                                font.family: Theme.fontSans
                                font.pixelSize: 11
                                font.weight: Font.DemiBold
                                color: Theme.textPrimary
                                topPadding: 6
                            }
                            Rectangle {
                                width: parent.width
                                height: Math.max(envEdit.implicitHeight + 20, 70)
                                radius: 10
                                color: Qt.rgba(1,1,1,0.05)
                                border.width: 1
                                border.color: envEdit.activeFocus ? Theme.accent : Qt.rgba(1,1,1,0.1)
                                TextEdit {
                                    id: envEdit
                                    anchors { fill: parent; margins: 10 }
                                    text: root.draftServerEnvVars
                                    onTextChanged: root.draftServerEnvVars = text
                                    font.family: Theme.fontMono
                                    font.pixelSize: 11
                                    color: Theme.textPrimary
                                    wrapMode: TextEdit.Wrap
                                }
                            }
                            Text {
                                width: parent.width
                                text: "Una variable por linea: GITHUB_TOKEN=ghp_xxx    OPENAI_API_KEY=sk-xxx"
                                font.family: Theme.fontSans
                                font.pixelSize: 10
                                color: Theme.textMuted
                                wrapMode: Text.Wrap
                            }
                        }

                        // 4. Metodo de autenticacion (solo HTTP)
                        Column {
                            width: parent.width
                            spacing: 8
                            visible: root.draftServerTransport === "http"

                            Text {
                                text: "Autenticacion"
                                font.family: Theme.fontSans
                                font.pixelSize: 11
                                font.weight: Font.DemiBold
                                color: Theme.textPrimary
                            }
                            Flow {
                                width: parent.width
                                spacing: 8
                                Repeater {
                                    model: [
                                        { value: "none", label: "Sin autenticación" },
                                        { value: "bearer", label: "Token Bearer / API Key" },
                                        { value: "oauth2", label: "OAuth 2.0 (PKCE)" }
                                    ]
                                    delegate: OptionChip {
                                        value: modelData.value
                                        label: modelData.label
                                        selected: root.draftServerAuthType === modelData.value
                                        onChosen: root.draftServerAuthType = value
                                    }
                                }
                            }
                        }

                        // Caso: Token Bearer (solo HTTP)
                        Column {
                            width: parent.width
                            spacing: 6
                            visible: root.draftServerTransport === "http" && root.draftServerAuthType === "bearer"
                            Text {
                                text: "Token de acceso Bearer (Authorization: Bearer <token>)"
                                font.family: Theme.fontSans
                                font.pixelSize: 11
                                color: Theme.textMuted
                            }
                            Rectangle {
                                width: parent.width; height: 38; radius: 10
                                color: Qt.rgba(1,1,1,0.05)
                                border.width: 1; border.color: bearerInput.activeFocus ? Theme.accent : Qt.rgba(1,1,1,0.1)
                                TextInput {
                                    id: bearerInput
                                    anchors { fill: parent; margins: 10 }
                                    text: root.draftServerBearerToken
                                    onTextEdited: root.draftServerBearerToken = text
                                    font.family: Theme.fontMono
                                    font.pixelSize: 11
                                    color: Theme.textPrimary
                                    echoMode: TextInput.Password
                                    clip: true
                                }
                            }
                        }

                        // Caso: OAuth 2.0 (solo HTTP)
                        Column {
                            width: parent.width
                            spacing: 8
                            visible: root.draftServerTransport === "http" && root.draftServerAuthType === "oauth2"

                            // Plantillas rápidas
                            Row {
                                spacing: 8
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "Plantillas rápidas:"
                                    font.family: Theme.fontSans
                                    font.pixelSize: 10
                                    color: Theme.textMuted
                                }
                                OptionChip {
                                    label: "Google (Drive/Gmail)"
                                    onChosen: root.applyOAuthPreset("google")
                                }
                                OptionChip {
                                    label: "GitHub"
                                    onChosen: root.applyOAuthPreset("github")
                                }
                            }

                            // Client ID
                            Text { text: "Client ID"; font.pixelSize: 10; color: Theme.textMuted; font.family: Theme.fontSans }
                            Rectangle {
                                width: parent.width; height: 36; radius: 10; color: Qt.rgba(1,1,1,0.05)
                                border.width: 1; border.color: clientIdInput.activeFocus ? Theme.accent : Qt.rgba(1,1,1,0.1)
                                TextInput {
                                    id: clientIdInput
                                    anchors { fill: parent; margins: 8 }
                                    text: root.draftServerClientId
                                    onTextEdited: root.draftServerClientId = text
                                    font.family: Theme.fontMono; font.pixelSize: 11; color: Theme.textPrimary; clip: true
                                }
                            }

                            // Client Secret (opcional)
                            Text { text: "Client Secret (opcional para apps públicas con PKCE)"; font.pixelSize: 10; color: Theme.textMuted; font.family: Theme.fontSans }
                            Rectangle {
                                width: parent.width; height: 36; radius: 10; color: Qt.rgba(1,1,1,0.05)
                                border.width: 1; border.color: clientSecInput.activeFocus ? Theme.accent : Qt.rgba(1,1,1,0.1)
                                TextInput {
                                    id: clientSecInput
                                    anchors { fill: parent; margins: 8 }
                                    text: root.draftServerClientSecret
                                    onTextEdited: root.draftServerClientSecret = text
                                    font.family: Theme.fontMono; font.pixelSize: 11; color: Theme.textPrimary; echoMode: TextInput.Password; clip: true
                                }
                            }

                            // Auth URL
                            Text { text: "Authorization URL"; font.pixelSize: 10; color: Theme.textMuted; font.family: Theme.fontSans }
                            Rectangle {
                                width: parent.width; height: 36; radius: 10; color: Qt.rgba(1,1,1,0.05)
                                border.width: 1; border.color: authUrlInput.activeFocus ? Theme.accent : Qt.rgba(1,1,1,0.1)
                                TextInput {
                                    id: authUrlInput
                                    anchors { fill: parent; margins: 8 }
                                    text: root.draftServerAuthUrl
                                    onTextEdited: root.draftServerAuthUrl = text
                                    font.family: Theme.fontMono; font.pixelSize: 11; color: Theme.textPrimary; clip: true
                                }
                            }

                            // Token URL
                            Text { text: "Token URL"; font.pixelSize: 10; color: Theme.textMuted; font.family: Theme.fontSans }
                            Rectangle {
                                width: parent.width; height: 36; radius: 10; color: Qt.rgba(1,1,1,0.05)
                                border.width: 1; border.color: tokenUrlInput.activeFocus ? Theme.accent : Qt.rgba(1,1,1,0.1)
                                TextInput {
                                    id: tokenUrlInput
                                    anchors { fill: parent; margins: 8 }
                                    text: root.draftServerTokenUrl
                                    onTextEdited: root.draftServerTokenUrl = text
                                    font.family: Theme.fontMono; font.pixelSize: 11; color: Theme.textPrimary; clip: true
                                }
                            }

                            // Scopes
                            Text { text: "Scopes / Permisos (separados por espacio)"; font.pixelSize: 10; color: Theme.textMuted; font.family: Theme.fontSans }
                            Rectangle {
                                width: parent.width; height: 36; radius: 10; color: Qt.rgba(1,1,1,0.05)
                                border.width: 1; border.color: scopesInput.activeFocus ? Theme.accent : Qt.rgba(1,1,1,0.1)
                                TextInput {
                                    id: scopesInput
                                    anchors { fill: parent; margins: 8 }
                                    text: root.draftServerScopes
                                    onTextEdited: root.draftServerScopes = text
                                    font.family: Theme.fontMono; font.pixelSize: 11; color: Theme.textPrimary; clip: true
                                }
                            }

                            // Botón de autenticación OAuth en navegador
                            Rectangle {
                                width: parent.width
                                height: 38
                                radius: 10
                                color: Qt.rgba(0.9, 0.78, 0.53, 0.14)
                                border.width: 1
                                border.color: Qt.rgba(0.9, 0.78, 0.53, 0.4)

                                Row {
                                    anchors.centerIn: parent
                                    spacing: 8
                                    Text { text: "🔑"; font.pixelSize: 13 }
                                    Text {
                                        text: "Iniciar sesión en el navegador con OAuth 2.0"
                                        font.family: Theme.fontSans
                                        font.pixelSize: 11
                                        font.weight: Font.DemiBold
                                        color: Theme.warning
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.triggerOAuthFromForm()
                                }
                            }
                        }

                        // Botones de acción del formulario
                        Item {
                            width: parent.width
                            height: 40
                            Row {
                                anchors.right: parent.right
                                spacing: 10
                                ActionButton {
                                    label: "Cancelar"
                                    onTriggered: root.showAddServerForm = false
                                }
                                ActionButton {
                                    label: "Guardar y Conectar"
                                    primary: true
                                    onTriggered: root.saveDraftServer()
                                }
                            }
                        }
                    }
                }

                // ──────────────────────────────────────────────────────────────
                // LISTADO DE SERVIDORES CONECTADOS
                // ──────────────────────────────────────────────────────────────

                // Estado vacío (cuando no hay servidores)
                Rectangle {
                    visible: !root.showAddServerForm && (!root.aiWidget || !root.aiWidget.mcpServers || root.aiWidget.mcpServers.length === 0)
                    width: parent.width
                    height: 160
                    radius: 16
                    color: Qt.rgba(1, 1, 1, 0.02)
                    border.width: 1
                    border.color: Qt.rgba(1, 1, 1, 0.06)

                    Column {
                        anchors.centerIn: parent
                        spacing: 8

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "🔌"
                            font.pixelSize: 26
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "No hay servidores MCP configurados"
                            font.family: Theme.fontSans
                            font.pixelSize: 13
                            font.weight: Font.Bold
                            color: Theme.textPrimary
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "Añade una URL HTTP/SSE o un comando STDIO para que Minerva descubra sus herramientas."
                            font.family: Theme.fontSans
                            font.pixelSize: 11
                            color: Theme.textMuted
                        }
                    }
                }

                // Tarjetas de servidores
                Column {
                    width: parent.width
                    spacing: 12
                    visible: root.aiWidget && root.aiWidget.mcpServers && root.aiWidget.mcpServers.length > 0

                    Repeater {
                        model: (root.aiWidget && root.aiWidget.mcpServers) ? root.aiWidget.mcpServers : []
                        delegate: Rectangle {
                            id: serverCard
                            width: parent.width
                            height: cardContentCol.implicitHeight + 28
                            radius: 16
                            color: "#11111a"
                            border.width: 1
                            border.color: modelData.status === "error"
                                ? Qt.rgba(0.93, 0.53, 0.59, 0.25)
                                : Qt.rgba(1, 1, 1, 0.08)

                            Column {
                                id: cardContentCol
                                width: parent.width - 32
                                x: 16
                                y: 14
                                spacing: 10

                                // Fila Superior: Estado + Nombre + Badges + Toggle
                                Item {
                                    width: parent.width
                                    height: 24

                                    Row {
                                        spacing: 10
                                        anchors.left: parent.left
                                        anchors.right: serverToggleSwitch.left
                                        anchors.rightMargin: 12
                                        anchors.verticalCenter: parent.verticalCenter
                                        clip: true

                                        // Punto de Estado
                                        Rectangle {
                                            width: 10; height: 10; radius: 5
                                            anchors.verticalCenter: parent.verticalCenter
                                            color: !modelData.enabled
                                                ? Theme.textMuted
                                                : (modelData.status === "connected"
                                                    ? Theme.success
                                                    : (modelData.status === "error" ? Theme.danger : Theme.warning))
                                        }

                                        // Nombre
                                        Text {
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: modelData.name || "Servidor MCP"
                                            font.family: Theme.fontSans
                                            font.pixelSize: 13
                                            font.weight: Font.Bold
                                            color: modelData.enabled ? Theme.textPrimary : Theme.textMuted
                                        }

                                        // Badge de Transporte
                                        Rectangle {
                                            anchors.verticalCenter: parent.verticalCenter
                                            height: 20
                                            width: transBadgeLabel.implicitWidth + 12
                                            radius: 6
                                            color: modelData.transport === "stdio"
                                                ? Qt.rgba(0.5, 0.8, 1.0, 0.12)
                                                : Qt.rgba(1, 1, 1, 0.06)
                                            Text {
                                                id: transBadgeLabel
                                                anchors.centerIn: parent
                                                text: modelData.transport === "stdio" ? "STDIO" : "HTTP"
                                                font.family: Theme.fontMono
                                                font.pixelSize: 9
                                                font.weight: Font.Bold
                                                color: modelData.transport === "stdio"
                                                    ? Qt.rgba(0.5, 0.8, 1.0, 0.9)
                                                    : Theme.textMuted
                                            }
                                        }

                                        // Badge de Autenticación (solo HTTP)
                                        Rectangle {
                                            anchors.verticalCenter: parent.verticalCenter
                                            height: 20
                                            width: authBadgeLabel.implicitWidth + 12
                                            radius: 6
                                            visible: (modelData.transport || "http") === "http"
                                            color: Qt.rgba(1, 1, 1, 0.06)
                                            Text {
                                                id: authBadgeLabel
                                                anchors.centerIn: parent
                                                text: modelData.auth_type === "oauth2"
                                                    ? "OAuth 2.0"
                                                    : (modelData.auth_type === "bearer" ? "Bearer Token" : "Publico")
                                                font.family: Theme.fontSans
                                                font.pixelSize: 9
                                                color: Theme.textMuted
                                            }
                                        }

                                        // Badge de Cantidad de Herramientas
                                        Rectangle {
                                            anchors.verticalCenter: parent.verticalCenter
                                            height: 20
                                            width: toolsBadgeLabel.implicitWidth + 12
                                            radius: 6
                                            color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.12)
                                            Text {
                                                id: toolsBadgeLabel
                                                anchors.centerIn: parent
                                                text: (modelData.tools ? modelData.tools.length : 0) + " herramientas"
                                                font.family: Theme.fontMono
                                                font.pixelSize: 9
                                                font.weight: Font.Bold
                                                color: Theme.accent
                                            }
                                        }
                                    }

                                    // Switch Activar / Desactivar
                                    Rectangle {
                                        id: serverToggleSwitch
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 44; height: 24
                                        radius: 12
                                        color: modelData.enabled
                                            ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.25)
                                            : Qt.rgba(1, 1, 1, 0.08)
                                        border.width: 1
                                        border.color: modelData.enabled ? Theme.accent : Qt.rgba(1,1,1,0.15)
                                        Behavior on color { ColorAnimation { duration: 150 } }

                                        Rectangle {
                                            width: 16; height: 16; radius: 8
                                            anchors.verticalCenter: parent.verticalCenter
                                            x: modelData.enabled ? parent.width - width - 4 : 4
                                            color: modelData.enabled ? Theme.accent : Qt.rgba(1, 1, 1, 0.4)
                                            Behavior on x { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                if (root.aiWidget && root.aiWidget.toggleMcpServer) {
                                                    root.aiWidget.toggleMcpServer(modelData.id, !modelData.enabled)
                                                }
                                            }
                                        }
                                    }
                                }

                                // Fila Central: URL o Comando
                                Text {
                                    width: parent.width
                                    text: modelData.transport === "stdio"
                                        ? (modelData.command || "")
                                        : (modelData.url || "")
                                    font.family: Theme.fontMono
                                    font.pixelSize: 11
                                    color: Theme.textMuted
                                    elide: Text.ElideRight
                                }

                                // Mensaje de Error (si aplica)
                                Rectangle {
                                    width: parent.width
                                    height: errText.implicitHeight + 12
                                    radius: 8
                                    visible: modelData.status === "error" && (modelData.error_message || "").length > 0
                                    color: Qt.rgba(0.93, 0.53, 0.59, 0.1)
                                    border.width: 1; border.color: Qt.rgba(0.93, 0.53, 0.59, 0.3)
                                    Text {
                                        id: errText
                                        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 8 }
                                        text: modelData.error_message || ""
                                        font.family: Theme.fontSans
                                        font.pixelSize: 10
                                        color: Theme.danger
                                        wrapMode: Text.Wrap
                                    }
                                }

                                // Fila Inferior: Botones de Acción
                                Row {
                                    spacing: 8

                                    // Botón Ver Herramientas
                                    Rectangle {
                                        height: 28
                                        width: viewToolsLabel.implicitWidth + 18
                                        radius: 8
                                        color: root.expandedServerIds[modelData.id]
                                            ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.2)
                                            : (toolsBtnArea.containsMouse ? Qt.rgba(1,1,1,0.08) : Qt.rgba(1,1,1,0.04))
                                        border.width: 1; border.color: root.expandedServerIds[modelData.id] ? Theme.accent : Qt.rgba(1,1,1,0.08)

                                        Row {
                                            id: viewToolsLabel
                                            anchors.centerIn: parent
                                            spacing: 5
                                            Text {
                                                text: root.expandedServerIds[modelData.id] ? "▾" : "▸"
                                                font.pixelSize: 10
                                                color: Theme.accent
                                            }
                                            Text {
                                                text: "Herramientas"
                                                font.family: Theme.fontSans
                                                font.pixelSize: 10
                                                color: Theme.textPrimary
                                            }
                                        }

                                        MouseArea {
                                            id: toolsBtnArea
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.toggleExpandTools(modelData.id)
                                        }
                                    }

                                    // Botón Probar / Sincronizar
                                    Rectangle {
                                        height: 28; width: syncLabel.implicitWidth + 16; radius: 8
                                        color: syncBtnArea.containsMouse ? Qt.rgba(1,1,1,0.08) : Qt.rgba(1,1,1,0.04)
                                        border.width: 1; border.color: Qt.rgba(1,1,1,0.08)
                                        Text {
                                            id: syncLabel
                                            anchors.centerIn: parent
                                            text: "↻ Probar"
                                            font.family: Theme.fontSans
                                            font.pixelSize: 10
                                            color: Theme.textPrimary
                                        }
                                        MouseArea {
                                            id: syncBtnArea
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                if (root.aiWidget && root.aiWidget.testMcpServer) {
                                                    root.aiWidget.testMcpServer(modelData.id)
                                                    root.setBanner("Probando conexión con " + modelData.name + "...", "info")
                                                }
                                            }
                                        }
                                    }

                                    // Botón OAuth (si el servidor usa OAuth 2.0)
                                    Rectangle {
                                        visible: modelData.auth_type === "oauth2"
                                        height: 28; width: oauthBtnText.implicitWidth + 16; radius: 8
                                        color: Qt.rgba(0.9, 0.78, 0.53, 0.12)
                                        border.width: 1; border.color: Qt.rgba(0.9, 0.78, 0.53, 0.3)
                                        Text {
                                            id: oauthBtnText
                                            anchors.centerIn: parent
                                            text: "🔑 Re-autenticar"
                                            font.family: Theme.fontSans
                                            font.pixelSize: 10
                                            color: Theme.warning
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                if (root.aiWidget && root.aiWidget.startMcpOAuth) {
                                                    root.aiWidget.startMcpOAuth(modelData.id)
                                                }
                                            }
                                        }
                                    }

                                    // Botón Editar
                                    Rectangle {
                                        height: 28; width: editLabel.implicitWidth + 16; radius: 8
                                        color: editBtnArea.containsMouse ? Qt.rgba(1,1,1,0.08) : Qt.rgba(1,1,1,0.04)
                                        border.width: 1; border.color: Qt.rgba(1,1,1,0.08)
                                        Text {
                                            id: editLabel
                                            anchors.centerIn: parent
                                            text: "✎ Editar"
                                            font.family: Theme.fontSans
                                            font.pixelSize: 10
                                            color: Theme.textPrimary
                                        }
                                        MouseArea {
                                            id: editBtnArea
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.openEditServer(modelData)
                                        }
                                    }

                                    // Botón Eliminar
                                    Rectangle {
                                        height: 28; width: delLabel.implicitWidth + 16; radius: 8
                                        color: delBtnArea.containsMouse ? Qt.rgba(0.93, 0.53, 0.59, 0.15) : Qt.rgba(1,1,1,0.04)
                                        border.width: 1; border.color: delBtnArea.containsMouse ? Theme.danger : Qt.rgba(1,1,1,0.08)
                                        Text {
                                            id: delLabel
                                            anchors.centerIn: parent
                                            text: "🗑 Eliminar"
                                            font.family: Theme.fontSans
                                            font.pixelSize: 10
                                            color: delBtnArea.containsMouse ? Theme.danger : Theme.textMuted
                                        }
                                        MouseArea {
                                            id: delBtnArea
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                if (root.aiWidget && root.aiWidget.deleteMcpServer) {
                                                    root.aiWidget.deleteMcpServer(modelData.id)
                                                }
                                            }
                                        }
                                    }
                                }

                                // ──────────────────────────────────────────────
                                // LISTA EXPANDIBLE DE HERRAMIENTAS
                                // ──────────────────────────────────────────────
                                Column {
                                    width: parent.width
                                    spacing: 6
                                    visible: root.expandedServerIds[modelData.id] === true

                                    Rectangle { width: parent.width; height: 1; color: Qt.rgba(1,1,1,0.06) }

                                    Text {
                                        text: "Herramientas expuestas por este servidor:"
                                        font.family: Theme.fontSans
                                        font.pixelSize: 11
                                        font.weight: Font.DemiBold
                                        color: Theme.textMuted
                                    }

                                    // Si no hay herramientas descubiertas
                                    Text {
                                        visible: !modelData.tools || modelData.tools.length === 0
                                        text: "Aún no se han descubierto herramientas. Pulsa 'Probar' para conectar."
                                        font.family: Theme.fontSans
                                        font.pixelSize: 10
                                        color: Theme.textMuted
                                    }

                                    Repeater {
                                        model: modelData.tools || []
                                        delegate: Rectangle {
                                            width: parent.width
                                            height: toolItemCol.implicitHeight + 12
                                            radius: 8
                                            color: Qt.rgba(1, 1, 1, 0.03)
                                            border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.05)

                                            Column {
                                                id: toolItemCol
                                                width: parent.width - 16
                                                x: 8
                                                y: 6
                                                spacing: 2

                                                Row {
                                                    spacing: 6
                                                    Text {
                                                        text: "•"
                                                        color: Theme.accent
                                                        font.pixelSize: 12
                                                    }
                                                    Text {
                                                        text: modelData.name || ""
                                                        font.family: Theme.fontMono
                                                        font.pixelSize: 11
                                                        font.weight: Font.Bold
                                                        color: Theme.accent
                                                    }
                                                }
                                                Text {
                                                    width: parent.width - 14
                                                    x: 14
                                                    text: modelData.description || "Sin descripción"
                                                    font.family: Theme.fontSans
                                                    font.pixelSize: 10
                                                    color: Theme.textMuted
                                                    wrapMode: Text.Wrap
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ── Componentes Reutilizables ─────────────────────────────────────────────

    component OptionChip: Rectangle {
        property string value: label
        property string label: ""
        property bool selected: false
        signal chosen(string value)

        width: optionLabel.implicitWidth + 28
        height: 34
        radius: 14
        color: selected
            ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
            : (optionArea.containsMouse ? Qt.rgba(1,1,1,0.09) : Qt.rgba(1,1,1,0.045))
        border.width: 1
        border.color: selected ? Theme.accent : Qt.rgba(1,1,1,0.09)

        Behavior on color { ColorAnimation { duration: 150 } }
        Behavior on border.color { ColorAnimation { duration: 150 } }

        Text {
            id: optionLabel
            anchors.centerIn: parent
            text: parent.label
            font.family: Theme.fontMono
            font.pixelSize: 11
            color: parent.selected ? Theme.accent : Theme.textMuted
            Behavior on color { ColorAnimation { duration: 150 } }
        }
        MouseArea {
            id: optionArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: parent.chosen(parent.value)
        }
    }

    component ActionButton: Rectangle {
        property string label: ""
        property bool primary: false
        signal triggered()

        width: actionLabel.implicitWidth + 32
        height: 40
        radius: 14
        color: primary
            ? (actionArea.containsMouse ? "#92e5e7" : Theme.accent)
            : (actionArea.containsMouse ? Qt.rgba(1,1,1,0.1) : Qt.rgba(1,1,1,0.055))
        border.width: primary ? 0 : 1
        border.color: Qt.rgba(1,1,1,0.1)

        Behavior on color { ColorAnimation { duration: 150 } }

        Text {
            id: actionLabel
            anchors.centerIn: parent
            text: parent.label
            font.family: Theme.fontSans
            font.pixelSize: 12
            font.weight: Font.DemiBold
            color: parent.primary ? "#102526" : Theme.textPrimary
        }
        MouseArea {
            id: actionArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: parent.triggered()
        }
    }
}

