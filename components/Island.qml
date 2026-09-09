import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import Quickshell.Services.Pipewire
import "Wallpaper"
import "../Minerva" as Minerva

// ── Dynamic Island ───────────────────────────────────────────────────────────
// Píldora interactiva modular con varios estados:
// 1. Compacto: Reloj centrado (140x38).
// 2. Hover expandido: Controles de música + Calendario de 7 días (530x110).
// 3. Launcher abierto: Búsqueda y lista de apps con rebote orgánico (~520xAlto).
// 4. Centro de control: panel de sistema navegable, accesible solo mediante IPC.
// 5. Minerva: chat agentivo y visualización de voz.
// 6. Alerta transitoria de batería: animación fluida al conectar/desconectar cargador.
// 7. OSD transitorio de volumen y brillo: indicador dinámico con feedback visual reactivo.
// ─────────────────────────────────────────────────────────────────────────────
Item {
    id: root

    property var currentDate: new Date()
    property var shellRoot: null
    property var minervaService: null
    property bool isExpanded: false
    property bool launcherOpen: false
    property bool controlCenterOpen: false
    property bool minervaOpen: false
    property bool wallpaperOpen: false
    property bool powerMenuOpen: false
    property bool suppressHoverUntilExit: false
    readonly property var notification: shellRoot ? shellRoot.notificationPopup : null
    readonly property bool notificationOpen: notification !== null && !launcherOpen && !controlCenterOpen && !minervaOpen && !wallpaperOpen && !powerMenuOpen
    onNotificationOpenChanged: {
        if (!notificationOpen) {
            root.isExpanded = false
            root.suppressHoverUntilExit = true
        }
    }
    readonly property bool minervaBusy: minervaService && (
        minervaService.isRecording || minervaService.isTranscribing ||
        minervaService.isThinking || minervaService.isSpeaking)

    // ── Recordatorio Sutil y Periódico de Tarea Pendiente (Anti-Ansiedad) ─
    readonly property bool hasMinervaPendingTasks: minervaService ? minervaService.hasPendingTasks : false
    readonly property bool hasMinervaUrgentTasks: minervaService ? minervaService.hasUrgentTasks : false
    readonly property string minervaTaskUrgency: minervaService ? minervaService.taskUrgency : ""

    property bool taskReminderVisible: false

    onHasMinervaPendingTasksChanged: {
        if (hasMinervaPendingTasks) {
            root.taskReminderVisible = true
            taskReminderActiveTimer.restart()
            taskReminderIntervalTimer.stop()
        } else {
            root.taskReminderVisible = false
            taskReminderActiveTimer.stop()
            taskReminderIntervalTimer.stop()
        }
    }

    onMinervaTaskUrgencyChanged: {
        if (hasMinervaPendingTasks) {
            root.taskReminderVisible = true
            taskReminderActiveTimer.restart()
        }
    }

    // Temporizador: permanece visible durante 9 segundos con pulso suave
    Timer {
        id: taskReminderActiveTimer
        interval: 9000
        repeat: false
        onTriggered: {
            root.taskReminderVisible = false
            if (root.hasMinervaPendingTasks) {
                // Intervalo de descanso: 45s urgente, 90s media, 140s (~2.3 min) normal
                const delay = (root.hasMinervaUrgentTasks || root.minervaTaskUrgency === "urgent") ? 50000
                            : (root.minervaTaskUrgency === "medium" ? 100000 : 140000)
                taskReminderIntervalTimer.interval = delay
                taskReminderIntervalTimer.restart()
            }
        }
    }

    // Temporizador: intervalo periódico para volver a avisar brevemente
    Timer {
        id: taskReminderIntervalTimer
        interval: 120000
        repeat: false
        onTriggered: {
            if (root.hasMinervaPendingTasks) {
                root.taskReminderVisible = true
                taskReminderActiveTimer.restart()
            }
        }
    }

    // ── OSD Transitorio de Volumen y Brillo (Dynamic Island) ──────────────
    property bool osdVisible: false
    property string osdType: "volume" // "volume" | "brightness"
    property real osdValue: 0
    property bool osdMuted: false

    readonly property bool osdOpen: osdVisible && !launcherOpen && !controlCenterOpen && !minervaOpen && !wallpaperOpen && !powerMenuOpen && !notificationOpen && !minervaBusy && !isExpanded
    readonly property int osdIslandWidth: 200

    function triggerOsd(type, value, muted) {
        root.osdType = type
        root.osdValue = Math.max(0, Math.min(150, value))
        root.osdMuted = (type === "volume") ? !!muted : false
        root.osdVisible = true
        osdHideTimer.restart()
    }

    Timer {
        id: osdHideTimer
        interval: 2000
        repeat: false
        onTriggered: root.osdVisible = false
    }

    // ── Rastreador Pipewire para Volumen ──────────────────────────────────
    PwObjectTracker {
        objects: Pipewire.defaultAudioSink ? [ Pipewire.defaultAudioSink ] : []
    }

    readonly property var defaultAudioSink: Pipewire.defaultAudioSink
    property bool audioInitialized: false
    property real lastAudioVolume: -1
    property bool lastAudioMuted: false

    onDefaultAudioSinkChanged: {
        if (root.defaultAudioSink && root.defaultAudioSink.audio) {
            root.lastAudioVolume = root.defaultAudioSink.audio.volume
            root.lastAudioMuted = root.defaultAudioSink.audio.muted
            root.audioInitialized = true
        }
    }

    Connections {
        target: (root.defaultAudioSink && root.defaultAudioSink.audio) ? root.defaultAudioSink.audio : null
        function onVolumeChanged() { root.handleAudioChange() }
        function onMutedChanged() { root.handleAudioChange() }
    }

    function triggerVolumeOsd(force) {
        if (!root.defaultAudioSink || !root.defaultAudioSink.audio) return
        const vol = root.defaultAudioSink.audio.volume
        const mut = root.defaultAudioSink.audio.muted

        if (!root.audioInitialized) {
            root.lastAudioVolume = vol
            root.lastAudioMuted = mut
            root.audioInitialized = true
            if (!force) return
        }

        if (!force && Math.abs(vol - root.lastAudioVolume) < 0.001 && mut === root.lastAudioMuted) return

        root.lastAudioVolume = vol
        root.lastAudioMuted = mut
        root.triggerOsd("volume", Math.round(vol * 100), mut)
    }

    function handleAudioChange() {
        root.triggerVolumeOsd(false)
    }

    // ── Rastreador de Brillo (brightnessctl para Laptop) ──────────────────
    Process {
        id: backlightUdevMonitor
        command: ["udevadm", "monitor", "--subsystem-match=backlight", "--udev"]
        running: true
        stdout: SplitParser {
            onRead: data => {
                if (data && (data.includes("change") || data.includes("backlight"))) {
                    if (!brightnessQuery.running) brightnessQuery.running = true
                }
            }
        }
    }

    Process {
        id: brightnessQuery
        command: ["bash", "-c", "brightnessctl -m 2>/dev/null | cut -d, -f4 | tr -d '% '"]
        stdout: StdioCollector {
            onStreamFinished: {
                const val = parseFloat(String(text || "").trim())
                if (isFinite(val)) {
                    root.triggerBrightnessOsd(val)
                }
            }
        }
    }

    property bool brightnessInitialized: false
    property real lastBrightness: -1

    function triggerBrightnessOsd(pct) {
        if (!isFinite(pct)) return
        const val = Math.max(0, Math.min(100, Math.round(pct)))
        if (!root.brightnessInitialized) {
            root.lastBrightness = val
            root.brightnessInitialized = true
            return
        }
        if (Math.abs(val - root.lastBrightness) < 1) return
        root.lastBrightness = val
        root.triggerOsd("brightness", val, false)
    }

    // ── Notificación transitoria de batería (Dynamic Island) ──────────────
    property bool batteryToastVisible: false
    property string batteryToastText: ""
    property string batteryToastIcon: "󰂄"
    property color batteryToastColor: "#a6e3a1"
    readonly property bool batteryToastOpen: batteryToastVisible && !launcherOpen && !controlCenterOpen && !minervaOpen && !wallpaperOpen && !powerMenuOpen && !notificationOpen && !minervaBusy && !osdOpen

    property int lastBatteryState: -1
    property real lastBatteryPct: -1
    property bool batteryInitialized: false

    Connections {
        target: UPower.displayDevice
        function onStateChanged() {
            if (!UPower.displayDevice || !UPower.displayDevice.isPresent) return
            const currentState = UPower.displayDevice.state
            const pct = Math.round(UPower.displayDevice.percentage * 100)
            
            if (!root.batteryInitialized) {
                root.lastBatteryState = currentState
                root.lastBatteryPct = pct
                root.batteryInitialized = true
                return
            }

            if (currentState !== root.lastBatteryState) {
                if (currentState === UPowerDeviceState.Charging || currentState === UPowerDeviceState.PendingCharge) {
                    root.triggerBatteryToast("󰂄", "Cargando • " + pct + "%", "#a6e3a1")
                } else if (root.lastBatteryState === UPowerDeviceState.Charging || root.lastBatteryState === UPowerDeviceState.PendingCharge) {
                    root.triggerBatteryToast("󰁹", "Desconectado • " + pct + "%", "#fab387")
                }
                root.lastBatteryState = currentState
            }
        }

        function onPercentageChanged() {
            if (!UPower.displayDevice || !UPower.displayDevice.isPresent) return
            const pct = Math.round(UPower.displayDevice.percentage * 100)
            const isDischarging = UPower.displayDevice.state === UPowerDeviceState.Discharging
            
            if (root.batteryInitialized && isDischarging) {
                if (pct <= 20 && root.lastBatteryPct > 20) {
                    root.triggerBatteryToast("󰂃", "Batería baja • " + pct + "%", "#f38ba8")
                } else if (pct <= 10 && root.lastBatteryPct > 10) {
                    root.triggerBatteryToast("󰂃", "Batería muy baja • " + pct + "%", "#f38ba8")
                }
            }
            root.lastBatteryPct = pct
        }
    }

    function triggerBatteryToast(icon, text, color) {
        root.batteryToastIcon = icon
        root.batteryToastText = text
        root.batteryToastColor = color
        root.batteryToastVisible = true
        batteryToastTimer.restart()
    }

    Timer {
        id: batteryToastTimer
        interval: 3500
        repeat: false
        onTriggered: root.batteryToastVisible = false
    }

    // Referencia al launcher embebido
    property alias launcherRef: launcher

    // Dimensiones reactivas según el estado
    readonly property int launcherWidth: 520
    readonly property int controlCenterWidth: 500
    readonly property int minervaWidth: 720
    readonly property int minervaHeight: 680
    readonly property int wallpaperWidth: 740
    readonly property int wallpaperHeight: 330
    readonly property int powerMenuWidth: 436
    readonly property int powerMenuHeight: 88
    readonly property int minervaWaveformIslandWidth: 210
    readonly property int batteryToastIslandWidth: 210
    readonly property bool minervaSettingsOpen: minervaPanelLoader.item ? minervaPanelLoader.item.settingsOpen : false
    readonly property int minervaSettingsHeight: minervaPanelLoader.item ? minervaPanelLoader.item.settingsImplicitHeight : minervaHeight
    width: powerMenuOpen ? powerMenuWidth : (minervaOpen ? minervaWidth : (wallpaperOpen ? wallpaperWidth : (controlCenterOpen ? controlCenterWidth : (launcherOpen ? launcherWidth : (notificationOpen ? 430 : (isExpanded ? 530 : (minervaBusy ? minervaWaveformIslandWidth : (osdOpen ? osdIslandWidth : (batteryToastOpen ? batteryToastIslandWidth : 140)))))))))
    height: powerMenuOpen ? powerMenuHeight : (minervaOpen ? (minervaSettingsOpen ? Math.min(minervaHeight, minervaSettingsHeight) : minervaHeight) : (wallpaperOpen ? wallpaperHeight : (controlCenterOpen ? controlCenter.contentHeight : (launcherOpen ? launcher.contentHeight : (notificationOpen ? 92 : (isExpanded ? 110 : 38))))))
    property real radius: (powerMenuOpen || launcherOpen || controlCenterOpen || minervaOpen || notificationOpen || wallpaperOpen) ? 26 : (isExpanded ? 26 : (height / 2))

    property color pillColor: (root.controlCenterOpen || root.minervaOpen || root.wallpaperOpen) ? Qt.rgba(0.035, 0.035, 0.04, 0.96) : '#000000'
    property color pillBorderColor: (powerMenuOpen || launcherOpen || controlCenterOpen || minervaOpen || notificationOpen || wallpaperOpen) ? "#343135" : (isExpanded ? "#313244" : "#1e1e2e")

    // Animación de expansión con rebote dinámico (Apple Dynamic Island style)
    Behavior on width {
        NumberAnimation {
            duration: (root.powerMenuOpen || root.launcherOpen || root.minervaOpen || root.wallpaperOpen || root.isExpanded || root.notificationOpen || root.minervaBusy || root.batteryToastOpen || root.osdOpen) ? 380 : 250
            easing.type: (root.powerMenuOpen || root.launcherOpen || root.minervaOpen || root.wallpaperOpen || root.isExpanded || root.notificationOpen || root.minervaBusy || root.batteryToastOpen || root.osdOpen) ? Easing.OutBack : Easing.OutCubic
            easing.overshoot: (root.powerMenuOpen || root.launcherOpen || root.minervaOpen || root.wallpaperOpen || root.isExpanded || root.notificationOpen || root.minervaBusy || root.batteryToastOpen || root.osdOpen) ? 1.15 : 0.0
        }
    }

    Behavior on height {
        NumberAnimation {
            duration: (root.powerMenuOpen || root.launcherOpen || root.minervaOpen || root.wallpaperOpen || root.isExpanded || root.notificationOpen) ? 380 : 250
            easing.type: (root.powerMenuOpen || root.launcherOpen || root.minervaOpen || root.wallpaperOpen || root.isExpanded || root.notificationOpen) ? Easing.OutBack : Easing.OutCubic
            easing.overshoot: (root.powerMenuOpen || root.launcherOpen || root.minervaOpen || root.wallpaperOpen || root.isExpanded || root.notificationOpen) ? 1.15 : 0.0
        }
    }

    Behavior on radius {
        NumberAnimation {
            duration: 250
            easing.type: Easing.OutCubic
        }
    }

    Behavior on pillBorderColor {
        ColorAnimation { duration: 150 }
    }

    Behavior on pillColor {
        ColorAnimation { duration: 180 }
    }

    // ── Funciones de control del Launcher / Centro de control / Minerva / Wallpaper ──
    function openLauncher() {
        collapseTimer.stop()
        root.suppressHoverUntilExit = false
        if (root.controlCenterOpen)
            closeControlCenter()
        if (root.minervaOpen)
            closeMinerva()
        if (root.wallpaperOpen)
            closeWallpaper()
        if (root.powerMenuOpen)
            closePowerMenu()
        root.launcherOpen = true
        launcher.open()
    }

    function closeLauncher() {
        root.launcherOpen = false
        launcher.close()
        root.isExpanded = false
        root.suppressHoverUntilExit = true
    }

    function toggleLauncher() {
        if (root.launcherOpen) closeLauncher()
        else openLauncher()
    }

    // El centro de control se expone deliberadamente solo mediante IPC.
    function openControlCenter() {
        collapseTimer.stop()
        root.suppressHoverUntilExit = false
        if (root.launcherOpen)
            closeLauncher()
        if (root.minervaOpen)
            closeMinerva()
        if (root.wallpaperOpen)
            closeWallpaper()
        if (root.powerMenuOpen)
            closePowerMenu()
        root.controlCenterOpen = true
        controlCenter.open()
    }

    function closeControlCenter() {
        root.controlCenterOpen = false
        controlCenter.close()
        root.isExpanded = false
        root.suppressHoverUntilExit = true
    }

    function toggleControlCenter() {
        if (root.controlCenterOpen) closeControlCenter()
        else openControlCenter()
    }

    function openMinerva() {
        collapseTimer.stop()
        root.suppressHoverUntilExit = false
        if (root.launcherOpen) closeLauncher()
        if (root.controlCenterOpen) closeControlCenter()
        if (root.wallpaperOpen) closeWallpaper()
        if (root.powerMenuOpen) closePowerMenu()
        root.minervaOpen = true
        Qt.callLater(function() {
            if (minervaPanelLoader.item) minervaPanelLoader.item.takeFocus()
        })
    }

    function closeMinerva() {
        root.minervaOpen = false
        root.isExpanded = false
        root.suppressHoverUntilExit = true
    }

    function toggleMinerva() {
        if (root.minervaOpen) closeMinerva()
        else openMinerva()
    }

    function openMinervaSettings() {
        openMinerva()
        Qt.callLater(function() {
            if (minervaPanelLoader.item)
                minervaPanelLoader.item.settingsOpen = true
        })
    }

    function openWallpaper() {
        collapseTimer.stop()
        root.suppressHoverUntilExit = false
        if (root.launcherOpen) closeLauncher()
        if (root.controlCenterOpen) closeControlCenter()
        if (root.minervaOpen) closeMinerva()
        if (root.powerMenuOpen) closePowerMenu()
        root.wallpaperOpen = true
        Qt.callLater(function() {
            if (wallpaperPanelLoader.item)
                wallpaperPanelLoader.item.open()
        })
    }

    function closeWallpaper() {
        root.wallpaperOpen = false
        if (wallpaperPanelLoader.item)
            wallpaperPanelLoader.item.close()
        root.isExpanded = false
        root.suppressHoverUntilExit = true
    }

    function toggleWallpaper() {
        if (root.wallpaperOpen) closeWallpaper()
        else openWallpaper()
    }

    function openPowerMenu() {
        collapseTimer.stop()
        root.suppressHoverUntilExit = false
        if (root.launcherOpen) closeLauncher()
        if (root.controlCenterOpen) closeControlCenter()
        if (root.minervaOpen) closeMinerva()
        if (root.wallpaperOpen) closeWallpaper()
        root.powerMenuOpen = true
        Qt.callLater(function() {
            if (powerMenuPanelLoader.item)
                powerMenuPanelLoader.item.open()
        })
    }

    function closePowerMenu() {
        root.powerMenuOpen = false
        root.isExpanded = false
        root.suppressHoverUntilExit = true
    }

    function togglePowerMenu() {
        if (root.powerMenuOpen) closePowerMenu()
        else openPowerMenu()
    }

    // ── Sombra sutil inferior para dar profundidad 3D ───────────────────────
    Rectangle {
        id: shadowDummy
        anchors.left: parent.left
        anchors.leftMargin: 4
        anchors.right: parent.right
        anchors.rightMargin: 4
        anchors.top: parent.top
        anchors.topMargin: 8
        anchors.bottom: parent.bottom
        radius: root.radius
        color: "black"
        visible: false
    }

    MultiEffect {
        source: shadowDummy
        anchors.fill: shadowDummy

        shadowEnabled: true
        shadowColor: Qt.rgba(0.0, 0.0, 0.0, 0.65)
        shadowBlur: 0.65
        shadowVerticalOffset: 7
        shadowHorizontalOffset: 0
        opacity: 0.85
    }

    // ── Fondo de la píldora y contenedor con clip ───────────────────────────
    Rectangle {
        id: pillBg
        anchors.fill: parent
        radius: root.radius
        color: root.pillColor
        border.color: root.pillBorderColor
        border.width: 1
        clip: true

    // ── 1. VISTA DE MÚSICA (Izquierda - solo visible al expandir en hover) ────
    MediaWidget {
        anchors.left: parent.left
        anchors.leftMargin: 16
        anchors.verticalCenter: parent.verticalCenter
        opacity: (root.isExpanded && !root.launcherOpen && !root.controlCenterOpen && !root.minervaOpen && !root.notificationOpen && !root.wallpaperOpen && !root.powerMenuOpen) ? 1 : 0
        visible: opacity > 0

        Behavior on opacity {
            NumberAnimation { duration: 150 }
        }
    }

    // ── 2. RELOJ Y CALENDARIO (Transición compartida del reloj) ──────────────
    ClockCalendar {
        anchors.right: parent.right
        anchors.rightMargin: 24
        anchors.verticalCenter: parent.verticalCenter
        currentDate: root.currentDate
        isExpanded: root.isExpanded
        islandWidth: root.width
        islandHeight: root.height
        rightMargin: 24
        opacity: (root.powerMenuOpen || root.launcherOpen || root.controlCenterOpen || root.minervaOpen || root.notificationOpen || root.wallpaperOpen || (root.minervaBusy && !root.isExpanded) || root.batteryToastOpen || root.osdOpen) ? 0 : 1
        visible: opacity > 0

        Behavior on opacity {
            NumberAnimation { duration: 150 }
        }
    }

    // ── 3. APP LAUNCHER INTEGRADO ────────────────────────────────────────────
    AppLauncher {
        id: launcher
        anchors.fill: parent
        active: root.launcherOpen
        opacity: root.launcherOpen ? 1 : 0
        visible: opacity > 0
        onCloseRequested: root.closeLauncher()

        Behavior on opacity {
            NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
        }
    }

    // ── 4. CENTRO DE CONTROL INTEGRADO ─────────────────────────────────
    ControlCenter {
        id: controlCenter
        anchors.fill: parent
        shellRoot: root.shellRoot
        active: root.controlCenterOpen
        opacity: root.controlCenterOpen ? 1 : 0
        visible: opacity > 0

        Behavior on opacity {
            NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
        }
    }

    // ── 5. MINERVA ────────────────────────────────────────────────────────
    Loader {
        id: minervaPanelLoader
        anchors.fill: parent
        active: root.minervaOpen
        opacity: root.minervaOpen ? 1 : 0
        visible: opacity > 0
        sourceComponent: Component {
            Minerva.ChatWidget {
                aiWidget: root.minervaService
                onCloseRequested: root.closeMinerva()
            }
        }

        Behavior on opacity {
            NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
        }
    }

    // ── 6. SELECTOR DE FONDOS DE PANTALLA (WALLPAPER PICKER) ───────────
    Loader {
        id: wallpaperPanelLoader
        anchors.fill: parent
        active: root.wallpaperOpen
        opacity: root.wallpaperOpen ? 1 : 0
        visible: opacity > 0
        sourceComponent: Component {
            WallpaperPicker {
                shellRoot: root.shellRoot
                active: root.wallpaperOpen
                onCloseRequested: root.closeWallpaper()
            }
        }

        Behavior on opacity {
            NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
        }
    }

    // ── 7. MENÚ DE APAGADO (POWER MENU) ───────────────────────────
    Loader {
        id: powerMenuPanelLoader
        anchors.fill: parent
        active: root.powerMenuOpen
        opacity: root.powerMenuOpen ? 1 : 0
        visible: opacity > 0
        sourceComponent: Component {
            PowerMenu {
                shellRoot: root.shellRoot
                active: root.powerMenuOpen
                onCloseRequested: root.closePowerMenu()
            }
        }

        Behavior on opacity {
            NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
        }
    }

    // Visualización transitoria de Minerva. En reposo desaparece por completo;
    // cuando está activa reemplaza temporalmente al reloj y al MediaWidget.
    Item {
        id: minervaButton
        anchors.centerIn: parent
        width: Math.min(parent.width - 32, 172)
        height: parent.height
        visible: root.minervaBusy && !root.isExpanded && !root.launcherOpen && !root.controlCenterOpen && !root.minervaOpen && !root.notificationOpen && !root.wallpaperOpen && !root.powerMenuOpen
        z: 20

        opacity: visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.InOutQuad } }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.openMinerva()
        }

        Minerva.Minerva_waveform {
            anchors.fill: parent
            isRecording: root.minervaService ? root.minervaService.isRecording : false
            isTranscribing: root.minervaService ? root.minervaService.isTranscribing : false
            isThinking: root.minervaService ? root.minervaService.isThinking : false
            isSpeaking: root.minervaService ? root.minervaService.isSpeaking : false
            isPendingTask: root.minervaService ? root.minervaService.hasPendingTasks : false
            isUrgentTask: root.minervaService ? root.minervaService.hasUrgentTasks : false
            taskUrgency: root.minervaService ? root.minervaService.taskUrgency : ""
            audioRms: root.shellRoot ? root.shellRoot.audioRms : 0
            audioBand0: root.shellRoot ? root.shellRoot.audioBand0 : 0
            audioBand1: root.shellRoot ? root.shellRoot.audioBand1 : 0
            audioBand2: root.shellRoot ? root.shellRoot.audioBand2 : 0
            audioBand3: root.shellRoot ? root.shellRoot.audioBand3 : 0
        }

    }

    // ── 7. AVISO TRANSITORIO DE NOTIFICACIÓN ───────────────────────────
    NotificationToast {
        anchors.fill: parent
        notification: root.notification
        opacity: root.notificationOpen ? 1 : 0
        visible: opacity > 0
        onDismissed: {
            root.isExpanded = false
            root.suppressHoverUntilExit = true
            if (root.shellRoot)
                root.shellRoot.dismissNotificationPopup()
        }

        Behavior on opacity {
            NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
    }

    // ── 8. AVISO TRANSITORIO DE BATERÍA (Dynamic Island Toast) ─────────
    Item {
        id: batteryToastItem
        anchors.centerIn: parent
        width: parent.width
        height: parent.height
        opacity: root.batteryToastOpen ? 1 : 0
        visible: opacity > 0
        z: 22

        Behavior on opacity {
            NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }

        RowLayout {
            anchors.centerIn: parent
            spacing: 8

            Text {
                text: root.batteryToastIcon
                color: root.batteryToastColor
                font.family: "Symbols Nerd Font, Iosevka Nerd Font"
                font.pixelSize: 16
                Layout.alignment: Qt.AlignVCenter
            }

            Text {
                text: root.batteryToastText
                color: "#FFFFFF"
                font.family: "SF Pro Display, SF Pro, sans-serif"
                font.pixelSize: 13
                font.weight: Font.DemiBold
                Layout.alignment: Qt.AlignVCenter
            }
        }
    }

    // ── 9. AVISO TRANSITORIO DE VOLUMEN Y BRILLO (Dynamic Island OSD) ────
    Item {
        id: osdItem
        anchors.centerIn: parent
        width: parent.width
        height: parent.height
        opacity: root.osdOpen ? 1 : 0
        visible: opacity > 0
        z: 23

        Behavior on opacity {
            NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            spacing: 10

            Text {
                text: {
                    if (root.osdType === "volume") {
                        if (root.osdMuted || root.osdValue === 0) return "󰝟"
                        if (root.osdValue < 33) return "󰕿"
                        if (root.osdValue < 66) return "󰖀"
                        return "󰕾"
                    } else {
                        if (root.osdValue < 33) return "󰃞"
                        if (root.osdValue < 66) return "󰃟"
                        return "󰃠"
                    }
                }
                color: root.osdMuted ? "#f38ba8" : (root.osdType === "volume" ? "#78d1d3" : "#f9e2af")
                font.family: "Symbols Nerd Font, Iosevka Nerd Font"
                font.pixelSize: 16
                Layout.alignment: Qt.AlignVCenter
            }

            Rectangle {
                id: osdTrack
                Layout.fillWidth: true
                Layout.preferredHeight: 6
                Layout.alignment: Qt.AlignVCenter
                radius: 3
                color: Qt.rgba(1, 1, 1, 0.16)

                Rectangle {
                    id: osdFill
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: Math.max(0, Math.min(parent.width, parent.width * (root.osdValue / 100)))
                    radius: 3
                    color: root.osdMuted ? "#f38ba8" : (root.osdType === "volume" ? "#78d1d3" : "#f9e2af")

                    Behavior on width {
                        NumberAnimation { duration: 90; easing.type: Easing.OutCubic }
                    }
                }
            }

            Text {
                text: root.osdMuted ? "Mute" : Math.round(root.osdValue) + "%"
                color: root.osdMuted ? "#f38ba8" : "#f5f2f4"
                font.family: "SF Pro Display, SF Pro, sans-serif"
                font.pixelSize: 12
                font.weight: Font.DemiBold
                Layout.preferredWidth: 36
                horizontalAlignment: Text.AlignRight
                Layout.alignment: Qt.AlignVCenter
            }
        }
    }

    // ── 10. INDICADOR PERIÓDICO DE TAREA PENDIENTE (SUTIL & ANTI-ANSIEDAD) ──
    Item {
        id: taskPipContainer
        anchors.right: parent.right
        anchors.rightMargin: 14
        anchors.verticalCenter: parent.verticalCenter
        width: 14
        height: 14
        z: 18

        readonly property bool shouldBeVisible: root.hasMinervaPendingTasks
            && root.taskReminderVisible
            && !root.launcherOpen
            && !root.controlCenterOpen
            && !root.minervaOpen
            && !root.wallpaperOpen
            && !root.powerMenuOpen
            && !root.notificationOpen
            && !root.minervaBusy
            && !root.batteryToastOpen
            && !root.osdOpen
            && !root.isExpanded

        opacity: shouldBeVisible ? 1 : 0
        visible: opacity > 0

        Behavior on opacity {
            NumberAnimation { duration: 400; easing.type: Easing.InOutQuad }
        }

        Rectangle {
            id: taskPip
            anchors.centerIn: parent
            width: 6
            height: 6
            radius: 3

            color: {
                if (root.hasMinervaUrgentTasks || root.minervaTaskUrgency === "urgent") return "#f38ba8"
                if (root.minervaTaskUrgency === "medium") return "#fab387"
                return "#78d1d3"
            }

            Behavior on color {
                ColorAnimation { duration: 250 }
            }

            // Pulso continuo suave en todos los estados (la velocidad aumenta según urgencia)
            readonly property int pulsePeriod: {
                if (root.hasMinervaUrgentTasks || root.minervaTaskUrgency === "urgent") return 1000
                if (root.minervaTaskUrgency === "medium") return 1500
                return 2000
            }

            SequentialAnimation on scale {
                running: taskPipContainer.shouldBeVisible
                loops: Animation.Infinite

                NumberAnimation {
                    to: 1.35
                    duration: taskPip.pulsePeriod / 2
                    easing.type: Easing.InOutSine
                }
                NumberAnimation {
                    to: 0.85
                    duration: taskPip.pulsePeriod / 2
                    easing.type: Easing.InOutSine
                }
            }

            SequentialAnimation on opacity {
                running: taskPipContainer.shouldBeVisible
                loops: Animation.Infinite

                NumberAnimation {
                    to: 1.0
                    duration: taskPip.pulsePeriod / 2
                    easing.type: Easing.InOutSine
                }
                NumberAnimation {
                    to: 0.40
                    duration: taskPip.pulsePeriod / 2
                    easing.type: Easing.InOutSine
                }
            }
        }

        MouseArea {
            anchors.fill: parent
            anchors.margins: -8
            cursorShape: Qt.PointingHandCursor
            onClicked: root.openMinerva()
        }
    }

    // ── 11. DETECCIÓN DE HOVER SIN CONSUMIR CLICKS (HoverHandler) ────────────
    HoverHandler {
        id: islandHover
        enabled: !root.launcherOpen && !root.controlCenterOpen && !root.minervaOpen && !root.notificationOpen && !root.wallpaperOpen && !root.powerMenuOpen
        onHoveredChanged: {
            if (root.launcherOpen || root.controlCenterOpen || root.minervaOpen || root.notificationOpen || root.wallpaperOpen || root.powerMenuOpen) return
            if (hovered) {
                if (!root.suppressHoverUntilExit) {
                    collapseTimer.stop()
                    root.isExpanded = true
                }
            } else {
                root.suppressHoverUntilExit = false
                collapseTimer.restart()
            }
        }
    }

    Timer {
        id: collapseTimer
        interval: 220
        repeat: false
        onTriggered: {
            if (!root.launcherOpen && !root.controlCenterOpen && !root.minervaOpen && !root.notificationOpen && !root.wallpaperOpen && !root.powerMenuOpen && !islandHover.hovered) {
                root.isExpanded = false
            }
        }
    }
    }
}
