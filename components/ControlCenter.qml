import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris

Item {
    id: root

    property bool active: false
    property var shellRoot: null
    property int currentPage: 0 // 0 = principal, 1 = Wi-Fi, 2 = Bluetooth
    readonly property int contentHeight: 535

    readonly property color accent: "#78d1d3"
    readonly property color foreground: "#f5f2f4"
    readonly property color muted: "#9b969c"
    readonly property color card: "#181719"
    readonly property color cardHover: "#211f22"
    readonly property string fontSans: "Noto Sans, Inter, sans-serif"
    readonly property string fontIcon: "Symbols Nerd Font, Iosevka Nerd Font"

    property real brightness: 50
    property real volume: 0
    property bool audioMuted: false
    property int battery: -1
    property real pendingBrightness: brightness
    property real pendingVolume: volume

    readonly property var players: Mpris.players.values
    readonly property var player: {
        for (let index = 0; index < players.length; ++index) {
            const candidate = players[index]
            if (candidate && candidate.playbackState === MprisPlaybackState.Playing)
                return candidate
        }
        return players.length ? players[0] : null
    }
    readonly property bool playing: player && player.playbackState === MprisPlaybackState.Playing
    readonly property string trackTitle: player && player.trackTitle ? player.trackTitle : "Sin reproducción"
    readonly property string trackArtist: player && player.trackArtist ? player.trackArtist : "Reproductor multimedia"
    readonly property string trackArt: player && player.trackArtUrl ? player.trackArtUrl : ""

    function open() {
        active = true
        currentPage = 0
        refreshSystemState()
        wifiPanel.refresh()
        bluetoothPanel.refresh()
    }

    function close() {
        active = false
        currentPage = 0
    }

    function refreshSystemState() {
        if (!systemState.running)
            systemState.running = true
    }

    function toggleDnd() {
        if (shellRoot)
            shellRoot.dndEnabled = !shellRoot.dndEnabled
    }

    function lockScreen() {
        Quickshell.execDetached(["loginctl", "lock-session"]);
    }

    Process {
        id: systemState
        command: ["bash", "-lc", `
            volume=$(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | grep -Po '\\d+(?=%)' | head -n1)
            muted=$(pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null | awk '{print $2}')
            brightness=$(brightnessctl -m 2>/dev/null | cut -d, -f4 | tr -d '% ')
            battery=$(upower -i /org/freedesktop/UPower/devices/battery_BAT0 2>/dev/null | awk '/percentage:/ {gsub("%", "", $2); print $2; exit}')
            printf 'VOLUME|%s\nMUTED|%s\nBRIGHTNESS|%s\nBATTERY|%s\n' "$volume" "$muted" "$brightness" "$battery"
        `]
        stdout: StdioCollector {
            onStreamFinished: {
                const lines = String(text || "").split(/\r?\n/)
                for (let index = 0; index < lines.length; ++index) {
                    const fields = lines[index].split("|")
                    const value = Number(fields[1])
                    if (fields[0] === "VOLUME" && isFinite(value)) root.volume = value
                    else if (fields[0] === "MUTED") root.audioMuted = fields[1] === "yes"
                    else if (fields[0] === "BRIGHTNESS" && isFinite(value)) root.brightness = value
                    else if (fields[0] === "BATTERY" && isFinite(value)) root.battery = value
                }
            }
        }
    }

    Timer { interval: 2500; repeat: true; running: root.active; onTriggered: { root.refreshSystemState(); wifiPanel.refresh(); } }
    Timer {
        id: brightnessDebounce
        interval: 70
        onTriggered: Quickshell.execDetached(["brightnessctl", "set", Math.round(root.pendingBrightness) + "%"])
    }
    Timer {
        id: volumeDebounce
        interval: 70
        onTriggered: Quickshell.execDetached(["pactl", "set-sink-volume", "@DEFAULT_SINK@", Math.round(root.pendingVolume) + "%"])
    }

    Item {
        id: dashboard
        width: parent.width
        height: parent.height
        x: root.currentPage === 0 ? 0 : -root.width
        enabled: root.currentPage === 0
        opacity: root.currentPage === 0 ? 1 : 0

        Behavior on x { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
        Behavior on opacity { NumberAnimation { duration: 160 } }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 15
            spacing: 10

            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 188
                Layout.minimumHeight: 188
                Layout.maximumHeight: 188
                spacing: 10

                ColumnLayout {
                    Layout.preferredWidth: 238
                    Layout.minimumWidth: 238
                    Layout.maximumWidth: 238
                    Layout.fillHeight: true
                    spacing: 7

                    ConnectivityTile {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 58
                        Layout.minimumHeight: 58
                        Layout.maximumHeight: 58
                        icon: wifiPanel.ethernetConnected ? "󰈀" : (wifiPanel.wifiEnabled ? wifiPanel.signalIcon(wifiPanel.currentSignal) : "󰤮")
                        title: wifiPanel.ethernetConnected ? "Ethernet" : "Wi‑Fi"
                        subtitle: wifiPanel.ethernetConnected ? wifiPanel.ethernetName : wifiPanel.currentSsid
                        enabledState: wifiPanel.ethernetConnected || wifiPanel.wifiEnabled
                        onClicked: root.currentPage = 1
                    }

                    ConnectivityTile {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 58
                        Layout.minimumHeight: 58
                        Layout.maximumHeight: 58
                        icon: "󰂯"
                        title: "Bluetooth"
                        subtitle: bluetoothPanel.connectedDevice.length ? bluetoothPanel.connectedDevice : (bluetoothPanel.bluetoothEnabled ? "Activado" : "Desactivado")
                        enabledState: bluetoothPanel.bluetoothEnabled
                        onClicked: root.currentPage = 2
                    }

                    ConnectivityTile {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 58
                        Layout.minimumHeight: 58
                        Layout.maximumHeight: 58
                        icon: root.shellRoot && root.shellRoot.dndEnabled ? "󰂛" : "󰂚"
                        title: "No molestar"
                        subtitle: root.shellRoot && root.shellRoot.dndEnabled ? "Activado" : "Desactivado"
                        enabledState: root.shellRoot && root.shellRoot.dndEnabled
                        onClicked: root.toggleDnd()
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 8

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 122
                        Layout.minimumHeight: 122
                        Layout.maximumHeight: 122
                        radius: 24
                        color: "#29272a"

                        Image {
                            id: mediaArtwork
                            anchors.fill: parent
                            source: root.trackArt
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            visible: false
                            layer.enabled: true
                        }

                        Rectangle {
                            id: mediaMask
                            anchors.fill: parent
                            radius: 24
                            color: "white"
                            visible: false
                            layer.enabled: true
                        }

                        // Rectangle.clip solo recorta en ángulo recto. Este
                        // efecto aplica una máscara real a la carátula.
                        MultiEffect {
                            anchors.fill: parent
                            source: mediaArtwork
                            maskEnabled: true
                            maskSource: mediaMask
                            antialiasing: true
                            opacity: mediaArtwork.status === Image.Ready ? 0.62 : 0
                        }

                        Rectangle {
                            anchors.fill: parent
                            radius: 24
                            color: "#52000000"
                        }

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 12
                            spacing: 2

                            Text { Layout.fillWidth: true; text: root.trackTitle; color: "white"; font.family: root.fontSans; font.pixelSize: 13; font.weight: Font.DemiBold; elide: Text.ElideRight }
                            Text { Layout.fillWidth: true; text: root.trackArtist; color: "#d0cbd0"; font.family: root.fontSans; font.pixelSize: 10; elide: Text.ElideRight }
                            Item { Layout.fillHeight: true }
                            RowLayout {
                                Layout.alignment: Qt.AlignHCenter
                                spacing: 17
                                Text { text: "󰒮"; color: "white"; font.family: root.fontIcon; font.pixelSize: 14; MouseArea { anchors.fill: parent; anchors.margins: -8; cursorShape: Qt.PointingHandCursor; onClicked: if (root.player) root.player.previous() } }
                                Rectangle {
                                    Layout.preferredWidth: 38; Layout.preferredHeight: 38; radius: 19; color: "#f4f2f3"
                                    Text { anchors.centerIn: parent; text: root.playing ? "󰏤" : "󰐊"; color: "#181719"; font.family: root.fontIcon; font.pixelSize: 15 }
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { if (!root.player) return; if (root.playing) root.player.pause(); else root.player.play() } }
                                }
                                Text { text: "󰒭"; color: "white"; font.family: root.fontIcon; font.pixelSize: 14; MouseArea { anchors.fill: parent; anchors.margins: -8; cursorShape: Qt.PointingHandCursor; onClicked: if (root.player) root.player.next() } }
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 58
                        Layout.minimumHeight: 58
                        Layout.maximumHeight: 58
                        spacing: 0

                        Item {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            CircleAction {
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                width: 58
                                height: 58
                                icon: "󰤄"
                                onClicked: Quickshell.execDetached(["systemctl", "suspend"])
                            }
                        }

                        Item {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            CircleAction {
                                anchors.centerIn: parent
                                width: 58
                                height: 58
                                icon: root.audioMuted ? "󰝟" : "󰕾"
                                activeState: root.audioMuted
                                onClicked: {
                                    root.audioMuted = !root.audioMuted
                                    Quickshell.execDetached(["pactl", "set-sink-mute", "@DEFAULT_SINK@", "toggle"])
                                }
                            }
                        }

                        Item {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            CircleAction {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                width: 58
                                height: 58
                                icon: "󰌾"
                                onClicked: root.lockScreen()
                            }
                        }
                    }
                }
            }

            SliderCard {
                Layout.fillWidth: true
                Layout.preferredHeight: 72
                label: "Pantalla"
                icon: "󰃠"
                level: root.brightness
                onLevelEdited: (value, committed) => {
                    root.brightness = value
                    root.pendingBrightness = value
                    if (committed) Quickshell.execDetached(["brightnessctl", "set", Math.round(value) + "%"])
                    else brightnessDebounce.restart()
                }
            }

            SliderCard {
                Layout.fillWidth: true
                Layout.preferredHeight: 72
                label: "Sonido"
                icon: root.audioMuted || root.volume <= 0 ? "󰝟" : "󰕾"
                level: root.audioMuted ? 0 : root.volume
                onLevelEdited: (value, committed) => {
                    root.volume = value
                    root.audioMuted = false
                    root.pendingVolume = value
                    if (committed) Quickshell.execDetached(["pactl", "set-sink-volume", "@DEFAULT_SINK@", Math.round(value) + "%"])
                    else volumeDebounce.restart()
                }
            }

            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: "#2a282b" }

            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 20

                Text { Layout.fillWidth: true; text: "Notificaciones"; color: root.muted; font.family: root.fontSans; font.pixelSize: 11 }
                Text {
                    text: "Limpiar todo"
                    color: clearMouse.containsMouse ? "#a3eeee" : root.accent
                    font.family: root.fontSans
                    font.pixelSize: 10
                    visible: notificationList.count > 0
                    MouseArea { id: clearMouse; anchors.fill: parent; anchors.margins: -5; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if (root.shellRoot && root.shellRoot.notificationHistory) root.shellRoot.notificationHistory.clear() }
                }
            }

            ListView {
                id: notificationList
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: 5
                model: root.shellRoot && root.shellRoot.notificationHistory ? root.shellRoot.notificationHistory.model : null

                delegate: ControlNotification {
                    width: ListView.view.width
                    appName: model.appName || "Sistema"
                    summary: model.summary || "Notificación"
                    body: model.body || ""
                    image: model.image || ""
                    time: model.time || ""
                    onRemoveRequested: if (root.shellRoot && root.shellRoot.notificationHistory) root.shellRoot.notificationHistory.remove(index)
                }

                Text {
                    anchors.centerIn: parent
                    visible: notificationList.count === 0
                    text: "No hay notificaciones"
                    color: "#6f6b70"
                    font.family: root.fontSans
                    font.pixelSize: 11
                }
            }
        }
    }

    WifiPanel {
        id: wifiPanel
        width: parent.width
        height: parent.height
        x: root.currentPage === 1 ? 0 : root.width
        enabled: root.currentPage === 1
        opacity: root.currentPage === 1 ? 1 : 0
        onBackRequested: root.currentPage = 0
        Behavior on x { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
        Behavior on opacity { NumberAnimation { duration: 160 } }
    }

    BluetoothPanel {
        id: bluetoothPanel
        width: parent.width
        height: parent.height
        x: root.currentPage === 2 ? 0 : root.width
        enabled: root.currentPage === 2
        opacity: root.currentPage === 2 ? 1 : 0
        onBackRequested: root.currentPage = 0
        Behavior on x { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
        Behavior on opacity { NumberAnimation { duration: 160 } }
    }

    component ConnectivityTile: Rectangle {
        id: tile
        property string icon: ""
        property string title: ""
        property string subtitle: ""
        property bool enabledState: false
        signal clicked()

        radius: height / 2
        color: tileMouse.containsMouse ? root.cardHover : root.card
        scale: tileMouse.pressed ? 0.98 : 1
        Behavior on color { ColorAnimation { duration: 120 } }
        Behavior on scale { NumberAnimation { duration: 90 } }

        RowLayout {
            anchors.fill: parent
            anchors.margins: 10
            spacing: 10

            Rectangle {
                Layout.preferredWidth: 38
                Layout.preferredHeight: 38
                radius: 19
                color: tile.enabledState ? root.accent : "#302e31"
                Text { anchors.centerIn: parent; text: tile.icon; color: tile.enabledState ? "#102526" : "#b2adb2"; font.family: root.fontIcon; font.pixelSize: 16 }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                Text { Layout.fillWidth: true; text: tile.title; color: root.foreground; font.family: root.fontSans; font.pixelSize: 12; font.weight: Font.DemiBold; elide: Text.ElideRight }
                Text { Layout.fillWidth: true; text: tile.subtitle; color: root.muted; font.family: root.fontSans; font.pixelSize: 9; elide: Text.ElideRight }
            }

            Text { text: "›"; color: "#625e63"; font.pixelSize: 19 }
        }

        MouseArea { id: tileMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: tile.clicked() }
    }

    component CircleAction: Rectangle {
        id: action
        property string icon: ""
        property bool activeState: false
        signal clicked()

        radius: height / 2
        color: activeState ? "#284345" : (actionMouse.containsMouse ? "#282629" : root.card)
        scale: actionMouse.pressed ? 0.94 : 1
        Behavior on scale { NumberAnimation { duration: 90 } }
        Text { anchors.centerIn: parent; text: action.icon; color: action.activeState ? root.accent : root.foreground; font.family: root.fontIcon; font.pixelSize: 15 }
        MouseArea { id: actionMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: action.clicked() }
    }

    component SliderCard: Rectangle {
        id: sliderCard
        property string label: ""
        property string icon: ""
        property real level: 0
        signal levelEdited(real value, bool committed)

        radius: 17
        color: root.card

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 10
            spacing: 7

            Text { text: sliderCard.label; color: root.foreground; font.family: root.fontSans; font.pixelSize: 11; font.weight: Font.DemiBold }

            Rectangle {
                id: track
                Layout.fillWidth: true
                Layout.fillHeight: true
                radius: height / 2
                color: "#0e0d0f"
                clip: true

                Rectangle {
                    width: Math.max(parent.height, parent.width * Math.max(0, Math.min(100, sliderCard.level)) / 100)
                    height: parent.height
                    radius: parent.radius
                    color: root.accent
                    Behavior on width { enabled: !trackMouse.pressed; NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                }

                Text { anchors.left: parent.left; anchors.leftMargin: 11; anchors.verticalCenter: parent.verticalCenter; text: sliderCard.icon; color: "#102526"; font.family: root.fontIcon; font.pixelSize: 13 }

                MouseArea {
                    id: trackMouse
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    function apply(mouse, committed) { sliderCard.levelEdited(Math.max(0, Math.min(100, mouse.x * 100 / width)), committed) }
                    onPressed: (mouse) => apply(mouse, false)
                    onPositionChanged: (mouse) => { if (pressed) apply(mouse, false) }
                    onReleased: (mouse) => apply(mouse, true)
                }
            }
        }
    }
}
