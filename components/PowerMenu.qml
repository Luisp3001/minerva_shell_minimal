import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

Item {
    id: root

    signal closeRequested()

    property bool active: false
    property var shellRoot: null

    // ── Colores y Tipografía (Minerva Shell Theme) ─────────────────────────
    readonly property color accent: "#78d1d3"
    readonly property color accentFg: "#102526"
    readonly property color foreground: "#f5f2f4"
    readonly property color card: "#181719"
    readonly property color cardHover: "#78d1d3"
    readonly property string fontSans: "SF Pro, Noto Sans, Inter, sans-serif"
    readonly property string fontIcon: "Symbols Nerd Font, Iosevka Nerd Font"

    property int selectedIdx: 0

    readonly property var items: [
        {
            name: "Lock",
            icon: "󰌾", // nf-md-lock
            cmd: "lock"
        },
        {
            name: "Suspend",
            icon: "󰤄", // nf-md-weather_night
            cmd: "suspend"
        },
        {
            name: "Log Out",
            icon: "󰍃", // nf-md-logout
            cmd: "logout"
        },
        {
            name: "Reboot",
            icon: "󰑓", // nf-md-restart
            cmd: "reboot"
        },
        {
            name: "Power Off",
            icon: "󰐥", // nf-md-power
            cmd: "poweroff"
        }
    ]

    function open() {
        selectedIdx = 0
        root.forceActiveFocus()
    }

    function close() {
        root.closeRequested()
    }

    function executeAction(index) {
        if (index < 0 || index >= items.length) return
        const action = items[index].cmd
        root.closeRequested()

        if (action === "lock") {
            // Intentar bloquear sesión por loginctl o mediante Lock.qml de Minerva
            Quickshell.execDetached(["loginctl", "lock-session"])
            Quickshell.execDetached(["qs", "-p", Quickshell.env("HOME") + "/.config/minerva_shell/components/Lock.qml"])
        } else if (action === "suspend") {
            Quickshell.execDetached(["systemctl", "suspend"])
        } else if (action === "logout") {
            Quickshell.execDetached(["hyprctl", "dispatch", "exit"])
        } else if (action === "reboot") {
            Quickshell.execDetached(["systemctl", "reboot"])
        } else if (action === "poweroff") {
            Quickshell.execDetached(["systemctl", "poweroff"])
        }
    }

    // Asegurar foco para eventos de teclado al activarse
    onActiveChanged: {
        if (active) {
            selectedIdx = 0
            Qt.callLater(function() {
                root.forceActiveFocus()
            })
        }
    }

    focus: true

    Keys.onLeftPressed: (event) => {
        selectedIdx = (selectedIdx - 1 + items.length) % items.length
        event.accepted = true
    }

    Keys.onRightPressed: (event) => {
        selectedIdx = (selectedIdx + 1) % items.length
        event.accepted = true
    }

    Keys.onTabPressed: (event) => {
        selectedIdx = (selectedIdx + 1) % items.length
        event.accepted = true
    }

    Keys.onBacktabPressed: (event) => {
        selectedIdx = (selectedIdx - 1 + items.length) % items.length
        event.accepted = true
    }

    Keys.onReturnPressed: (event) => {
        executeAction(selectedIdx)
        event.accepted = true
    }

    Keys.onSpacePressed: (event) => {
        executeAction(selectedIdx)
        event.accepted = true
    }

    Keys.onEscapePressed: (event) => {
        root.closeRequested()
        event.accepted = true
    }

    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_1 || event.key === Qt.Key_L) {
            executeAction(0)
            event.accepted = true
        } else if (event.key === Qt.Key_2 || event.key === Qt.Key_S) {
            executeAction(1)
            event.accepted = true
        } else if (event.key === Qt.Key_3 || event.key === Qt.Key_O) {
            executeAction(2)
            event.accepted = true
        } else if (event.key === Qt.Key_4 || event.key === Qt.Key_R) {
            executeAction(3)
            event.accepted = true
        } else if (event.key === Qt.Key_5 || event.key === Qt.Key_P) {
            executeAction(4)
            event.accepted = true
        }
    }

    Shortcut {
        sequence: "Escape"
        enabled: root.active
        onActivated: root.closeRequested()
    }

    // ── Layout de Botones ──────────────────────────────────────────────────
    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 14
        anchors.rightMargin: 14
        anchors.topMargin: 10
        anchors.bottomMargin: 10
        spacing: 8

        Repeater {
            model: root.items

            delegate: Rectangle {
                id: btn
                required property var modelData
                required property int index

                Layout.fillWidth: true
                Layout.fillHeight: true
                radius: 16

                readonly property bool isSelected: root.selectedIdx === index || mouseArea.containsMouse
                
                color: isSelected ? root.cardHover : root.card
                scale: mouseArea.pressed ? 0.94 : 1.0

                Behavior on color {
                    ColorAnimation { duration: 130 }
                }

                Behavior on scale {
                    NumberAnimation { duration: 90; easing.type: Easing.OutCubic }
                }

                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: 5

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: btn.modelData.icon
                        font.family: root.fontIcon
                        font.pixelSize: 19
                        color: btn.isSelected ? root.accentFg : root.foreground

                        Behavior on color {
                            ColorAnimation { duration: 130 }
                        }
                    }

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: btn.modelData.name
                        font.family: root.fontSans
                        font.pixelSize: 11
                        font.weight: Font.DemiBold
                        color: btn.isSelected ? root.accentFg : root.foreground

                        Behavior on color {
                            ColorAnimation { duration: 130 }
                        }
                    }
                }

                MouseArea {
                    id: mouseArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor

                    onEntered: {
                        root.selectedIdx = btn.index
                    }

                    onClicked: {
                        root.executeAction(btn.index)
                    }
                }
            }
        }
    }
}
