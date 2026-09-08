import QtQuick
import Quickshell

Rectangle {
    id: root

    required property var aiWidget

    visible: aiWidget ? aiWidget.showConfirm : false
    color: Qt.rgba(0, 0, 0, 0.75)
    radius: 22
    opacity: visible ? 1.0 : 0.0

    Behavior on opacity { NumberAnimation { duration: 180 } }

    // Intercept clicks on the backdrop so clicks don't hit underlying chat
    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        preventStealing: true
        onClicked: { /* modal backdrop blocker */ }
    }

    // Keyboard navigation
    focus: visible
    onVisibleChanged: {
        if (visible) {
            root.forceActiveFocus()
        }
    }
    Keys.onEscapePressed: (event) => {
        root.cancelPendingCommand()
        event.accepted = true
    }
    Keys.onReturnPressed: (event) => {
        root.executePendingCommand()
        event.accepted = true
    }
    Keys.onEnterPressed: (event) => {
        root.executePendingCommand()
        event.accepted = true
    }

    property bool isCopied: false
    Timer {
        id: copyTimer
        interval: 2000
        onTriggered: root.isCopied = false
    }

    function copyCommand() {
        if (!root.aiWidget || !root.aiWidget.pendingCmd) return
        Quickshell.execDetached(["wl-copy", "--", root.aiWidget.pendingCmd])
        root.isCopied = true
        copyTimer.restart()
    }

    // Modal Card
    Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.min(parent.width - 32, 640)

        // Geometry bounds
        readonly property int maxHeight: Math.max(200, parent.height - 36)
        readonly property int headerAreaHeight: headerBox.implicitHeight + 28
        readonly property int footerAreaHeight: 64
        readonly property int chromeHeight: headerAreaHeight + footerAreaHeight
        readonly property int maxCommandBoxHeight: Math.max(80, maxHeight - chromeHeight)

        // Command box natural content height (content + top bar 32px + margins)
        readonly property int commandContentHeight: (cmdFlickContent.implicitHeight || 40) + 48

        // Desired dialog height (bounded to maxHeight)
        height: Math.min(maxHeight, chromeHeight + Math.min(maxCommandBoxHeight, Math.max(90, commandContentHeight)))

        radius: 18
        color: "#131320"
        border.width: 1
        border.color: (root.aiWidget && root.aiWidget.pendingIsSudo)
                      ? Qt.rgba(0.95, 0.55, 0.2, 0.75)
                      : Qt.rgba(0.95, 0.65, 0.2, 0.55)
        clip: true

        // Header
        Item {
            id: headerBox
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.topMargin: 16
            anchors.leftMargin: 20
            anchors.rightMargin: 20
            implicitHeight: headerCol.implicitHeight

            Column {
                id: headerCol
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: 6

                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 8

                    Text {
                        text: (root.aiWidget && root.aiWidget.pendingIsSudo) ? "󰌞" : "󰀦"
                        font.family: Theme.fontMono
                        font.pixelSize: 24
                        color: (root.aiWidget && root.aiWidget.pendingIsSudo) ? Theme.danger : Theme.warning
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: (root.aiWidget && root.aiWidget.pendingIsSudo)
                              ? "Permisos elevados (sudo)"
                              : "¿Confirmar ejecución de comando?"
                        font.family: Theme.fontSans
                        font.pixelSize: 15
                        font.weight: Font.Bold
                        color: Theme.textPrimary
                    }
                }

                Text {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    text: (root.aiWidget && root.aiWidget.pendingReason)
                          ? root.aiWidget.pendingReason
                          : "Este comando requiere tu confirmación antes de ser ejecutado en el sistema."
                    font.family: Theme.fontSans
                    font.pixelSize: 12
                    color: Theme.textMuted
                    wrapMode: Text.Wrap
                    horizontalAlignment: Text.AlignHCenter
                }
            }
        }

        // Terminal / Command Area
        Rectangle {
            id: commandContainer
            anchors.top: headerBox.bottom
            anchors.bottom: footerBox.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.topMargin: 12
            anchors.bottomMargin: 12
            anchors.leftMargin: 18
            anchors.rightMargin: 18
            radius: 10
            color: Qt.rgba(0.04, 0.04, 0.08, 0.95)
            border.width: 1
            border.color: (root.aiWidget && root.aiWidget.pendingIsSudo)
                          ? Qt.rgba(Theme.warning.r, Theme.warning.g, Theme.warning.b, 0.35)
                          : Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.25)
            clip: true

            // Terminal Bar
            Rectangle {
                id: terminalBar
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                height: 32
                color: Qt.rgba(0.1, 0.1, 0.15, 0.9)
                border.width: 1
                border.color: Qt.rgba(1, 1, 1, 0.06)

                Row {
                    anchors.left: parent.left
                    anchors.leftMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6

                    Text {
                        text: "󰆍"
                        font.family: Theme.fontMono
                        font.pixelSize: 13
                        color: (root.aiWidget && root.aiWidget.pendingIsSudo) ? Theme.warning : Theme.accent
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                        text: (root.aiWidget && root.aiWidget.pendingIsSudo) ? "bash (sudo)" : "bash"
                        font.family: Theme.fontMono
                        font.pixelSize: 11
                        color: Theme.textMuted
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    // Line counter badge
                    Text {
                        readonly property int lineCount: (root.aiWidget && root.aiWidget.pendingCmd)
                                                          ? root.aiWidget.pendingCmd.split("\n").length : 1
                        text: "• " + lineCount + (lineCount === 1 ? " línea" : " líneas")
                        font.family: Theme.fontSans
                        font.pixelSize: 11
                        color: Theme.textMuted
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                // Copy button
                Rectangle {
                    anchors.right: parent.right
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    height: 24
                    width: copyBtnContent.implicitWidth + 16
                    radius: 6
                    color: copyArea.containsMouse
                           ? Qt.rgba(1, 1, 1, 0.14)
                           : Qt.rgba(1, 1, 1, 0.06)
                    border.width: 1
                    border.color: root.isCopied
                                  ? Qt.rgba(Theme.success.r, Theme.success.g, Theme.success.b, 0.6)
                                  : Qt.rgba(1, 1, 1, 0.12)

                    Row {
                        id: copyBtnContent
                        anchors.centerIn: parent
                        spacing: 4
                        Text {
                            text: root.isCopied ? "󰄬" : "󰅍"
                            font.family: Theme.fontMono
                            font.pixelSize: 11
                            color: root.isCopied ? Theme.success : Theme.textMuted
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            text: root.isCopied ? "¡Copiado!" : "Copiar"
                            font.family: Theme.fontSans
                            font.pixelSize: 11
                            color: root.isCopied ? Theme.success : Theme.textMuted
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    MouseArea {
                        id: copyArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.copyCommand()
                    }
                }
            }

            // Scrollable Code Content
            Flickable {
                id: codeFlickable
                anchors.top: terminalBar.bottom
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: 8
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                contentWidth: width
                contentHeight: cmdFlickContent.implicitHeight + 8

                TextEdit {
                    id: cmdFlickContent
                    width: codeFlickable.width - ((codeFlickable.contentHeight > codeFlickable.height) ? 14 : 4)
                    text: "$ " + (root.aiWidget ? root.aiWidget.pendingCmd : "")
                    font.family: Theme.fontMono
                    font.pixelSize: 12
                    color: (root.aiWidget && root.aiWidget.pendingIsSudo) ? Theme.warning : Theme.accent
                    wrapMode: TextEdit.Wrap
                    readOnly: true
                    selectByMouse: true
                    selectionColor: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.35)
                }

                // Vertical scrollbar indicator
                Rectangle {
                    id: scrollTrack
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    anchors.right: parent.right
                    anchors.topMargin: 2
                    anchors.bottomMargin: 2
                    anchors.rightMargin: 1
                    width: 5
                    radius: 3
                    color: Qt.rgba(1, 1, 1, 0.08)
                    visible: codeFlickable.contentHeight > codeFlickable.height

                    Rectangle {
                        id: scrollThumb
                        width: parent.width
                        radius: 3
                        color: Qt.rgba(1, 1, 1, 0.35)
                        height: Math.max(20, codeFlickable.height * (codeFlickable.height / Math.max(1, codeFlickable.contentHeight)))
                        y: (codeFlickable.contentHeight > codeFlickable.height)
                           ? (codeFlickable.contentY / (codeFlickable.contentHeight - codeFlickable.height)) * (scrollTrack.height - height)
                           : 0

                        MouseArea {
                            anchors.fill: parent
                            drag.target: scrollThumb
                            drag.axis: Drag.YAxis
                            drag.minimumY: 0
                            drag.maximumY: scrollTrack.height - scrollThumb.height
                            onPositionChanged: {
                                if (drag.active && (scrollTrack.height - scrollThumb.height) > 0) {
                                    const ratio = scrollThumb.y / (scrollTrack.height - scrollThumb.height)
                                    codeFlickable.contentY = ratio * (codeFlickable.contentHeight - codeFlickable.height)
                                }
                            }
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        z: -1
                        onClicked: (mouse) => {
                            const ratio = mouse.y / height
                            codeFlickable.contentY = ratio * (codeFlickable.contentHeight - codeFlickable.height)
                        }
                    }
                }
            }
        }

        // Footer with Action Buttons (ALWAYS PINNED TO BOTTOM)
        Item {
            id: footerBox
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: 52

            Row {
                anchors.centerIn: parent
                spacing: 14

                // Cancel Button
                Rectangle {
                    width: 130
                    height: 36
                    radius: 10
                    color: cancelArea.containsMouse
                           ? Qt.rgba(0.4, 0.12, 0.12, 0.5)
                           : Qt.rgba(0.2, 0.2, 0.25, 0.5)
                    border.width: 1
                    border.color: cancelArea.containsMouse
                                  ? Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.6)
                                  : Qt.rgba(1, 1, 1, 0.18)

                    Behavior on color { ColorAnimation { duration: 120 } }
                    Behavior on border.color { ColorAnimation { duration: 120 } }

                    Row {
                        anchors.centerIn: parent
                        spacing: 6
                        Text {
                            text: "󰅖"
                            font.family: Theme.fontMono
                            font.pixelSize: 12
                            color: cancelArea.containsMouse ? Theme.danger : Theme.textPrimary
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            text: "Cancelar (Esc)"
                            font.family: Theme.fontSans
                            font.pixelSize: 12
                            font.weight: Font.Medium
                            color: cancelArea.containsMouse ? Theme.danger : Theme.textPrimary
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    MouseArea {
                        id: cancelArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.cancelPendingCommand()
                    }
                }

                // Execute Button
                Rectangle {
                    width: (root.aiWidget && root.aiWidget.pendingIsSudo) ? 200 : 180
                    height: 36
                    radius: 10
                    color: executeArea.containsMouse
                           ? ((root.aiWidget && root.aiWidget.pendingIsSudo)
                              ? Qt.rgba(0.85, 0.45, 0.1, 0.8)
                              : Qt.rgba(0.18, 0.55, 0.22, 0.85))
                           : ((root.aiWidget && root.aiWidget.pendingIsSudo)
                              ? Qt.rgba(0.65, 0.32, 0.05, 0.6)
                              : Qt.rgba(0.12, 0.38, 0.15, 0.7))
                    border.width: 1
                    border.color: (root.aiWidget && root.aiWidget.pendingIsSudo)
                                  ? Qt.rgba(Theme.warning.r, Theme.warning.g, Theme.warning.b, 0.8)
                                  : Qt.rgba(Theme.success.r, Theme.success.g, Theme.success.b, 0.8)

                    Behavior on color { ColorAnimation { duration: 120 } }

                    Row {
                        anchors.centerIn: parent
                        spacing: 6
                        Text {
                            text: (root.aiWidget && root.aiWidget.pendingIsSudo) ? "󰌞" : "󰄬"
                            font.family: Theme.fontMono
                            font.pixelSize: 13
                            color: (root.aiWidget && root.aiWidget.pendingIsSudo) ? Theme.warning : Theme.success
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            text: (root.aiWidget && root.aiWidget.pendingIsSudo)
                                  ? "Ejecutar (pkexec)"
                                  : "Ejecutar comando"
                            font.family: Theme.fontSans
                            font.pixelSize: 12
                            font.weight: Font.DemiBold
                            color: (root.aiWidget && root.aiWidget.pendingIsSudo) ? Theme.warning : Theme.success
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    MouseArea {
                        id: executeArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.executePendingCommand()
                    }
                }
            }
        }
    }

    function cancelPendingCommand() {
        if (!aiWidget) return
        const jobId = aiWidget.pendingJobId || ""
        for (let i = aiWidget.msgModel.count - 1; i >= 0; i--) {
            const item = aiWidget.msgModel.get(i)
            if (item.role === "command" && item.jobId === jobId) {
                aiWidget.msgModel.setProperty(i, "cmdStatus", "cancelled")
                break
            }
        }
        aiWidget.cancelJob(jobId)
        aiWidget.resolveApproval(jobId)
    }

    function executePendingCommand() {
        if (!aiWidget) return
        const jobId = aiWidget.pendingJobId || ""
        aiWidget.showConfirm = false
        for (let i = aiWidget.msgModel.count - 1; i >= 0; i--) {
            const item = aiWidget.msgModel.get(i)
            if (item.role === "command" && item.jobId === jobId) {
                aiWidget.msgModel.setProperty(i, "cmdStatus", "running")
                break
            }
        }
        if (aiWidget.pendingIsSudo) {
            aiWidget.sudoRun(aiWidget.pendingCmd, jobId)
        } else {
            aiWidget.confirmRun(aiWidget.pendingCmd, jobId)
        }
        aiWidget.resolveApproval(jobId)
    }
}
