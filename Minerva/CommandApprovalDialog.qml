import QtQuick

Rectangle {
    id: root

    required property var aiWidget

    visible: aiWidget ? aiWidget.showConfirm : false
    color: Qt.rgba(0, 0, 0, 0.72)
    radius: 22
    opacity: visible ? 1.0 : 0.0

    Behavior on opacity { NumberAnimation { duration: 180 } }

    Rectangle {
        anchors.centerIn: parent
        width: parent.width - 36
        height: dialogColumn.implicitHeight + 44
        radius: 18
        color: "#141422"
        border.width: 1
        border.color: Qt.rgba(0.95, 0.65, 0.2, 0.55)
        layer.enabled: visible

        Column {
            id: dialogColumn
            anchors.centerIn: parent
            width: parent.width - 44
            spacing: 16

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 10

                Text {
                    text: root.aiWidget && root.aiWidget.pendingIsSudo
                          ? "󰌞" : "󰀦"
                    font.family: Theme.fontMono
                    font.pixelSize: 28
                    color: Theme.warning
                    anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.aiWidget && root.aiWidget.pendingIsSudo
                          ? "Permisos elevados" : "¿Confirmar acción?"
                    font.family: Theme.fontSans
                    font.pixelSize: 15
                    font.weight: Font.Bold
                    color: Theme.warning
                }
            }

            Text {
                width: parent.width
                text: root.aiWidget ? root.aiWidget.pendingReason : ""
                font.family: Theme.fontSans
                font.pixelSize: 12
                color: Theme.textMuted
                wrapMode: Text.Wrap
                horizontalAlignment: Text.AlignHCenter
            }

            Rectangle {
                width: parent.width
                height: commandText.implicitHeight + 16
                radius: 10
                color: Qt.rgba(0, 0, 0, 0.45)
                border.width: 1
                border.color: Qt.rgba(0.95, 0.65, 0.2, 0.25)

                Text {
                    id: commandText
                    anchors {
                        left: parent.left
                        right: parent.right
                        verticalCenter: parent.verticalCenter
                        margins: 12
                    }
                    text: "$ " + (root.aiWidget
                                   ? root.aiWidget.pendingCmd : "")
                    font.family: Theme.fontMono
                    font.pixelSize: 12
                    color: Theme.warning
                    wrapMode: Text.Wrap
                }
            }

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 12

                Rectangle {
                    width: 100
                    height: 36
                    radius: 10
                    color: cancelArea.containsMouse
                           ? Qt.rgba(0.3, 0.3, 0.3, 0.4)
                           : Qt.rgba(0.15, 0.15, 0.15, 0.4)
                    border.width: 1
                    border.color: Qt.rgba(1, 1, 1, 0.2)

                    Behavior on color { ColorAnimation { duration: 120 } }

                    Text {
                        anchors.centerIn: parent
                        text: "Cancelar"
                        font.family: Theme.fontSans
                        font.pixelSize: 13
                        color: Theme.textPrimary
                    }

                    MouseArea {
                        id: cancelArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (!root.aiWidget) return
                            const jobId = root.aiWidget.pendingJobId || ""
                            root.aiWidget.cancelJob(jobId)
                            root.aiWidget.resolveApproval(jobId)
                        }
                    }
                }

                Rectangle {
                    width: root.aiWidget && root.aiWidget.pendingIsSudo
                           ? 150 : 170
                    height: 36
                    radius: 10
                    color: executeArea.containsMouse
                           ? Qt.rgba(0.75, 0.45, 0.08, 0.55)
                           : Qt.rgba(0.5, 0.28, 0.04, 0.4)
                    border.width: 1
                    border.color: Qt.rgba(
                        Theme.warning.r,
                        Theme.warning.g,
                        Theme.warning.b,
                        0.75
                    )

                    Behavior on color { ColorAnimation { duration: 120 } }

                    Text {
                        anchors.centerIn: parent
                        text: root.aiWidget && root.aiWidget.pendingIsSudo
                              ? "Ejecutar (pkexec)"
                              : "Ejecutar de todos modos"
                        font.family: Theme.fontSans
                        font.pixelSize: 12
                        color: Theme.warning
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
