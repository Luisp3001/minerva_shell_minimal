import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell.Io

Item {
    id: root

    signal backRequested()

    readonly property color accent: "#5ea2ff"
    readonly property color accentBg: "#17273b"
    readonly property color foreground: "#f4f1f3"
    readonly property color muted: "#969197"
    readonly property color card: "#181719"
    readonly property color cardHover: "#232125"
    readonly property string fontSans: "Noto Sans, Inter, sans-serif"
    readonly property string fontIcon: "Symbols Nerd Font, Iosevka Nerd Font"

    property bool bluetoothEnabled: false
    property bool busy: false
    property bool scanning: false
    property string statusMessage: ""
    property bool statusIsError: false
    readonly property string connectedDevice: {
        for (let index = 0; index < devices.count; ++index) {
            const device = devices.get(index)
            if (device.connected)
                return device.name
        }
        return ""
    }

    ListModel { id: devices }

    function getDeviceIcon(name) {
        const lowerName = (name || "").toLowerCase()
        if (lowerName.includes("headset") || lowerName.includes("headphone") || lowerName.includes("airpods")
            || lowerName.includes("buds") || lowerName.includes("speaker") || lowerName.includes("audio")
            || lowerName.includes("wh-") || lowerName.includes("wf-") || lowerName.includes("jbl") || lowerName.includes("sony")) {
            return "󰋋"
        }
        if (lowerName.includes("phone") || lowerName.includes("iphone") || lowerName.includes("celular")
            || lowerName.includes("galaxy") || lowerName.includes("xiaomi") || lowerName.includes("pixel")) {
            return "󰄜"
        }
        if (lowerName.includes("mouse") || lowerName.includes("trackpad") || lowerName.includes("logitech")) {
            return "󰍽"
        }
        if (lowerName.includes("keyboard") || lowerName.includes("teclado")) {
            return "󰌌"
        }
        if (lowerName.includes("gamepad") || lowerName.includes("controller") || lowerName.includes("xbox")
            || lowerName.includes("playstation") || lowerName.includes("dual")) {
            return "󰊴"
        }
        if (lowerName.includes("laptop") || lowerName.includes("pc") || lowerName.includes("computer") || lowerName.includes("desktop")) {
            return "󰌢"
        }
        return "󰂯"
    }

    function setStatus(message, isError) {
        statusMessage = message
        statusIsError = isError
        statusTimer.restart()
    }

    function refresh() {
        if (statusProcess.running)
            return
        statusProcess.running = true
    }

    function runAction(arguments, message) {
        if (busy)
            return
        busy = true
        setStatus(message, false)
        actionProcess.command = arguments
        actionProcess.running = true
    }

    function toggleDevice(mac, connected, paired) {
        if (!/^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/.test(mac)) {
            setStatus("Dirección de dispositivo inválida", true)
            return
        }
        if (connected)
            runAction(["bluetoothctl", "disconnect", mac], "Desconectando…")
        else if (paired)
            runAction(["bluetoothctl", "connect", mac], "Conectando…")
        else
            runAction(["bluetoothctl", "pair", mac], "Emparejando… confirma el código si aparece")
    }

    function scan() {
        if (!bluetoothEnabled || scanning || busy)
            return
        scanning = true
        setStatus("Buscando dispositivos…", false)
        scanProcess.running = true
    }

    Process {
        id: statusProcess
        command: ["bash", "-lc", `
            command -v bluetoothctl >/dev/null 2>&1 || { echo 'ERROR|bluetoothctl no está instalado'; exit 0; }
            bluetoothctl show >/dev/null 2>&1 || { echo 'ERROR|El servicio Bluetooth no está disponible'; exit 0; }
            bluetoothctl show | grep -q 'Powered: yes' || { echo 'POWER|off'; exit 0; }
            echo 'POWER|on'
            bluetoothctl devices | while read -r _ mac name; do
                [ -n "$mac" ] || continue
                info=$(bluetoothctl info "$mac" 2>/dev/null)
                connected=false; paired=false
                echo "$info" | grep -q 'Connected: yes' && connected=true
                echo "$info" | grep -q 'Paired: yes' && paired=true
                printf 'DEVICE|%s|%s|%s|%s\n' "$mac" "$connected" "$paired" "$name"
            done
        `]
        stdout: StdioCollector {
            onStreamFinished: {
                devices.clear()
                let powered = false
                const lines = String(text || "").split(/\r?\n/)
                for (let index = 0; index < lines.length; ++index) {
                    const fields = lines[index].split("|")
                    if (fields[0] === "POWER")
                        powered = fields[1] === "on"
                    else if (fields[0] === "ERROR")
                        root.setStatus(fields.slice(1).join("|"), true)
                    else if (fields[0] === "DEVICE" && fields.length >= 5) {
                        devices.append({
                            "mac": fields[1],
                            "connected": fields[2] === "true",
                            "paired": fields[3] === "true",
                            "name": fields.slice(4).join("|") || "Dispositivo desconocido"
                        })
                    }
                }
                root.bluetoothEnabled = powered
            }
        }
    }

    Process {
        id: actionProcess
        onExited: (exitCode) => {
            root.busy = false
            root.setStatus(exitCode === 0 ? "Listo" : "No se pudo completar la operación", exitCode !== 0)
            refreshDelay.restart()
        }
    }

    Process {
        id: scanProcess
        command: ["bluetoothctl", "--timeout", "8", "scan", "on"]
        onExited: (exitCode) => {
            root.scanning = false
            root.setStatus(exitCode === 0 ? "Búsqueda terminada" : "No se pudo buscar", exitCode !== 0)
            root.refresh()
        }
    }

    Timer { id: statusTimer; interval: 3200; onTriggered: root.statusMessage = "" }
    Timer { id: refreshDelay; interval: 700; onTriggered: root.refresh() }
    Timer { interval: 6000; repeat: true; running: root.visible; onTriggered: root.refresh() }

    onVisibleChanged: if (visible) refresh()
    Component.onCompleted: refresh()

    // Reusable Custom Switch Component
    component CustomSwitch: Rectangle {
        id: sw
        property bool checked: false
        property bool enabled: true
        property color activeColor: root.accent
        property color inactiveColor: "#272528"
        signal toggled(bool checked)

        implicitWidth: 46
        implicitHeight: 24
        radius: 12
        color: sw.checked ? sw.activeColor : sw.inactiveColor
        opacity: sw.enabled ? 1.0 : 0.4
        border.color: sw.checked ? Qt.lighter(sw.activeColor, 1.1) : "#38353a"
        border.width: 1

        Behavior on color { ColorAnimation { duration: 180 } }
        Behavior on opacity { NumberAnimation { duration: 150 } }

        Rectangle {
            id: thumb
            width: 18
            height: 18
            radius: 9
            anchors.verticalCenter: parent.verticalCenter
            x: sw.checked ? (sw.width - width - 3) : 3
            color: sw.checked ? "#0c1524" : "#e0dcde"

            Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 180 } }
        }

        MouseArea {
            anchors.fill: parent
            enabled: sw.enabled
            cursorShape: Qt.PointingHandCursor
            onClicked: sw.toggled(!sw.checked)
        }
    }

    // Reusable Custom Back Button Component
    component CustomBackButton: Rectangle {
        id: btn
        signal clicked()

        implicitWidth: 36
        implicitHeight: 36
        radius: 12
        color: btnMouse.pressed ? "#3c3842" : (btnMouse.containsMouse ? "#2d2a30" : "#222024")
        scale: btnMouse.pressed ? 0.93 : (btnMouse.containsMouse ? 1.04 : 1.0)
        border.color: btnMouse.containsMouse ? "#423e47" : "transparent"
        border.width: 1

        Behavior on color { ColorAnimation { duration: 120 } }
        Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

        Text {
            anchors.centerIn: parent
            text: "󰁍"
            font.family: root.fontIcon
            font.pixelSize: 16
            color: btnMouse.containsMouse ? root.foreground : root.muted
            Behavior on color { ColorAnimation { duration: 120 } }
        }

        MouseArea {
            id: btnMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: btn.clicked()
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 12

        // Header Bar
        RowLayout {
            Layout.fillWidth: true
            spacing: 12

            CustomBackButton {
                onClicked: root.backRequested()
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                RowLayout {
                    spacing: 8
                    Text {
                        text: "Bluetooth"
                        color: root.foreground
                        font.family: root.fontSans
                        font.pixelSize: 18
                        font.weight: Font.Bold
                    }

                    Rectangle {
                        radius: 8
                        color: root.bluetoothEnabled ? root.accentBg : "#272528"
                        implicitWidth: statusPillText.implicitWidth + 12
                        implicitHeight: 20

                        Text {
                            id: statusPillText
                            anchors.centerIn: parent
                            text: root.bluetoothEnabled ? "Activado" : "Desactivado"
                            color: root.bluetoothEnabled ? root.accent : root.muted
                            font.family: root.fontSans
                            font.pixelSize: 10
                            font.weight: Font.Medium
                        }
                    }
                }
            }

            CustomSwitch {
                checked: root.bluetoothEnabled
                enabled: !root.busy
                activeColor: root.accent
                onToggled: (checked) => root.runAction(["bluetoothctl", "power", checked ? "on" : "off"], checked ? "Activando Bluetooth…" : "Desactivando Bluetooth…")
            }
        }

        // Bluetooth Adapter Status Card
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 68
            radius: 16
            color: root.card
            border.color: root.bluetoothEnabled ? Qt.alpha(root.accent, 0.25) : "#272529"
            border.width: 1

            RowLayout {
                anchors.fill: parent
                anchors.margins: 12
                spacing: 12

                Rectangle {
                    Layout.preferredWidth: 44
                    Layout.preferredHeight: 44
                    radius: 14
                    color: root.bluetoothEnabled ? root.accent : "#2b292c"
                    Behavior on color { ColorAnimation { duration: 180 } }

                    Text {
                        anchors.centerIn: parent
                        text: root.connectedDevice.length ? "󰂱" : "󰂯"
                        color: root.bluetoothEnabled ? "#0c1524" : root.muted
                        font.family: root.fontIcon
                        font.pixelSize: 20
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2

                    Text {
                        text: root.connectedDevice.length ? root.connectedDevice : (root.bluetoothEnabled ? "Bluetooth listo" : "Bluetooth desactivado")
                        color: root.foreground
                        font.family: root.fontSans
                        font.pixelSize: 14
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }

                    Text {
                        text: root.connectedDevice.length ? "Dispositivo conectado" : (root.bluetoothEnabled ? "Descubrible para otros dispositivos" : "Desactivado")
                        color: root.connectedDevice.length ? root.accent : root.muted
                        font.family: root.fontSans
                        font.pixelSize: 11
                    }
                }

                Rectangle {
                    id: scanBtn
                    Layout.preferredWidth: 38
                    Layout.preferredHeight: 38
                    radius: 12
                    color: scanMouse.pressed ? "#353238" : (scanMouse.containsMouse ? "#2b282e" : "#211f23")
                    opacity: root.bluetoothEnabled && !root.busy ? 1.0 : 0.4
                    enabled: root.bluetoothEnabled && !root.scanning && !root.busy

                    Text {
                        anchors.centerIn: parent
                        text: "󰑐"
                        font.family: root.fontIcon
                        font.pixelSize: 16
                        color: root.scanning ? root.accent : (scanMouse.containsMouse ? root.foreground : root.muted)

                        RotationAnimation on rotation {
                            running: root.scanning
                            loops: Animation.Infinite
                            from: 0
                            to: 360
                            duration: 1000
                        }
                    }

                    MouseArea {
                        id: scanMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.scan()
                    }
                }
            }
        }

        // Section Title
        RowLayout {
            Layout.fillWidth: true

            Text {
                text: root.scanning ? "Buscando dispositivos…" : "Dispositivos emparejados"
                color: root.muted
                font.family: root.fontSans
                font.pixelSize: 12
                font.weight: Font.DemiBold
            }

            Item { Layout.fillWidth: true }

            Text {
                visible: devices.count > 0 && root.bluetoothEnabled
                text: devices.count + " reconocidos"
                color: Qt.alpha(root.muted, 0.7)
                font.family: root.fontSans
                font.pixelSize: 10
            }
        }

        // Devices List
        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 6
            model: devices

            delegate: Rectangle {
                id: deviceRow
                required property string mac
                required property string name
                required property bool connected
                required property bool paired

                width: ListView.view.width
                height: 52
                radius: 14
                color: deviceMouse.pressed ? "#2b292e" : (deviceMouse.containsMouse ? root.cardHover : (connected ? root.accentBg : "#161517"))
                border.color: connected ? Qt.alpha(root.accent, 0.4) : (deviceMouse.containsMouse ? "#2c2a2e" : "transparent")
                border.width: 1

                Behavior on color { ColorAnimation { duration: 120 } }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 14
                    spacing: 12

                    Rectangle {
                        Layout.preferredWidth: 36
                        Layout.preferredHeight: 36
                        radius: 12
                        color: deviceRow.connected ? root.accent : "#252327"
                        Behavior on color { ColorAnimation { duration: 180 } }

                        Text {
                            anchors.centerIn: parent
                            text: root.getDeviceIcon(deviceRow.name)
                            color: deviceRow.connected ? "#0c1524" : (deviceMouse.containsMouse ? root.foreground : root.muted)
                            font.family: root.fontIcon
                            font.pixelSize: 16
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1

                        Text {
                            Layout.fillWidth: true
                            text: deviceRow.name
                            color: root.foreground
                            font.family: root.fontSans
                            font.pixelSize: 13
                            font.weight: deviceRow.connected ? Font.DemiBold : Font.Normal
                            elide: Text.ElideRight
                        }

                        Text {
                            text: deviceRow.connected ? "Conectado actualmente" : (deviceRow.paired ? "Emparejado" : "Toca para emparejar")
                            color: deviceRow.connected ? root.accent : root.muted
                            font.family: root.fontSans
                            font.pixelSize: 10
                        }
                    }

                    Rectangle {
                        visible: deviceRow.connected
                        radius: 6
                        color: root.accent
                        implicitWidth: connTagText.implicitWidth + 10
                        implicitHeight: 18

                        Text {
                            id: connTagText
                            anchors.centerIn: parent
                            text: "Conectado"
                            color: "#0c1524"
                            font.family: root.fontSans
                            font.pixelSize: 9
                            font.weight: Font.Bold
                        }
                    }

                    Text {
                        text: "󰅂"
                        color: deviceMouse.containsMouse ? root.foreground : root.muted
                        font.family: root.fontIcon
                        font.pixelSize: 14
                    }
                }

                MouseArea {
                    id: deviceMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: root.bluetoothEnabled && !root.busy
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleDevice(deviceRow.mac, deviceRow.connected, deviceRow.paired)
                }
            }

            ColumnLayout {
                anchors.centerIn: parent
                visible: devices.count === 0
                spacing: 8

                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: "󰂲"
                    font.family: root.fontIcon
                    font.pixelSize: 32
                    color: root.muted
                    opacity: 0.5
                }

                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: root.bluetoothEnabled ? "No hay dispositivos.\nPulsa el botón de búsqueda para descubrirlos." : "El Bluetooth está desactivado"
                    horizontalAlignment: Text.AlignHCenter
                    color: root.muted
                    font.family: root.fontSans
                    font.pixelSize: 12
                }
            }
        }

        // Status Message Bar
        Text {
            Layout.fillWidth: true
            visible: root.statusMessage.length > 0
            text: root.statusMessage
            color: root.statusIsError ? "#f2a2ad" : root.accent
            horizontalAlignment: Text.AlignHCenter
            font.family: root.fontSans
            font.pixelSize: 11
            font.weight: Font.Medium
        }
    }
}
