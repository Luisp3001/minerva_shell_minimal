import QtQuick
import Quickshell
import Quickshell.Wayland

PanelWindow {
    id: root

    property var targetScreen: Quickshell.screens[0]
    property alias contentItem: root.contentItem

    screen: targetScreen
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "freeze_screen"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    anchors {
        left: true
        right: true
        top: true
        bottom: true
    }

    ScreencopyView {
        captureSource: root.targetScreen
        anchors.fill: parent
        z: -1
    }

}
