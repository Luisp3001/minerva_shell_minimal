import QtQuick

QtObject {
    id: root

    property real currentWidth: 1920
    property real baseWidth: 1920
    readonly property real baseScale: Math.max(0.1, currentWidth / baseWidth)
}
