import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Notifications
import "components"
import "HyprQuickFrame"
import "Minerva" as Minerva


ShellRoot {
    id: root

    // Servicio único: las notificaciones se comparten entre monitores.
    property bool screenshotActive: false
    property bool dndEnabled: false
    property bool commandApprovalOpen: false
    property var notificationPopup: null

    // Estado global de Minerva. El servicio se instancia una sola vez aunque
    // haya varias pantallas; las islas comparten conversación y backend.
    property bool minervaActive: false
    property string minervaState: "idle"
    property real audioRms: 0.0
    property real audioBand0: 0.0
    property real audioBand1: 0.0
    property real audioBand2: 0.0
    property real audioBand3: 0.0
    property alias minervaService: minervaBackend
    property var notificationServer: NotificationServer {
        actionsSupported: true
        imageSupported: true
        bodyImagesSupported: true
        keepOnReload: true
    }
    property var notificationHistory: NotificationHistory {
        server: root.notificationServer
    }

    Connections {
        target: root.notificationHistory
        function onNotificationArrived(entry) {
            // DND oculta el aviso emergente, nunca borra el historial.
            if (!root.dndEnabled || entry.urgency === 2) {
                root.notificationPopup = entry
                notificationPopupTimer.restart()
            }
        }
    }

    Timer {
        id: notificationPopupTimer
        interval: 5500
        repeat: false
        onTriggered: root.notificationPopup = null
    }

    function dismissNotificationPopup() {
        notificationPopupTimer.stop()
        notificationPopup = null
    }

    function openMinerva(targetIsland) {
        let opened = false
        for (let i = 0; i < variantsModel.instances.length; i++) {
            let inst = variantsModel.instances[i]
            if (inst && inst.islandRef) {
                if ((!targetIsland && !opened) || inst.islandRef === targetIsland) {
                    inst.islandRef.openMinerva()
                    opened = true
                }
                else inst.islandRef.closeMinerva()
            }
        }
    }

    Minerva.Main {
        id: minervaBackend
        shellRoot: root
        visible: false
        onAttentionRequested: root.openMinerva(null)
    }

    // Reloj del sistema centralizado con precisión en segundos
    SystemClock {
        id: clock
        precision: SystemClock.Seconds
    }

    // ── IPC: permite activar el launcher desde Hyprland (Super+Space) ───────
    // Uso: quickshell ipc call shell toggleLauncher
    IpcHandler {
        target: "shell"
        function toggleLauncher() {
            // Buscar la isla en el primer monitor activo
            for (let i = 0; i < variantsModel.instances.length; i++) {
                let inst = variantsModel.instances[i]
                if (inst && inst.islandRef) {
                    inst.islandRef.toggleLauncher()
                }
            }
        }

        function launchScreenshot() {
            root.screenshotActive = true;
        }


        function toggleControlCenter() {
            for (let i = 0; i < variantsModel.instances.length; i++) {
                let inst = variantsModel.instances[i]
                if (inst && inst.islandRef) {
                    inst.islandRef.toggleControlCenter()
                }
            }
        }

        function toggleMinerva() {
            for (let i = 0; i < variantsModel.instances.length; i++) {
                let inst = variantsModel.instances[i]
                if (inst && inst.islandRef) {
                    inst.islandRef.toggleMinerva()
                    break
                }
            }
        }

        function toggleWallpaper() {
            for (let i = 0; i < variantsModel.instances.length; i++) {
                let inst = variantsModel.instances[i]
                if (inst && inst.islandRef) {
                    inst.islandRef.toggleWallpaper()
                    break
                }
            }
        }

        function openMinervaSettings() {
            for (let i = 0; i < variantsModel.instances.length; i++) {
                let inst = variantsModel.instances[i]
                if (inst && inst.islandRef) {
                    root.openMinerva(inst.islandRef)
                    inst.islandRef.openMinervaSettings()
                    break
                }
            }
        }

        function togglePowerMenu() {
            for (let i = 0; i < variantsModel.instances.length; i++) {
                let inst = variantsModel.instances[i]
                if (inst && inst.islandRef) {
                    inst.islandRef.togglePowerMenu()
                    break
                }
            }
        }

        function openPowerMenu() {
            for (let i = 0; i < variantsModel.instances.length; i++) {
                let inst = variantsModel.instances[i]
                if (inst && inst.islandRef) {
                    inst.islandRef.openPowerMenu()
                    break
                }
            }
        }

        function closePowerMenu() {
            for (let i = 0; i < variantsModel.instances.length; i++) {
                let inst = variantsModel.instances[i]
                if (inst && inst.islandRef) {
                    inst.islandRef.closePowerMenu()
                }
            }
        }

        function lockscreen() {
            Quickshell.execDetached(["qs", "-p", Quickshell.env("HOME") + "/.config/minerva_shell/components/Lock.qml"]);
        }

        // Salida explícita de emergencia; siempre es segura e idempotente.
        function closeControlCenter() {
            for (let i = 0; i < variantsModel.instances.length; i++) {
                let inst = variantsModel.instances[i]
                if (inst && inst.islandRef) {
                    inst.islandRef.closeControlCenter()
                }
            }
        }

    }

    // Variants crea la barra en cada monitor conectado automáticamente
    Variants {
        id: variantsModel
        model: Quickshell.screens

        delegate: Component {
            Item {
                required property var modelData
                // Referencia a la isla de este monitor (para IPC)
                property alias islandRef: island

                // 1. Ventana invisible para reservar espacio exclusivo en Hyprland
                // Mantiene el resto de ventanas de Hyprland abajo sin empujarlas cuando la isla se expanda
                PanelWindow {
                    screen: modelData
                    anchors { top: true; left: true; right: true }
                    implicitHeight: 48
                    color: "transparent"
                    WlrLayershell.namespace: "minerva-bar"
                    WlrLayershell.layer: WlrLayer.Top
                    mask: Region {} // Región vacía: todos los clicks la traspasan
                }

                // 2. Ventana principal a pantalla completa para animaciones fluidas
                PanelWindow {
                    id: mainWindow
                    screen: modelData

                    // Abarca toda la pantalla fijamente para evitar recalcular su geometría en Wayland
                    anchors { top: true; bottom: true; left: true; right: true }
                    color: "transparent"
                    WlrLayershell.namespace: "minerva-shell"
                    WlrLayershell.layer: WlrLayer.Top
                    WlrLayershell.exclusionMode: WlrLayershell.Ignore
                    // Foco de teclado en Wayland: exclusivo solo cuando el launcher esté desplegado
                    // El centro no secuestra el foco global. OnDemand permite
                    // escribir contraseñas solo después de pulsar su campo.
                    WlrLayershell.keyboardFocus: (island.launcherOpen || island.minervaOpen || island.wallpaperOpen || island.powerMenuOpen)
                        ? WlrKeyboardFocus.Exclusive
                        : (island.controlCenterOpen ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None)

                    // Máscara reactiva: la isla dinámica y la micro-burbuja de workspaces
                    // Al expandirse la isla o brotar la burbuja, la máscara se actualiza en tiempo real
                    mask: Region {
                        Region {
                            item: island
                        }
                        Region {
                            item: wsBubble.opacity > 0.05 ? wsBubble : null
                        }
                    }

                    // Píldora interactiva modular con Launcher integrado
                    Island {
                        id: island
                        anchors.top: parent.top
                        anchors.topMargin: 10
                        anchors.horizontalCenter: parent.horizontalCenter
                        currentDate: clock.date
                        shellRoot: root
                        minervaService: root.minervaService
                    }

                    // Micro-burbuja flotante de workspaces (Split Bubble estilo Dynamic Island)
                    WorkspaceBubble {
                        id: wsBubble
                        anchors.right: island.left
                        anchors.rightMargin: 8
                        anchors.top: island.top
                        suppressed: island.isExpanded || island.launcherOpen || island.controlCenterOpen || island.minervaOpen || island.notificationOpen || island.wallpaperOpen || island.powerMenuOpen
                    }
                }
            }
        }
    }

    ScreenshotTool {
        active: root.screenshotActive
        onDone: root.screenshotActive = false
    }
}
