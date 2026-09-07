import QtQuick

Item {
    id: root

    property var aiWidget: null
    property string draftTextModel: ""
    property string draftTtsProvider: "fish"
    property string draftTtsModel: ""
    property string draftGeminiVoice: "Kore"
    signal closeRequested()

    readonly property int contentHeight: settingsHeader.height + settingsContent.implicitHeight + 48

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
        draftTextModel = aiWidget.geminiModel
        draftTtsProvider = aiWidget.ttsProvider
        draftGeminiVoice = aiWidget.geminiTtsVoice
        if (draftTtsProvider === "fish")
            draftTtsModel = aiWidget.fishModel
        else if (draftTtsProvider === "gemini")
            draftTtsModel = aiWidget.geminiTtsModel
        else
            draftTtsModel = "es_MX-claude-high"
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
        aiWidget.ttsProvider = draftTtsProvider
        if (draftTtsProvider === "fish" && ttsModel)
            aiWidget.fishModel = ttsModel
        else if (draftTtsProvider === "gemini" && ttsModel) {
            aiWidget.geminiTtsModel = ttsModel
            aiWidget.geminiTtsVoice = draftGeminiVoice.trim() || "Kore"
        }
        aiWidget.saveSettings()
        closeRequested()
    }

    onVisibleChanged: {
        if (visible) {
            syncFromService()
            forceActiveFocus()
        }
    }

    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
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

        Rectangle {
            id: settingsHeader
            anchors { left: parent.left; right: parent.right; top: parent.top }
            height: 56
            color: "transparent"

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width; height: 1
                color: Qt.rgba(1, 1, 1, 0.07)
            }

            Row {
                anchors { left: parent.left; leftMargin: 20; verticalCenter: parent.verticalCenter }
                spacing: 10

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "⚙"
                    font.family: Theme.fontSans
                    font.pixelSize: 18
                    color: Theme.accent
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Configuración de Minerva"
                    font.family: Theme.fontSans
                    font.pixelSize: 14
                    font.weight: Font.Bold
                    color: Theme.textPrimary
                }
            }

            Rectangle {
                anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
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

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width; height: 1
                color: Qt.rgba(1, 1, 1, 0.07)
            }
        }

        Flickable {
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
                    text: "Modelo de texto"
                    font.family: Theme.fontSans
                    font.pixelSize: 13
                    font.weight: Font.Bold
                    color: Theme.textPrimary
                }
                Text {
                    width: parent.width
                    text: "Minerva usa exclusivamente Gemini. Puedes elegir un modelo conocido o escribir uno nuevo."
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
                    font.family: Theme.fontSans
                    font.pixelSize: 13
                    font.weight: Font.Bold
                    color: Theme.textPrimary
                }
                Flow {
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
                    visible: root.draftTtsProvider === "gemini"
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
                    text: "Las API keys, Voice ID y demás valores existentes se conservan sin mostrarse aquí."
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
    }

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
