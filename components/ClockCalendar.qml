import QtQuick
import QtQuick.Layouts

Item {
    id: root

    property var currentDate: new Date()
    property bool isExpanded: false
    property real islandWidth: 140
    property real islandHeight: 38

    property real rightMargin: 24

    signal clicked()

    // Reserva únicamente el espacio adicional que pueda necesitar la hora en
    // los extremos de la semana. Así, su centro coincide siempre con el día
    // actual sin que el texto quede recortado.
    readonly property real leftPadding: Math.max(0, clockText.implicitWidth / 2 - daysRow.todayCenter)
    readonly property real rightPadding: Math.max(0, clockText.implicitWidth / 2 - (daysRow.implicitWidth - daysRow.todayCenter))
    // El día actual se ubica siempre en el centro exacto (índice 3 de 7)
    readonly property int todayIndex: 3
    // Cálculo dinámico de 7 días centrados simétricamente en el día actual (-3 a +3)
    readonly property var weekDays: {
        let days = [];
        let d = root.currentDate;
        const dayLabels = ["S", "M", "T", "W", "T", "F", "S"];
        const fullDayLabels = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"];
        for (let i = -3; i <= 3; i++) {
            let dayDate = new Date(d.getFullYear(), d.getMonth(), d.getDate() + i);
            let dayOfWeek = dayDate.getDay();
            let isToday = (i === 0);
            let isWeekend = (dayOfWeek === 0 || dayOfWeek === 6);
            days.push({
                "name": isToday ? fullDayLabels[dayOfWeek] : dayLabels[dayOfWeek],
                "dayNumber": dayDate.getDate(),
                "isToday": isToday,
                "isWeekend": isWeekend
            });
        }
        return days;
    }

    implicitWidth: leftPadding + daysRow.implicitWidth + rightPadding
    implicitHeight: clockText.implicitHeight + 5 + daysRow.implicitHeight

    // Fondo sutil al posar el cursor sobre el módulo en modo expandido
    Rectangle {
        id: hoverBg
        anchors.fill: parent
        anchors.topMargin: -4
        anchors.bottomMargin: -4
        anchors.leftMargin: -6
        anchors.rightMargin: -6
        radius: 12
        color: (clickArea.containsMouse && root.isExpanded) ? Qt.rgba(1, 1, 1, 0.06) : "transparent"
        border.color: (clickArea.containsMouse && root.isExpanded) ? Qt.rgba(0.47, 0.82, 0.83, 0.25) : "transparent"
        border.width: 1
        opacity: root.isExpanded ? 1 : 0
        z: -1

        Behavior on color { ColorAnimation { duration: 150 } }
        Behavior on border.color { ColorAnimation { duration: 150 } }
        Behavior on opacity { NumberAnimation { duration: 150 } }
    }

    MouseArea {
        id: clickArea
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        hoverEnabled: true
        onClicked: root.clicked()
    }

    // Hora centrada sobre la celda correspondiente al día actual en modo expandido,
    // o morphing hacia el centro de la isla en modo compacto.
    Text {
        id: clockText

        readonly property real expandedX: root.leftPadding + daysRow.todayCenter - implicitWidth / 2
        readonly property real compactX: root.width + root.rightMargin - root.islandWidth / 2 - implicitWidth / 2
        readonly property real expandedY: 0
        readonly property real compactY: (root.height - implicitHeight) / 2

        x: root.isExpanded ? expandedX : compactX
        y: root.isExpanded ? expandedY : compactY

        text: Qt.formatDateTime(root.currentDate, "hh:mm")
        color: (clickArea.containsMouse && root.isExpanded) ? "#78d1d3" : "#FFFFFF"
        font.pixelSize: root.isExpanded ? 18 : 16
        font.weight: Font.DemiBold
        font.family: "SF Pro Display, SF Pro, sans-serif"
        font.letterSpacing: root.isExpanded ? 0.5 : 0.0

        Behavior on x {
            enabled: root.isExpanded
            NumberAnimation {
                duration: 380
                easing.type: Easing.OutBack
                easing.overshoot: 1.15
            }
        }

        Behavior on y {
            enabled: root.isExpanded
            NumberAnimation {
                duration: 380
                easing.type: Easing.OutBack
                easing.overshoot: 1.15
            }
        }

        Behavior on font.pixelSize {
            NumberAnimation {
                duration: root.isExpanded ? 380 : 250
                easing.type: root.isExpanded ? Easing.OutBack : Easing.OutCubic
            }
        }

        Behavior on color {
            ColorAnimation { duration: 200 }
        }
    }

    // Tira de los 7 días de la semana con efecto de degradado simétrico
    Row {
        id: daysRow

        readonly property real todayCenter: {
            // Mantiene el binding reactivo mientras el Repeater crea/cambia
            // sus delegates.
            if (daysRepeater.count === 0)
                return implicitWidth / 2;

            const item = daysRepeater.itemAt(root.todayIndex);
            return item ? item.x + item.width / 2 : implicitWidth / 2;
        }

        x: root.leftPadding
        y: clockText.implicitHeight + 5
        spacing: 3

        opacity: root.isExpanded ? 1 : 0
        visible: opacity > 0

        Behavior on opacity {
            NumberAnimation { duration: 150 }
        }

        Repeater {
            id: daysRepeater

            model: root.weekDays

            delegate: Rectangle {
                id: dayCell

                required property var modelData
                required property int index
                // Distancia al día actual para crear el degradado progresivo simétrico
                readonly property real distance: Math.abs(index - root.todayIndex)

                width: modelData.isToday ? 30 : 18
                height: 36
                radius: 7
                // Destacar el día actual
                color: "transparent"
                border.color: "transparent"
                border.width: 1
                // Efecto de degradado / desvanecimiento simétrico según la distancia al día seleccionado
                opacity: modelData.isToday ? 1 : Math.max(0.12, 0.72 - (distance * 0.18))

                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: 1

                    // Nombre del día
                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: modelData.name
                        color:"#8c92ac"
                        font.pixelSize: modelData.isToday ? 9 : 10
                        font.weight: modelData.isToday ? Font.Bold : Font.Normal
                        font.family: "SF Pro, Noto Sans, Inter, system-ui, sans-serif"
                    }

                    // Número del día
                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: modelData.dayNumber
                        color: modelData.isWeekend ? "#f38ba8" : '#8c92ac'
                        font.pixelSize: modelData.isToday ? 14 : 12
                        font.weight: modelData.isToday ? Font.Bold : Font.Normal
                        font.family: "SF Pro, Noto Sans, Inter, system-ui, sans-serif"
                    }

                }

            }

        }

    }

}

