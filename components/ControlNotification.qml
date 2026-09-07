import QtQuick
import QtQuick.Layouts

Rectangle {
    id: root

    property string appName: "Sistema"
    property string summary: "Notificación"
    property string body: ""
    property string image: ""
    property string time: ""

    signal removeRequested()

    implicitHeight: Math.max(58, content.implicitHeight + 20)
    radius: 15
    color: hover.hovered ? "#211f22" : '#000000'

    Behavior on color { ColorAnimation { duration: 120 } }

    RowLayout {
        id: content
        anchors.fill: parent
        anchors.margins: 10
        spacing: 10

        Rectangle {
            Layout.preferredWidth: 30
            Layout.preferredHeight: 30
            Layout.alignment: Qt.AlignTop
            radius: 9
            color: "#29272a"
            clip: true

            Image {
                id: notificationImage
                anchors.fill: parent
                source: root.image
                visible: status === Image.Ready
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
            }

            Text {
                anchors.centerIn: parent
                visible: !notificationImage.visible
                text: "󰂚"
                color: "#79d3d5"
                font.family: "Symbols Nerd Font, Iosevka Nerd Font"
                font.pixelSize: 15
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 1

            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                Text {
                    Layout.fillWidth: true
                    text: root.appName
                    color: "#969197"
                    font.family: "Noto Sans, Inter, sans-serif"
                    font.pixelSize: 10
                    elide: Text.ElideRight
                }

                Text {
                    text: root.time
                    color: "#6f6b70"
                    font.family: "Noto Sans, Inter, sans-serif"
                    font.pixelSize: 9
                }
            }

            Text {
                Layout.fillWidth: true
                text: root.summary
                color: "#f4f1f3"
                font.family: "Noto Sans, Inter, sans-serif"
                font.pixelSize: 12
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }

            Text {
                Layout.fillWidth: true
                visible: text.length > 0
                text: root.body.replace(/\n/g, " ")
                color: "#aaa5aa"
                font.family: "Noto Sans, Inter, sans-serif"
                font.pixelSize: 10
                maximumLineCount: 1
                elide: Text.ElideRight
            }
        }

        Rectangle {
            Layout.preferredWidth: 24
            Layout.preferredHeight: 24
            Layout.alignment: Qt.AlignTop
            radius: 12
            color: closeMouse.containsMouse ? "#3b3033" : "transparent"

            Text {
                anchors.centerIn: parent
                text: "×"
                color: closeMouse.containsMouse ? "#f2a2ad" : "#858086"
                font.pixelSize: 16
            }

            MouseArea {
                id: closeMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.removeRequested()
            }
        }
    }

    HoverHandler { id: hover }
}
