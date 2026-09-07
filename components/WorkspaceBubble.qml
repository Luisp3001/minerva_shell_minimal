import QtQuick
import Quickshell
import Quickshell.Hyprland

// ── Workspace Split Bubble (Dynamic Island Style) ───────────────────────────
// Micro-burbuja desprendida que brota elásticamente a la izquierda de la isla
// principal al cambiar de espacio de trabajo en Hyprland, o parpadea en rojo
// de forma persistente cuando existe una ventana urgente sin atender.
// ─────────────────────────────────────────────────────────────────────────────
Rectangle {
    id: root

    property bool suppressed: false
    property bool bubbleVisible: false
    property int currentWorkspaceId: -1
    property string currentWorkspaceName: ""
    property bool initialized: false

    // ── Estado de Alerta Urgente ─────────────────────────────────────────────
    property bool isUrgent: false
    property int urgentWorkspaceId: -1
    property string urgentWorkspaceName: ""
    property real pulseRatio: 0.0

    // Dimensiones y estética adaptada a la isla compacta
    height: 36
    width: Math.max(36, wsLabel.implicitWidth + 16)
    radius: height / 2

    // Estilo con respiración sutil en rojo cuando hay ventana urgente
    color: root.isUrgent
        ? Qt.rgba(0.18 * pulseRatio + 0.05, 0.04, 0.06, 0.95)
        : "#0b0b10"
    border.color: root.isUrgent
        ? Qt.rgba(0.95, 0.3, 0.38, 0.35 + 0.55 * pulseRatio)
        : "#1e1e2e"
    border.width: 1
    clip: true

    // El origen de transformación a la derecha hace que brote desde la isla
    transformOrigin: Item.Right
    scale: bubbleVisible ? 1.0 : 0.0
    opacity: bubbleVisible ? 1.0 : 0.0
    visible: opacity > 0.001

    Behavior on scale {
        NumberAnimation {
            duration: root.bubbleVisible ? 240 : 220
            easing.type: root.bubbleVisible ? Easing.OutBack : Easing.InBack
            easing.overshoot: root.bubbleVisible ? 1.25 : 0.0
        }
    }

    Behavior on opacity {
        NumberAnimation {
            duration: root.bubbleVisible ? 200 : 180
            easing.type: Easing.OutCubic
        }
    }

    Behavior on width {
        NumberAnimation {
            duration: 220
            easing.type: Easing.OutCubic
        }
    }

    // Animación de pulso continuo mientras persista la ventana urgente
    SequentialAnimation {
        id: urgentPulse
        running: root.isUrgent
        loops: Animation.Infinite

        NumberAnimation {
            target: root
            property: "pulseRatio"
            from: 0.0
            to: 1.0
            duration: 550
            easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root
            property: "pulseRatio"
            from: 1.0
            to: 0.0
            duration: 550
            easing.type: Easing.InOutSine
        }

        onRunningChanged: {
            if (!running) {
                root.pulseRatio = 0.0;
            }
        }
    }

    // ── Disparador y auto-reabsorción ────────────────────────────────────────
    function pop() {
        if (root.suppressed) return;
        root.bubbleVisible = true;
        if (!root.isUrgent) {
            hideTimer.restart();
        }
    }

    function hide() {
        if (root.isUrgent) return;
        hideTimer.stop();
        root.bubbleVisible = false;
    }

    function switchToWorkspace(targetId) {
        if (targetId < 1) return;
        Hyprland.dispatch("hl.dsp.focus({ workspace = " + targetId + " })");
    }

    onSuppressedChanged: {
        if (suppressed && bubbleVisible) {
            hide();
        }
    }

    Timer {
        id: hideTimer
        interval: 1400
        repeat: false
        onTriggered: {
            // Nunca ocultar automáticamente si hay una ventana urgente pendiente
            if (!bubbleHover.hovered && !root.isUrgent) {
                root.bubbleVisible = false;
            }
        }
    }

    // ── Detección y gestión de ventanas/workspaces urgentes ───────────────────
    function checkUrgency() {
        const focusedId = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1;
        let foundUrgent = null;

        // 1. Revisar ventanas activas en Hyprland
        const toplevels = Hyprland.toplevels.values;
        for (let i = 0; i < toplevels.length; i++) {
            let tl = toplevels[i];
            if (tl && tl.urgent && tl.workspace) {
                if (tl.workspace.id !== focusedId) {
                    foundUrgent = { id: tl.workspace.id, name: tl.workspace.name };
                    break;
                }
            }
        }

        // 2. Revisar workspaces directamente
        if (!foundUrgent) {
            const workspaces = Hyprland.workspaces.values;
            for (let j = 0; j < workspaces.length; j++) {
                let ws = workspaces[j];
                if (ws && ws.urgent && ws.id !== focusedId) {
                    foundUrgent = { id: ws.id, name: ws.name };
                    break;
                }
            }
        }

        if (foundUrgent) {
            root.urgentWorkspaceId = foundUrgent.id;
            root.urgentWorkspaceName = foundUrgent.name || foundUrgent.id.toString();
            root.isUrgent = true;
            root.bubbleVisible = true;
            hideTimer.stop();
        } else {
            if (root.isUrgent) {
                root.isUrgent = false;
                hideTimer.restart();
            }
        }
    }

    Component.onCompleted: {
        Hyprland.refreshWorkspaces();
        Hyprland.refreshToplevels();
        checkUrgency();
    }

    // Monitoreo reactivo de urgencia en todas las ventanas y workspaces
    Instantiator {
        model: Hyprland.toplevels
        delegate: Connections {
            target: modelData
            function onUrgentChanged() {
                root.checkUrgency();
            }
        }
    }

    Instantiator {
        model: Hyprland.workspaces
        delegate: Connections {
            target: modelData
            function onUrgentChanged() {
                root.checkUrgency();
            }
        }
    }

    // ── Detección reactiva de cambio de Workspace y Eventos en Hyprland ─────
    Connections {
        target: Hyprland

        function onRawEvent(event) {
            if (event && (event.name === "urgent" || event.name === "changefloatingmode" || event.name === "closewindow")) {
                Hyprland.refreshWorkspaces();
                Hyprland.refreshToplevels();
                root.checkUrgency();
            }
        }

        function onFocusedWorkspaceChanged() {
            const ws = Hyprland.focusedWorkspace;
            if (!ws) return;

            // En el arranque inicial, guardamos el workspace activo sin disparar la animación
            if (!root.initialized) {
                root.currentWorkspaceId = ws.id;
                root.currentWorkspaceName = ws.name || ws.id.toString();
                root.initialized = true;
                root.checkUrgency();
                return;
            }

            // Si el usuario cambia al workspace que tenía la alerta urgente:
            if (root.isUrgent && ws.id === root.urgentWorkspaceId) {
                root.isUrgent = false;
                root.currentWorkspaceId = ws.id;
                root.currentWorkspaceName = ws.name || ws.id.toString();
                // Se reabsorbe suavemente tras 1.4s
                hideTimer.restart();
                return;
            }

            // Reevaluar si queda alguna otra urgencia en otro espacio
            root.checkUrgency();
            if (root.isUrgent) return;

            // Transición habitual de workspace
            if (ws.id !== root.currentWorkspaceId) {
                root.currentWorkspaceId = ws.id;
                root.currentWorkspaceName = ws.name || ws.id.toString();
                root.pop();
            }
        }
    }

    // ── Etiqueta con el número o nombre del Workspace ────────────────────────
    Text {
        id: wsLabel
        anchors.centerIn: parent

        text: {
            let n = root.isUrgent ? root.urgentWorkspaceName : root.currentWorkspaceName;
            let id = root.isUrgent ? root.urgentWorkspaceId : root.currentWorkspaceId;
            if (n && n.startsWith("special:")) {
                return "★ " + n.substring(8);
            }
            return (n && n !== "") ? n : (id > 0 ? id.toString() : "");
        }

        // Parpadeo suave en rojo mientras esté urgente, o blanco/azul pastel en reposo
        color: root.isUrgent
            ? Qt.rgba(1.0, 0.35 + 0.35 * (1 - root.pulseRatio), 0.45 + 0.45 * (1 - root.pulseRatio), 1.0)
            : "#cdd6f4"
        font.pixelSize: 15
        font.weight: Font.DemiBold
        font.family: "Noto Sans, Inter, system-ui, sans-serif"
    }

    // ── Interacción: Clic para ir al workspace urgente, Hover y Scroll ───────
    TapHandler {
        onTapped: {
            if (root.isUrgent && root.urgentWorkspaceId > 0) {
                root.switchToWorkspace(root.urgentWorkspaceId);
            }
        }
    }

    HoverHandler {
        id: bubbleHover
        onHoveredChanged: {
            if (hovered) {
                hideTimer.stop();
            } else if (root.bubbleVisible && !root.isUrgent) {
                hideTimer.restart();
            }
        }
    }

    WheelHandler {
        id: wheelHandler
        orientation: Qt.Vertical
        onWheel: (event) => {
            if (!root.isUrgent) hideTimer.restart();
            let target = root.isUrgent ? root.urgentWorkspaceId : root.currentWorkspaceId;
            if (event.angleDelta.y > 0) {
                target = Math.max(1, target - 1);
            } else if (event.angleDelta.y < 0) {
                target = target + 1;
            }
            if (target !== root.currentWorkspaceId) {
                root.switchToWorkspace(target);
            }
        }
    }
}
