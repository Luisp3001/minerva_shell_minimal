import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

Item {
    id: root

    signal backRequested()

    readonly property color accent: "#78d1d3"
    readonly property color accentBg: "#192e30"
    readonly property color foreground: "#f4f1f3"
    readonly property color muted: "#969197"
    readonly property color card: "#181719"
    readonly property color cardHover: "#232125"
    readonly property string fontSans: "Noto Sans, Inter, sans-serif"
    readonly property string fontIcon: "Symbols Nerd Font, Iosevka Nerd Font"

    property bool wifiEnabled: false
    property bool ethernetConnected: false
    property string ethernetName: ""
    property bool busy: false
    property bool scanning: false
    property string currentSsid: "Desconectado"
    property string activeUuid: ""
    property int currentSignal: 0
    property string statusMessage: ""
    property bool statusIsError: false
    property bool initialScanDone: false
    property var savedBySsid: ({})
    property string passwordSsid: ""

    ListModel { id: networks }

    function signalIcon(value) {
        if (value >= 75) return "󰤨"
        if (value >= 50) return "󰤥"
        if (value >= 25) return "󰤢"
        return "󰤟"
    }

    function splitNmcli(line) {
        const fields = []
        let field = ""
        let escaped = false
        for (let index = 0; index < line.length; ++index) {
            const character = line[index]
            if (escaped) {
                field += character
                escaped = false
            } else if (character === "\\") {
                escaped = true
            } else if (character === ":") {
                fields.push(field)
                field = ""
            } else {
                field += character
            }
        }
        fields.push(field)
        return fields
    }

    function setStatus(message, isError) {
        statusMessage = message
        statusIsError = isError
        statusTimer.restart()
    }

    function refresh() {
        if (!statusProcess.running)
            statusProcess.running = true
        if (!savedProcess.running)
            savedProcess.running = true
    }

    function scan() {
        if (!wifiEnabled || scanning)
            return
        scanning = true
        networks.clear()
        scanProcess.running = true
    }

    function markSavedNetworks() {
        for (let index = 0; index < networks.count; ++index) {
            const network = networks.get(index)
            const saved = savedBySsid[network.ssid]
            networks.setProperty(index, "saved", saved !== undefined)
            networks.setProperty(index, "uuid", saved ? saved.uuid : "")
        }
    }

    function startAction(arguments, message) {
        if (busy)
            return
        busy = true
        setStatus(message, false)
        actionProcess.command = arguments
        actionProcess.running = true
    }

    function activateNetwork(ssid, security, saved, uuid, enterprise) {
        if (busy)
            return
        if (ssid === currentSsid && activeUuid.length) {
            startAction(["nmcli", "connection", "down", "uuid", activeUuid], "Desconectando…")
        } else if (saved && uuid.length) {
            startAction(["nmcli", "-w", "18", "connection", "up", "uuid", uuid], "Conectando a " + ssid + "…")
        } else if (enterprise) {
            setStatus("Abriendo el editor para la red empresarial…", false)
            Quickshell.execDetached(["nm-connection-editor"])
        } else if (!security.length || security === "--") {
            startAction(["nmcli", "-w", "18", "device", "wifi", "connect", ssid], "Conectando a " + ssid + "…")
        } else {
            passwordSsid = ssid
            passwordField.text = ""
            page.currentIndex = 1
            Qt.callLater(() => passwordField.forceActiveFocus())
        }
    }

    Process {
        id: statusProcess
        command: ["bash", "-lc", `
            state=$(nmcli -g WIFI general 2>/dev/null | head -n1)
            printf 'WIFI|%s\n' "$state"
            eth_dev=$(nmcli -t -e no -f DEVICE,TYPE,STATE device status 2>/dev/null | awk -F: '$2=="ethernet" && $3=="connected" {print $1; exit}')
            if [ -n "$eth_dev" ]; then
                eth_conn=$(nmcli -g GENERAL.CONNECTION device show "$eth_dev" 2>/dev/null | head -n1)
                [ -n "$eth_conn" ] || eth_conn="Ethernet"
                printf 'ETHERNET|true|%s\n' "$eth_conn"
            else
                printf 'ETHERNET|false|\n'
            fi
            [ "$state" = enabled ] || exit 0
            dev=$(nmcli -t -e no -f DEVICE,TYPE,STATE device status 2>/dev/null | awk -F: '$2=="wifi" && $3=="connected" {print $1; exit}')
            [ -n "$dev" ] || exit 0
            conn=$(nmcli -g GENERAL.CONNECTION device show "$dev" 2>/dev/null | head -n1)
            uuid=$(nmcli -g connection.uuid connection show "$conn" 2>/dev/null | head -n1)
            ssid=$(nmcli -g 802-11-wireless.ssid connection show "$conn" 2>/dev/null | head -n1)
            signal=$(nmcli -t -e no -f IN-USE,SIGNAL device wifi list 2>/dev/null | awk -F: '$1=="*" {print $2; exit}')
            printf 'ACTIVE|%s|%s|%s\n' "$uuid" "$ssid" "$signal"
        `]
        stdout: StdioCollector {
            onStreamFinished: {
                let enabled = false
                let ssid = "Desconectado"
                let uuid = ""
                let strength = 0
                let ethConnected = false
                let ethName = ""
                const lines = String(text || "").split(/\r?\n/)
                for (let index = 0; index < lines.length; ++index) {
                    const fields = lines[index].split("|")
                    if (fields[0] === "WIFI")
                        enabled = fields[1] === "enabled"
                    else if (fields[0] === "ETHERNET") {
                        ethConnected = fields[1] === "true"
                        ethName = fields[2] || "Ethernet"
                    } else if (fields[0] === "ACTIVE") {
                        uuid = fields[1] || ""
                        ssid = fields[2] || "Conectado"
                        strength = Number(fields[3]) || 0
                    }
                }
                root.wifiEnabled = enabled
                root.ethernetConnected = ethConnected
                root.ethernetName = ethName
                root.currentSsid = enabled ? ssid : "Wi‑Fi desactivado"
                root.activeUuid = uuid
                root.currentSignal = strength
                for (let index = 0; index < networks.count; ++index)
                    networks.setProperty(index, "active", networks.get(index).ssid === ssid && uuid.length > 0)
                if (enabled && root.visible && !root.initialScanDone) {
                    root.initialScanDone = true
                    Qt.callLater(() => root.scan())
                }
            }
        }
    }

    Process {
        id: savedProcess
        command: ["bash", "-lc", `
            nmcli -t -e no -f UUID,TYPE connection show 2>/dev/null | awk -F: '$2=="802-11-wireless" {print $1}' |
            while IFS= read -r uuid; do
                ssid=$(nmcli -g 802-11-wireless.ssid connection show uuid "$uuid" 2>/dev/null | head -n1)
                [ -n "$ssid" ] && printf '%s|%s\n' "$uuid" "$ssid"
            done
        `]
        stdout: StdioCollector {
            onStreamFinished: {
                const saved = ({})
                const lines = String(text || "").split(/\r?\n/)
                for (let index = 0; index < lines.length; ++index) {
                    const separator = lines[index].indexOf("|")
                    if (separator <= 0)
                        continue
                    const uuid = lines[index].slice(0, separator)
                    const ssid = lines[index].slice(separator + 1)
                    saved[ssid] = { "uuid": uuid }
                }
                root.savedBySsid = saved
                root.markSavedNetworks()
            }
        }
    }

    Process {
        id: scanProcess
        command: ["nmcli", "-t", "-e", "yes", "-f", "IN-USE,SSID,SECURITY,SIGNAL", "device", "wifi", "list", "--rescan", "yes"]
        stdout: StdioCollector {
            onStreamFinished: {
                const bestBySsid = ({})
                const lines = String(text || "").split(/\r?\n/)
                for (let index = 0; index < lines.length; ++index) {
                    const fields = root.splitNmcli(lines[index])
                    if (fields.length < 4 || !fields[1].length)
                        continue
                    const candidate = {
                        "active": fields[0] === "*",
                        "ssid": fields[1],
                        "security": fields[2],
                        "signal": Number(fields[3]) || 0
                    }
                    if (!bestBySsid[candidate.ssid] || candidate.signal > bestBySsid[candidate.ssid].signal)
                        bestBySsid[candidate.ssid] = candidate
                }
                const names = Object.keys(bestBySsid)
                names.sort((a, b) => bestBySsid[b].signal - bestBySsid[a].signal)
                for (let index = 0; index < names.length; ++index) {
                    const candidate = bestBySsid[names[index]]
                    const saved = root.savedBySsid[candidate.ssid]
                    networks.append({
                        "ssid": candidate.ssid,
                        "security": candidate.security,
                        "signal": candidate.signal,
                        "active": candidate.active,
                        "saved": saved !== undefined,
                        "uuid": saved ? saved.uuid : "",
                        "enterprise": candidate.security.includes("802.1X")
                                      || candidate.security.includes("Enterprise")
                    })
                }
                root.scanning = false
                root.setStatus(networks.count ? "Redes actualizadas" : "No se encontraron redes", networks.count === 0)
            }
        }
        onExited: (exitCode) => {
            if (exitCode !== 0) {
                root.scanning = false
                root.setStatus("No se pudo escanear", true)
            }
        }
    }

    Process {
        id: actionProcess
        onExited: (exitCode) => {
            root.busy = false
            root.setStatus(exitCode === 0 ? "Listo" : "La operación falló", exitCode !== 0)
            refreshDelay.restart()
        }
    }

    Timer { id: statusTimer; interval: 3200; onTriggered: root.statusMessage = "" }
    Timer { id: refreshDelay; interval: 900; onTriggered: { root.refresh(); if (root.wifiEnabled) root.scan() } }
    Timer { interval: 6000; repeat: true; running: root.visible; onTriggered: root.refresh() }

    onVisibleChanged: if (visible) { page.currentIndex = 0; initialScanDone = false; refresh() }
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
            color: sw.checked ? "#0d1b1c" : "#e0dcde"

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

    StackLayout {
        id: page
        anchors.fill: parent
        currentIndex: 0

        Item {
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
                                text: "Wi‑Fi"
                                color: root.foreground
                                font.family: root.fontSans
                                font.pixelSize: 18
                                font.weight: Font.Bold
                            }

                            Rectangle {
                                radius: 8
                                color: root.wifiEnabled ? root.accentBg : "#272528"
                                implicitWidth: statusPillText.implicitWidth + 12
                                implicitHeight: 20

                                Text {
                                    id: statusPillText
                                    anchors.centerIn: parent
                                    text: root.wifiEnabled ? "Activado" : "Desactivado"
                                    color: root.wifiEnabled ? root.accent : root.muted
                                    font.family: root.fontSans
                                    font.pixelSize: 10
                                    font.weight: Font.Medium
                                }
                            }
                        }
                    }

                    CustomSwitch {
                        checked: root.wifiEnabled
                        enabled: !root.busy
                        onToggled: (checked) => root.startAction(["nmcli", "radio", "wifi", checked ? "on" : "off"], checked ? "Activando Wi‑Fi…" : "Desactivando Wi‑Fi…")
                    }
                }

                // Active Connection Card
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 68
                    radius: 16
                    color: root.card
                    border.color: root.wifiEnabled && root.activeUuid.length ? Qt.alpha(root.accent, 0.25) : "#272529"
                    border.width: 1

                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: 12
                        spacing: 12

                        Rectangle {
                            Layout.preferredWidth: 44
                            Layout.preferredHeight: 44
                            radius: 14
                            color: root.wifiEnabled && root.activeUuid.length ? root.accent : "#2b292c"
                            Behavior on color { ColorAnimation { duration: 180 } }

                            Text {
                                anchors.centerIn: parent
                                text: root.wifiEnabled ? root.signalIcon(root.currentSignal) : "󰤮"
                                color: root.wifiEnabled && root.activeUuid.length ? "#0c1b1c" : root.muted
                                font.family: root.fontIcon
                                font.pixelSize: 20
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2

                            Text {
                                text: root.currentSsid
                                color: root.foreground
                                font.family: root.fontSans
                                font.pixelSize: 14
                                font.weight: Font.DemiBold
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }

                            Text {
                                text: root.activeUuid.length ? "Conectado • " + root.currentSignal + "% de señal" : (root.wifiEnabled ? "Sin conexión" : "Desactivado")
                                color: root.activeUuid.length ? root.accent : root.muted
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
                            opacity: root.wifiEnabled && !root.busy ? 1.0 : 0.4
                            enabled: root.wifiEnabled && !root.scanning && !root.busy

                            Text {
                                id: scanIconText
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

                // Networks Header
                RowLayout {
                    Layout.fillWidth: true

                    Text {
                        text: root.scanning ? "Buscando redes..." : "Redes disponibles"
                        color: root.muted
                        font.family: root.fontSans
                        font.pixelSize: 12
                        font.weight: Font.DemiBold
                    }

                    Item { Layout.fillWidth: true }

                    Text {
                        visible: networks.count > 0 && root.wifiEnabled
                        text: networks.count + " encontradas"
                        color: Qt.alpha(root.muted, 0.7)
                        font.family: root.fontSans
                        font.pixelSize: 10
                    }
                }

                // Network List
                ListView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    spacing: 6
                    model: networks

                    delegate: Rectangle {
                        id: networkRow
                        required property string ssid
                        required property string security
                        required property int signal
                        required property bool active
                        required property bool saved
                        required property string uuid
                        required property bool enterprise

                        width: ListView.view.width
                        height: 52
                        radius: 14
                        color: networkMouse.pressed ? "#2b292e" : (networkMouse.containsMouse ? root.cardHover : (active ? root.accentBg : "#161517"))
                        border.color: active ? Qt.alpha(root.accent, 0.4) : (networkMouse.containsMouse ? "#2c2a2e" : "transparent")
                        border.width: 1

                        Behavior on color { ColorAnimation { duration: 120 } }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            anchors.rightMargin: 14
                            spacing: 12

                            Text {
                                text: root.signalIcon(networkRow.signal)
                                color: networkRow.active ? root.accent : root.muted
                                font.family: root.fontIcon
                                font.pixelSize: 18
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 1

                                Text {
                                    Layout.fillWidth: true
                                    text: networkRow.ssid
                                    color: root.foreground
                                    font.family: root.fontSans
                                    font.pixelSize: 13
                                    font.weight: networkRow.active ? Font.DemiBold : Font.Normal
                                    elide: Text.ElideRight
                                }

                                Text {
                                    text: networkRow.active ? "Conectado actualmente" : (networkRow.saved ? "Red guardada" : (networkRow.enterprise ? "Seguridad empresarial" : (networkRow.security.length && networkRow.security !== "--" ? "Red protegida" : "Red abierta")))
                                    color: networkRow.active ? root.accent : root.muted
                                    font.family: root.fontSans
                                    font.pixelSize: 10
                                }
                            }

                            Text {
                                visible: networkRow.security.length > 0 && networkRow.security !== "--"
                                text: "󰌾"
                                color: root.muted
                                font.family: root.fontIcon
                                font.pixelSize: 13
                            }

                            Rectangle {
                                visible: networkRow.active
                                radius: 6
                                color: root.accent
                                implicitWidth: activeText.implicitWidth + 10
                                implicitHeight: 18

                                Text {
                                    id: activeText
                                    anchors.centerIn: parent
                                    text: "Conectado"
                                    color: "#0c1b1c"
                                    font.family: root.fontSans
                                    font.pixelSize: 9
                                    font.weight: Font.Bold
                                }
                            }

                            Text {
                                text: "󰅂"
                                color: networkMouse.containsMouse ? root.foreground : root.muted
                                font.family: root.fontIcon
                                font.pixelSize: 14
                            }
                        }

                        MouseArea {
                            id: networkMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: !root.busy
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.activateNetwork(networkRow.ssid, networkRow.security, networkRow.saved, networkRow.uuid, networkRow.enterprise)
                        }
                    }

                    Text {
                        anchors.centerIn: parent
                        visible: networks.count === 0 && !root.scanning
                        text: root.wifiEnabled ? "No se encontraron redes Wi‑Fi" : "El Wi‑Fi está desactivado"
                        horizontalAlignment: Text.AlignHCenter
                        color: root.muted
                        font.family: root.fontSans
                        font.pixelSize: 12
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

        // Password Prompt Page
        Item {
            ColumnLayout {
                anchors.centerIn: parent
                width: Math.min(parent.width - 40, 360)
                spacing: 16

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    CustomBackButton {
                        onClicked: page.currentIndex = 0
                    }

                    Text {
                        Layout.fillWidth: true
                        text: "Conectar a red"
                        color: root.foreground
                        font.family: root.fontSans
                        font.pixelSize: 17
                        font.weight: Font.Bold
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    radius: 16
                    color: root.card
                    border.color: "#2a272c"
                    border.width: 1
                    implicitHeight: passContent.implicitHeight + 32

                    ColumnLayout {
                        id: passContent
                        anchors.fill: parent
                        anchors.margins: 16
                        spacing: 14

                        Text {
                            Layout.fillWidth: true
                            text: "Introduce la contraseña para \"" + root.passwordSsid + "\""
                            color: root.muted
                            font.family: root.fontSans
                            font.pixelSize: 12
                            wrapMode: Text.Wrap
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 46
                            radius: 12
                            color: "#141315"
                            border.color: passwordField.activeFocus ? root.accent : "#343135"
                            border.width: 1

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 12
                                anchors.rightMargin: 8
                                spacing: 6

                                TextField {
                                    id: passwordField
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    placeholderText: "Contraseña de la red"
                                    echoMode: showPasswordBtn.showPass ? TextInput.Normal : TextInput.Password
                                    color: root.foreground
                                    placeholderTextColor: root.muted
                                    font.family: root.fontSans
                                    font.pixelSize: 13
                                    background: Item {}
                                    onAccepted: connectButton.clicked()
                                }

                                Rectangle {
                                    id: showPasswordBtn
                                    property bool showPass: false
                                    Layout.preferredWidth: 32
                                    Layout.preferredHeight: 32
                                    radius: 8
                                    color: showPassMouse.containsMouse ? "#2d2a30" : "transparent"

                                    Text {
                                        anchors.centerIn: parent
                                        text: showPasswordBtn.showPass ? "󰈈" : "󰈉"
                                        font.family: root.fontIcon
                                        font.pixelSize: 15
                                        color: showPasswordBtn.showPass ? root.accent : root.muted
                                    }

                                    MouseArea {
                                        id: showPassMouse
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: showPasswordBtn.showPass = !showPasswordBtn.showPass
                                    }
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10

                            Rectangle {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 40
                                radius: 10
                                color: cancelMouse.pressed ? "#353238" : (cancelMouse.containsMouse ? "#2b282e" : "#222024")

                                Text {
                                    anchors.centerIn: parent
                                    text: "Cancelar"
                                    color: root.foreground
                                    font.family: root.fontSans
                                    font.pixelSize: 12
                                    font.weight: Font.Medium
                                }

                                MouseArea {
                                    id: cancelMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: page.currentIndex = 0
                                }
                            }

                            Rectangle {
                                id: connectButton
                                Layout.fillWidth: true
                                Layout.preferredHeight: 40
                                radius: 10
                                color: passwordField.text.length > 0 && !root.busy ? (connectMouse.pressed ? Qt.darker(root.accent, 1.2) : (connectMouse.containsMouse ? Qt.lighter(root.accent, 1.1) : root.accent)) : "#29272a"
                                opacity: passwordField.text.length > 0 && !root.busy ? 1.0 : 0.5
                                enabled: passwordField.text.length > 0 && !root.busy

                                Text {
                                    anchors.centerIn: parent
                                    text: root.busy ? "Conectando…" : "Conectar"
                                    color: passwordField.text.length > 0 && !root.busy ? "#0c1b1c" : root.muted
                                    font.family: root.fontSans
                                    font.pixelSize: 12
                                    font.weight: Font.Bold
                                }

                                MouseArea {
                                    id: connectMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.startAction(["nmcli", "-w", "20", "device", "wifi", "connect", root.passwordSsid, "password", passwordField.text], "Conectando…")
                                }
                            }
                        }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    visible: root.statusMessage.length > 0
                    text: root.statusMessage
                    color: root.statusIsError ? "#f2a2ad" : root.accent
                    horizontalAlignment: Text.AlignHCenter
                    font.family: root.fontSans
                    font.pixelSize: 11
                }
            }
        }
    }
}
