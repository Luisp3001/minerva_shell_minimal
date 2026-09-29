import QtQuick
import QtQuick.Layouts
import QtQuick.Effects

// ── Minerva Shell - Calendar View ───────────────────────────────────────────
// Vista de calendario interactiva mensual y anual integrada en la Dynamic Island.
// Permite navegar con fluidez entre meses y años, seleccionar días,
// atajos de teclado y volver rápidamente a la fecha actual ("Hoy").
// ─────────────────────────────────────────────────────────────────────────────
Item {
    id: root

    // ── Señales y control público ─────────────────────────────────────────────
    signal closeRequested()

    property bool active: false
    property var currentDate: new Date()

    // Estado de visualización y selección
    property int viewYear: currentDate.getFullYear()
    property int viewMonth: currentDate.getMonth() // 0 - 11
    property int selectedDay: currentDate.getDate()
    property int selectedMonth: currentDate.getMonth()
    property int selectedYear: currentDate.getFullYear()

    // ── Colores y Tipografía (Catppuccin Mocha / Minerva Theme) ────────────────
    readonly property color clrAccent: "#78d1d3"
    readonly property color clrAccentFg: "#102526"
    readonly property color clrText: "#f5f2f4"
    readonly property color clrSubtext: "#9b969c"
    readonly property color clrMuted: "#585b70"
    readonly property color clrWeekend: "#f38ba8"
    readonly property color clrBorder: "#313244"
    readonly property color clrCardBg: "#111114"
    readonly property color clrHover: Qt.rgba(1, 1, 1, 0.08)

    readonly property string fontSans: "SF Pro, Noto Sans, Inter, system-ui, sans-serif"
    readonly property string fontIcon: "Symbols Nerd Font, Iosevka Nerd Font"
    readonly property string fontMono: "JetBrains Mono, monospace"

    readonly property var monthNames: [
        "Enero", "Febrero", "Marzo", "Abril", "Mayo", "Junio",
        "Julio", "Agosto", "Septiembre", "Octubre", "Noviembre", "Diciembre"
    ]

    readonly property var weekDayNames: ["Lun", "Mar", "Mié", "Jue", "Vie", "Sáb", "Dom"]

    // Detección de si la vista actual corresponde al mes/año actual
    readonly property bool isCurrentViewingMonth: {
        let now = root.currentDate || new Date();
        return viewYear === now.getFullYear() && viewMonth === now.getMonth();
    }

    // Texto descriptivo del día seleccionado
    readonly property string selectedDateString: {
        let d = new Date(selectedYear, selectedMonth, selectedDay);
        let dayOfWeek = d.getDay();
        const days = ["Domingo", "Lunes", "Martes", "Miércoles", "Jueves", "Viernes", "Sábado"];
        let monthName = monthNames[selectedMonth] || "";
        return days[dayOfWeek] + ", " + selectedDay + " de " + monthName.toLowerCase() + " de " + selectedYear;
    }

    // Nombre del mes actual en vista
    function getMonthName(m) {
        if (m >= 0 && m < 12) return monthNames[m];
        return "";
    }

    // ── Navegación ────────────────────────────────────────────────────────────
    function prevMonth() {
        if (viewMonth === 0) {
            viewMonth = 11;
            viewYear--;
        } else {
            viewMonth--;
        }
    }

    function nextMonth() {
        if (viewMonth === 11) {
            viewMonth = 0;
            viewYear++;
        } else {
            viewMonth++;
        }
    }

    function prevYear() {
        viewYear--;
    }

    function nextYear() {
        viewYear++;
    }

    function goToToday() {
        let now = root.currentDate || new Date();
        viewYear = now.getFullYear();
        viewMonth = now.getMonth();
        selectedDay = now.getDate();
        selectedMonth = now.getMonth();
        selectedYear = now.getFullYear();
    }

    function open() {
        goToToday();
        root.forceActiveFocus();
    }

    onActiveChanged: {
        if (active) {
            open();
        }
    }

    // ── Generación de días de la cuadrícula (6 semanas x 7 días = 42 celdas) ───
    property string currentDayKey: {
        let d = root.currentDate || new Date();
        return d.getFullYear() + "-" + d.getMonth() + "-" + d.getDate();
    }

    readonly property var gridDays: {
        // Marcador de reactividad con el cambio de día del sistema
        let _key = currentDayKey;
        let year = viewYear;
        let month = viewMonth;
        let days = [];

        let firstDayOfMonth = new Date(year, month, 1);
        // getDay(): 0 es domingo, 1 es lunes...
        // Índice iniciando en lunes: Lun=0, Mar=1, Mié=2, Jue=3, Vie=4, Sáb=5, Dom=6
        let firstDayOfWeek = (firstDayOfMonth.getDay() + 6) % 7;

        let daysInCurrentMonth = new Date(year, month + 1, 0).getDate();
        let daysInPrevMonth = new Date(year, month, 0).getDate();

        let now = root.currentDate || new Date();
        let todayDate = now.getDate();
        let todayMonth = now.getMonth();
        let todayYear = now.getFullYear();

        for (let i = 0; i < 42; i++) {
            let dayNum, cellMonth, cellYear, isCurrentMonth;

            if (i < firstDayOfWeek) {
                // Días del mes anterior
                dayNum = daysInPrevMonth - firstDayOfWeek + 1 + i;
                cellMonth = (month === 0) ? 11 : month - 1;
                cellYear = (month === 0) ? year - 1 : year;
                isCurrentMonth = false;
            } else if (i < firstDayOfWeek + daysInCurrentMonth) {
                // Días del mes actual
                dayNum = i - firstDayOfWeek + 1;
                cellMonth = month;
                cellYear = year;
                isCurrentMonth = true;
            } else {
                // Días del mes siguiente
                dayNum = i - firstDayOfWeek - daysInCurrentMonth + 1;
                cellMonth = (month === 11) ? 0 : month + 1;
                cellYear = (month === 11) ? year + 1 : year;
                isCurrentMonth = false;
            }

            let dayOfWeek = (i % 7); // 0=Lun ... 5=Sáb, 6=Dom
            let isWeekend = (dayOfWeek === 5 || dayOfWeek === 6);
            let isToday = (dayNum === todayDate && cellMonth === todayMonth && cellYear === todayYear);
            let isSelected = (dayNum === root.selectedDay && cellMonth === root.selectedMonth && cellYear === root.selectedYear);

            days.push({
                "dayNumber": dayNum,
                "month": cellMonth,
                "year": cellYear,
                "isCurrentMonth": isCurrentMonth,
                "isWeekend": isWeekend,
                "isToday": isToday,
                "isSelected": isSelected
            });
        }
        return days;
    }

    // ── Atajos de Teclado y Rueda del Ratón ───────────────────────────────────
    focus: true

    Keys.onEscapePressed: (event) => {
        root.closeRequested();
        event.accepted = true;
    }

    Keys.onLeftPressed: (event) => {
        root.prevMonth();
        event.accepted = true;
    }

    Keys.onRightPressed: (event) => {
        root.nextMonth();
        event.accepted = true;
    }

    Keys.onUpPressed: (event) => {
        root.prevYear();
        event.accepted = true;
    }

    Keys.onDownPressed: (event) => {
        root.nextYear();
        event.accepted = true;
    }

    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_Home || event.key === Qt.Key_T) {
            root.goToToday();
            event.accepted = true;
        } else if (event.key === Qt.Key_PageUp) {
            root.prevYear();
            event.accepted = true;
        } else if (event.key === Qt.Key_PageDown) {
            root.nextYear();
            event.accepted = true;
        }
    }

    Shortcut {
        sequence: "Escape"
        enabled: root.active
        onActivated: root.closeRequested()
    }

    WheelHandler {
        target: root
        onWheel: (event) => {
            if (event.angleDelta.y > 0) root.prevMonth();
            else if (event.angleDelta.y < 0) root.nextMonth();
        }
    }

    // ── Estructura Visual Principal ──────────────────────────────────────────
    ColumnLayout {
        anchors.fill: parent
        anchors.topMargin: 12
        anchors.bottomMargin: 12
        anchors.leftMargin: 16
        anchors.rightMargin: 16
        spacing: 8

        // 1. Barra superior: Título, hora en tiempo real y botón de cerrar
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 30
            spacing: 8

            // Icono de calendario + Título
            Row {
                Layout.alignment: Qt.AlignVCenter
                spacing: 7

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "󰸗"
                    color: root.clrAccent
                    font.family: root.fontIcon
                    font.pixelSize: 15
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Calendario"
                    color: root.clrText
                    font.family: root.fontSans
                    font.pixelSize: 13
                    font.weight: Font.DemiBold
                }

                // Separador sutil
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 3
                    height: 3
                    radius: 1.5
                    color: root.clrMuted
                    opacity: 0.6
                }

                // Reloj en tiempo real
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: Qt.formatDateTime(root.currentDate, "hh:mm:ss")
                    color: root.clrSubtext
                    font.family: root.fontMono
                    font.pixelSize: 11
                }
            }

            Item { Layout.fillWidth: true }

            // Botón "Hoy"
            Rectangle {
                id: todayBtn
                Layout.preferredHeight: 24
                Layout.preferredWidth: todayBtnContent.implicitWidth + 14
                radius: 12
                color: todayMouse.containsMouse ? Qt.rgba(0.47, 0.82, 0.83, 0.2) : (root.isCurrentViewingMonth ? Qt.rgba(1, 1, 1, 0.06) : Qt.rgba(0.47, 0.82, 0.83, 0.12))
                border.color: root.isCurrentViewingMonth ? Qt.rgba(1, 1, 1, 0.1) : root.clrAccent
                border.width: 1

                Behavior on color { ColorAnimation { duration: 120 } }
                Behavior on border.color { ColorAnimation { duration: 120 } }

                Row {
                    id: todayBtnContent
                    anchors.centerIn: parent
                    spacing: 4

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "󰃭"
                        color: root.isCurrentViewingMonth ? root.clrSubtext : root.clrAccent
                        font.family: root.fontIcon
                        font.pixelSize: 11
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Hoy"
                        color: root.isCurrentViewingMonth ? root.clrText : root.clrAccent
                        font.family: root.fontSans
                        font.pixelSize: 11
                        font.weight: Font.Medium
                    }
                }

                MouseArea {
                    id: todayMouse
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    hoverEnabled: true
                    onClicked: root.goToToday()
                }
            }

            // Botón Cerrar (✕)
            Rectangle {
                id: closeBtn
                Layout.preferredWidth: 26
                Layout.preferredHeight: 26
                radius: 13
                color: closeMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.14) : Qt.rgba(1, 1, 1, 0.05)
                border.color: closeMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.25) : "transparent"
                border.width: 1

                Behavior on color { ColorAnimation { duration: 100 } }

                Text {
                    anchors.centerIn: parent
                    text: "✕"
                    color: closeMouse.containsMouse ? "#FFFFFF" : root.clrSubtext
                    font.family: root.fontSans
                    font.pixelSize: 11
                    font.weight: Font.Medium
                }

                MouseArea {
                    id: closeMouse
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    hoverEnabled: true
                    onClicked: root.closeRequested()
                }
            }
        }

        // Línea divisoria sutil
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: root.clrBorder
            opacity: 0.7
        }

        // 2. Barra de Navegación de Mes y Año ( « ‹ [Mes Año] › » )
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 34
            spacing: 4

            // Año anterior ( « )
            Rectangle {
                Layout.preferredWidth: 28
                Layout.preferredHeight: 28
                radius: 8
                color: prevYearMouse.containsMouse ? root.clrHover : "transparent"
                border.color: prevYearMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.15) : "transparent"
                border.width: 1

                Text {
                    anchors.centerIn: parent
                    text: "«"
                    color: prevYearMouse.containsMouse ? root.clrAccent : root.clrSubtext
                    font.family: root.fontSans
                    font.pixelSize: 15
                    font.weight: Font.DemiBold
                }

                MouseArea {
                    id: prevYearMouse
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    hoverEnabled: true
                    onClicked: root.prevYear()
                }
            }

            // Mes anterior ( ‹ )
            Rectangle {
                Layout.preferredWidth: 28
                Layout.preferredHeight: 28
                radius: 8
                color: prevMonthMouse.containsMouse ? root.clrHover : "transparent"
                border.color: prevMonthMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.15) : "transparent"
                border.width: 1

                Text {
                    anchors.centerIn: parent
                    text: "‹"
                    color: prevMonthMouse.containsMouse ? root.clrAccent : root.clrSubtext
                    font.family: root.fontSans
                    font.pixelSize: 18
                    font.weight: Font.DemiBold
                }

                MouseArea {
                    id: prevMonthMouse
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    hoverEnabled: true
                    onClicked: root.prevMonth()
                }
            }

            // Título central: Nombre del Mes y Año (Clickable para volver a hoy)
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 28
                radius: 8
                color: monthTitleMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.05) : "transparent"

                Row {
                    anchors.centerIn: parent
                    spacing: 7

                    Text {
                        text: root.getMonthName(root.viewMonth)
                        color: root.clrText
                        font.family: root.fontSans
                        font.pixelSize: 15
                        font.weight: Font.DemiBold
                    }

                    Text {
                        text: root.viewYear
                        color: root.clrAccent
                        font.family: root.fontSans
                        font.pixelSize: 15
                        font.weight: Font.DemiBold
                    }
                }

                MouseArea {
                    id: monthTitleMouse
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    hoverEnabled: true
                    onClicked: root.goToToday()
                }
            }

            // Mes siguiente ( › )
            Rectangle {
                Layout.preferredWidth: 28
                Layout.preferredHeight: 28
                radius: 8
                color: nextMonthMouse.containsMouse ? root.clrHover : "transparent"
                border.color: nextMonthMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.15) : "transparent"
                border.width: 1

                Text {
                    anchors.centerIn: parent
                    text: "›"
                    color: nextMonthMouse.containsMouse ? root.clrAccent : root.clrSubtext
                    font.family: root.fontSans
                    font.pixelSize: 18
                    font.weight: Font.DemiBold
                }

                MouseArea {
                    id: nextMonthMouse
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    hoverEnabled: true
                    onClicked: root.nextMonth()
                }
            }

            // Año siguiente ( » )
            Rectangle {
                Layout.preferredWidth: 28
                Layout.preferredHeight: 28
                radius: 8
                color: nextYearMouse.containsMouse ? root.clrHover : "transparent"
                border.color: nextYearMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.15) : "transparent"
                border.width: 1

                Text {
                    anchors.centerIn: parent
                    text: "»"
                    color: nextYearMouse.containsMouse ? root.clrAccent : root.clrSubtext
                    font.family: root.fontSans
                    font.pixelSize: 15
                    font.weight: Font.DemiBold
                }

                MouseArea {
                    id: nextYearMouse
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    hoverEnabled: true
                    onClicked: root.nextYear()
                }
            }
        }

        // 3. Cabecera de Días de la Semana (Lun, Mar, Mié, Jue, Vie, Sáb, Dom)
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 20
            spacing: 2

            Repeater {
                model: root.weekDayNames

                Item {
                    required property string modelData
                    required property int index
                    Layout.fillWidth: true
                    Layout.preferredHeight: 20

                    Text {
                        anchors.centerIn: parent
                        text: modelData
                        color: (index === 5 || index === 6) ? root.clrWeekend : root.clrMuted
                        font.family: root.fontSans
                        font.pixelSize: 11
                        font.weight: Font.DemiBold
                        opacity: 0.9
                    }
                }
            }
        }

        // 4. Cuadrícula de Días (6 semanas x 7 días = 42 celdas)
        GridLayout {
            id: daysGrid
            Layout.fillWidth: true
            Layout.fillHeight: true
            columns: 7
            rowSpacing: 3
            columnSpacing: 2

            Repeater {
                model: root.gridDays

                Item {
                    id: dayDelegate
                    required property var modelData
                    required property int index

                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    Rectangle {
                        id: dayBadge
                        anchors.centerIn: parent
                        width: Math.min(parent.width - 2, 32)
                        height: Math.min(parent.height - 2, 30)
                        radius: 8

                        // Colores de fondo según estado (Hoy / Seleccionado / Hover / Inactivo)
                        color: {
                            if (modelData.isToday) return root.clrAccent;
                            if (modelData.isSelected) return Qt.rgba(0.47, 0.82, 0.83, 0.22);
                            if (cellMouse.containsMouse) return root.clrHover;
                            return "transparent";
                        }

                        border.color: {
                            if (modelData.isToday) return root.clrAccent;
                            if (modelData.isSelected) return root.clrAccent;
                            if (cellMouse.containsMouse) return Qt.rgba(1, 1, 1, 0.15);
                            return "transparent";
                        }
                        border.width: (modelData.isSelected || modelData.isToday) ? 1 : (cellMouse.containsMouse ? 1 : 0)

                        Behavior on color { ColorAnimation { duration: 100 } }
                        Behavior on border.color { ColorAnimation { duration: 100 } }

                        Text {
                            anchors.centerIn: parent
                            text: modelData.dayNumber
                            font.family: root.fontSans
                            font.pixelSize: modelData.isToday ? 13 : 12
                            font.weight: (modelData.isToday || modelData.isSelected) ? Font.Bold : Font.Normal

                            color: {
                                if (modelData.isToday) return root.clrAccentFg;
                                if (modelData.isSelected) return root.clrAccent;
                                if (!modelData.isCurrentMonth) return root.clrMuted;
                                if (modelData.isWeekend) return root.clrWeekend;
                                return root.clrText;
                            }
                            opacity: modelData.isCurrentMonth ? 1.0 : 0.38
                        }

                        // Punto indicador bajo el día seleccionado si no es hoy
                        Rectangle {
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: 2
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: 3
                            height: 3
                            radius: 1.5
                            color: root.clrAccent
                            visible: modelData.isSelected && !modelData.isToday
                        }
                    }

                    MouseArea {
                        id: cellMouse
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        hoverEnabled: true
                        onClicked: {
                            if (!modelData.isCurrentMonth) {
                                root.viewMonth = modelData.month;
                                root.viewYear = modelData.year;
                            }
                            root.selectedDay = modelData.dayNumber;
                            root.selectedMonth = modelData.month;
                            root.selectedYear = modelData.year;
                        }
                    }
                }
            }
        }

        // 5. Barra Inferior / Pie con la fecha seleccionada y atajo
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 26
            radius: 8
            color: Qt.rgba(0.08, 0.08, 0.1, 0.6)
            border.color: Qt.rgba(1, 1, 1, 0.06)
            border.width: 1

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                spacing: 6

                Text {
                    Layout.alignment: Qt.AlignVCenter
                    text: root.selectedDateString
                    color: root.clrText
                    font.family: root.fontSans
                    font.pixelSize: 11
                    font.weight: Font.Medium
                    elide: Text.ElideRight
                }

                Item { Layout.fillWidth: true }

                Text {
                    Layout.alignment: Qt.AlignVCenter
                    text: "Esc para cerrar"
                    color: root.clrMuted
                    font.family: root.fontSans
                    font.pixelSize: 10
                }
            }
        }
    }
}
