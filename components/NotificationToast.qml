import QtQuick
import QtQuick.Layouts

Item {
    id: root

    property var notification: null
    signal dismissed()

    readonly property string fontSans: "SF Pro, Noto Sans, Inter, sans-serif"
    readonly property string fontIcon: "Symbols Nerd Font, Iosevka Nerd Font"

    Rectangle {
        anchors.fill: parent
        radius: 22
        color: '#000000'
        border.width: 1
        border.color: "#353237"

        RowLayout {
            anchors.fill: parent
            anchors.margins: 13
            spacing: 11

            Rectangle {
                Layout.preferredWidth: 46
                Layout.preferredHeight: 46
                Layout.alignment: Qt.AlignVCenter
                radius: 14
                color: "#28262a"
                clip: true

                Image {
                    id: appImage
                    anchors.fill: parent
                    source: root.notification ? root.notification.image : ""
                    visible: status === Image.Ready
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: false
                }

                Text {
                    anchors.centerIn: parent
                    visible: !appImage.visible
                    text: "󰂚"
                    color: "#78d1d3"
                    font.family: root.fontIcon
                    font.pixelSize: 20
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                spacing: 2

                Text {
                    Layout.fillWidth: true
                    text: root.notification ? root.notification.appName : ""
                    color: "#aaa5aa"
                    font.family: root.fontSans
                    font.pixelSize: 10
                    elide: Text.ElideRight
                }

                Text {
                    Layout.fillWidth: true
                    text: root.notification ? root.notification.summary : ""
                    color: "#f5f2f4"
                    font.family: root.fontSans
                    font.pixelSize: 13
                    font.weight: Font.DemiBold
                    elide: Text.ElideRight
                }

                Text {
                    Layout.fillWidth: true
                    visible: text.length > 0
                    text: root.notification ? String(root.notification.body).replace(/\n/g, " ") : ""
                    color: "#aaa5aa"
                    font.family: root.fontSans
                    font.pixelSize: 10
                    elide: Text.ElideRight
                    maximumLineCount: 1
                }
            }

            Rectangle {
                Layout.preferredWidth: 26
                Layout.preferredHeight: 26
                Layout.alignment: Qt.AlignTop
                radius: 13
                color: closeMouse.containsMouse ? "#3b3033" : "transparent"

                Text {
                    anchors.centerIn: parent
                    text: "×"
                    color: closeMouse.containsMouse ? "#f2a2ad" : "#858086"
                    font.pixelSize: 17
                }

                MouseArea {
                    id: closeMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.dismissed()
                }
            }
        }
    }
}
