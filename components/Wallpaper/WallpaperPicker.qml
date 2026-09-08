import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io

Item {
    id: root

    signal closeRequested()
    signal wallpaperSelected(string path)

    property bool active: false
    property var shellRoot: null

    property var tagsDb: ({})
    property string searchQuery: ""
    property bool isTagging: false
    property var filteredIndices: []
    property bool searchFocused: false
    property bool initialFocusSet: false
    property string targetWallName: ""

    // ── Colores y Tipografía (Catppuccin Mocha / Minerva Theme) ────────────────
    readonly property color clrAccent: "#78d1d3"
    readonly property color clrText: "#f5f2f4"
    readonly property color clrMuted: "#9b969c"
    readonly property color clrBgPill: Qt.rgba(0.08, 0.08, 0.1, 0.7)
    readonly property color clrCardBg: "#111114"
    readonly property color clrBorder: "#313244"
    readonly property string fontSans: "SF Pro, Noto Sans, Inter, sans-serif"
    readonly property string fontMono: "JetBrains Mono, monospace"
    readonly property string fontIcon: "Symbols Nerd Font, Iosevka Nerd Font"

    // ── Rutas y Dimensiones de Elementos del Carrusel ─────────────────────────
    readonly property string homeDir: "file://" + Quickshell.env("HOME")
    readonly property string thumbDir: homeDir + "/.cache/wallpaper"
    readonly property string srcDir: Quickshell.env("HOME") + "/wallpaper"
    readonly property string awwwCommand: "awww img '%1' --transition-type %2 --transition-pos top --transition-fps 60 --transition-duration 2"
    readonly property var transitions: ["grow", "outer", "wipe", "wave", "fade", "center"]

    readonly property int itemWidthExpanded: 410
    readonly property int itemWidthCollapsed: 65
    readonly property int itemHeight: 236

    // ── Procesos del Sistema ──────────────────────────────────────────────────
    // 1. Verificación del estado de etiquetado AI (tagger.lock)
    property var taggingStatusProcess: Process {
        command: ["bash", "-c", "while true; do if [ -f ~/.cache/wallpaper/tagger.lock ]; then echo '1'; else echo '0'; fi; sleep 2; done"]
        running: root.active
        stdout: SplitParser {
            splitMarker: ""
            onRead: (data) => {
                let text = data.trim();
                root.isTagging = (text === "1");
            }
        }
    }

    // 2. Carga del archivo de etiquetas generado por wallpaper_tagger.py
    property var loadTagsProcess: Process {
        command: ["cat", Quickshell.env("HOME") + "/.cache/wallpaper/tags.json"]
        running: false
        stdout: SplitParser {
            splitMarker: ""
            onRead: (data) => {
                let text = data.trim();
                if (text.length > 0) {
                    try {
                        root.tagsDb = JSON.parse(text);
                        root.rebuildFilter();
                    } catch (e) {
                        console.log("Failed to parse tags.json:", e);
                    }
                }
            }
        }
    }

    // 3. Obtener el fondo de pantalla actual desde awww query
    property var currentWallProcess: Process {
        command: ["bash", "-c", "awww query | sed -n 's/.*image://p' | head -n 1 || true"]
        running: false
        stdout: SplitParser {
            onRead: (data) => {
                let text = data.trim();
                let parts = text.split('/');
                let name = parts[parts.length - 1];
                if (name) {
                    root.targetWallName = name;
                    root.tryFocus();
                }
            }
        }
    }

    function open() {
        root.active = true;
    }

    function close() {
        root.active = false;
    }

    onActiveChanged: {
        if (active) {
            root.searchQuery = "";
            searchField.text = "";
            root.searchFocused = false;
            root.initialFocusSet = false;
            loadTagsProcess.running = true;
            currentWallProcess.running = true;
            root.rebuildFilter();
            Qt.callLater(function() {
                view.forceActiveFocus();
                root.tryFocus();
            });
        }
    }

    function getTagsForFile(fileName) {
        if (root.tagsDb && root.tagsDb[fileName]) return root.tagsDb[fileName];
        return [];
    }

    function matchesSearch(fileName) {
        let q = root.searchQuery.trim().toLowerCase();
        if (q === "") return true;
        let terms = q.split(/\s+/);
        let tags = getTagsForFile(fileName);
        let tagStr = tags.join(" ").toLowerCase();
        let nameStr = fileName.toLowerCase();
        for (let t of terms) {
            if (tagStr.indexOf(t) === -1 && nameStr.indexOf(t) === -1)
                return false;
        }
        return true;
    }

    function rebuildFilter() {
        let indices = [];
        for (let i = 0; i < folderModel.count; i++) {
            let fname = folderModel.get(i, "fileName");
            if (matchesSearch(fname)) indices.push(i);
        }
        filteredIndices = indices;
    }

    function tryFocus() {
        if (!initialFocusSet && targetWallName !== "" && view.count > 0) {
            let foundIndex = -1;
            for (let i = 0; i < view.count; i++) {
                let fname = (root.searchQuery !== "" ? filteredModel.get(i).fileName : folderModel.get(i, "fileName"));
                if (fname === targetWallName) {
                    foundIndex = i;
                    break;
                }
            }
            if (foundIndex !== -1) {
                view.currentIndex = foundIndex;
                view.positionViewAtIndex(foundIndex, ListView.Center);
                initialFocusSet = true;
            }
        }
    }

    onSearchQueryChanged: {
        rebuildFilter();
        if (view.count > 0) view.currentIndex = 0;
    }

    function pickWallpaper(fileName) {
        if (!fileName) return;
        const originalFile = root.srcDir + "/" + fileName;
        // Terminar cualquier motor previo
        Quickshell.execDetached(["bash", "-c", "killall linux-wallpaperengine || true"]);
        const randomTransition = root.transitions[Math.floor(Math.random() * root.transitions.length)];
        const finalCmd = root.awwwCommand.arg(originalFile).arg(randomTransition);
        Quickshell.execDetached(["bash", "-c", finalCmd]);
        const postCmd = "sleep 2 && /home/luisp/.config/hypr/scripts_hypr/update_color.sh '" + originalFile + "'";
        Quickshell.execDetached(["bash", "-c", postCmd]);

        root.wallpaperSelected(originalFile);
        root.closeRequested();
    }

    // ── Atajos de Teclado ─────────────────────────────────────────────────────
    Shortcut {
        sequence: "Left"
        enabled: root.active && !root.searchFocused
        onActivated: view.decrementCurrentIndex()
    }
    Shortcut {
        sequence: "Right"
        enabled: root.active && !root.searchFocused
        onActivated: view.incrementCurrentIndex()
    }
    Shortcut {
        sequence: "Return"
        enabled: root.active && (!root.searchFocused || searchField.text === "")
        onActivated: {
            if (view.currentItem) view.currentItem.pickWallpaper();
        }
    }
    Shortcut {
        sequence: "Ctrl+F"
        enabled: root.active
        onActivated: {
            searchField.forceActiveFocus();
            searchField.selectAll();
        }
    }
    Shortcut {
        sequence: "Escape"
        enabled: root.active
        onActivated: {
            if (root.searchFocused) {
                view.forceActiveFocus();
            } else if (root.searchQuery !== "") {
                searchField.text = "";
                root.searchQuery = "";
            } else {
                root.closeRequested();
            }
        }
    }

    // ── Contenedor Principal ──────────────────────────────────────────────────
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 15
        spacing: 8

        // Barra Superior: Buscador, Estado de IA, Contador y Botón Cerrar
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 32
            Layout.minimumHeight: 32
            Layout.maximumHeight: 32
            Layout.fillHeight: false
            spacing: 8


            Text { 
                id: wallpaperLabel
                Layout.alignment: Qt.AlignLeft
                text: "Wallpapers"
                color: root.clrText
                font.family: root.fontSans
                font.pixelSize: 15
                font.weight: Font.DemiBold
            }

            // Espaciador izquierdo para centrar el campo de búsqueda
            Item {
                Layout.fillWidth: true
            }

            // Campo de búsqueda integrado
            Rectangle {
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: 260
                Layout.preferredHeight: 32
                Layout.minimumHeight: 32
                Layout.maximumHeight: 32
                Layout.fillHeight: false
                radius: 16
                color: root.searchFocused ? Qt.rgba(0.47, 0.82, 0.83, 0.12) : Qt.rgba(0.1, 0.1, 0.13, 0.7)
                border.color: root.searchFocused ? root.clrAccent : Qt.rgba(1, 1, 1, 0.1)
                border.width: 1

                Behavior on color { ColorAnimation { duration: 180 } }
                Behavior on border.color { ColorAnimation { duration: 180 } }

                Item {
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10

                    Text {
                        id: searchIcon
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: "󰍉"
                        color: root.searchFocused ? root.clrAccent : root.clrMuted
                        font.family: root.fontIcon
                        font.pixelSize: 14
                    }

                    TextInput {
                        id: searchField
                        anchors.left: searchIcon.right
                        anchors.leftMargin: 8
                        anchors.right: clearBtn.visible ? clearBtn.left : parent.right
                        anchors.rightMargin: 6
                        anchors.verticalCenter: parent.verticalCenter
                        color: root.clrText
                        font.pixelSize: 12
                        font.family: root.fontSans
                        clip: true
                        selectByMouse: true
                        selectedTextColor: "#050508"
                        selectionColor: root.clrAccent

                        onTextChanged: root.searchQuery = text
                        onActiveFocusChanged: root.searchFocused = activeFocus

                        Keys.onEscapePressed: view.forceActiveFocus()
                        Keys.onDownPressed: view.forceActiveFocus()
                        Keys.onReturnPressed: view.forceActiveFocus()

                        Text {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Buscar por tag o nombre... (Ctrl+F)"
                            color: root.clrMuted
                            font: parent.font
                            visible: !parent.text && !parent.activeFocus
                        }
                    }

                    Rectangle {
                        id: clearBtn
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: 18
                        height: 18
                        radius: 9
                        color: clearMa.containsMouse ? Qt.rgba(1, 1, 1, 0.2) : "transparent"
                        visible: searchField.text.length > 0

                        Text {
                            anchors.centerIn: parent
                            text: "✕"
                            color: root.clrMuted
                            font.pixelSize: 9
                        }

                        MouseArea {
                            id: clearMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                searchField.text = "";
                                root.searchQuery = "";
                                view.forceActiveFocus();
                            }
                        }
                    }
                }
            }

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 32
                Layout.fillHeight: false
            }

            // Contador de fondos
            Rectangle {
                Layout.preferredHeight: 24
                Layout.maximumHeight: 24
                Layout.preferredWidth: countText.implicitWidth + 14
                Layout.fillHeight: false
                Layout.alignment: Qt.AlignVCenter
                radius: 12
                color: Qt.rgba(1, 1, 1, 0.07)
                border.color: Qt.rgba(1, 1, 1, 0.08)
                border.width: 1

                Text {
                    id: countText
                    anchors.centerIn: parent
                    text: (view.count > 0 ? (view.currentIndex + 1) : 0) + " / " + view.count
                    color: root.clrMuted
                    font.family: root.fontMono
                    font.pixelSize: 10
                }
            }

            // Botón para cerrar
            Rectangle {
                Layout.preferredWidth: 28
                Layout.preferredHeight: 28
                Layout.maximumHeight: 28
                Layout.fillHeight: false
                Layout.alignment: Qt.AlignVCenter
                radius: 14
                color: closeMa.containsMouse ? Qt.rgba(1, 1, 1, 0.15) : Qt.rgba(1, 1, 1, 0.06)
                border.color: Qt.rgba(1, 1, 1, 0.08)
                border.width: 1

                Behavior on color { ColorAnimation { duration: 150 } }

                Text {
                    anchors.centerIn: parent
                    text: "✕"
                    color: closeMa.containsMouse ? root.clrText : root.clrMuted
                    font.family: root.fontSans
                    font.pixelSize: 11
                }

                MouseArea {
                    id: closeMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.closeRequested()
                }
            }
        }

        // Indicador de etiquetado AI en tiempo real (movido debajo del cuadro de búsqueda)
        RowLayout {
            visible: root.isTagging
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredHeight: 20
            Layout.fillHeight: false
            spacing: 6

            Rectangle {
                width: 7; height: 7; radius: 3.5; color: root.clrAccent
                SequentialAnimation on opacity {
                    loops: Animation.Infinite
                    running: root.isTagging
                    NumberAnimation { to: 0.25; duration: 750 }
                    NumberAnimation { to: 1.0; duration: 750 }
                }
            }
            Text {
                text: "Generando tags por IA..."
                color: root.clrAccent
                font.family: root.fontSans
                font.pixelSize: 11
                font.weight: Font.DemiBold
            }
        }

        // Vista de Carrusel de Fondos
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            implicitHeight: 250

            ListView {
                id: view
                anchors.fill: parent
                spacing: 12
                orientation: ListView.Horizontal
                clip: true
                highlightRangeMode: ListView.StrictlyEnforceRange
                preferredHighlightBegin: (width / 2) - (root.itemWidthExpanded / 2)
                preferredHighlightEnd: (width / 2) + (root.itemWidthExpanded / 2)
                highlightMoveDuration: 280
                highlightMoveVelocity: -1
                boundsBehavior: Flickable.StopAtBounds
                cacheBuffer: 600

                model: root.searchQuery !== "" ? filteredModel : folderModel

                WheelHandler {
                    target: view
                    orientation: Qt.Vertical | Qt.Horizontal
                    onWheel: (event) => {
                        if (event.angleDelta.y < 0 || event.angleDelta.x > 0) {
                            view.incrementCurrentIndex();
                        } else if (event.angleDelta.y > 0 || event.angleDelta.x < 0) {
                            view.decrementCurrentIndex();
                        }
                    }
                }

                FolderListModel {
                    id: folderModel
                    folder: root.thumbDir
                    nameFilters: ["*.jpg", "*.jpeg", "*.png", "*.webp", "*.gif"]
                    showDirs: false
                    sortField: FolderListModel.Name
                    onStatusChanged: {
                        root.rebuildFilter();
                        root.tryFocus();
                    }
                    onCountChanged: {
                        root.rebuildFilter();
                        root.tryFocus();
                    }
                }

                ListModel { id: filteredModel }

                Connections {
                    target: root
                    function onFilteredIndicesChanged() {
                        filteredModel.clear();
                        for (let idx of root.filteredIndices) {
                            filteredModel.append({
                                fileName: folderModel.get(idx, "fileName"),
                                fileUrl: folderModel.get(idx, "fileUrl")
                            });
                        }
                    }
                }

                delegate: Item {
                    id: delegateRoot
                    readonly property bool isCurrent: ListView.isCurrentItem
                    readonly property var currentTags: root.getTagsForFile(fileName)

                    width: isCurrent ? root.itemWidthExpanded : root.itemWidthCollapsed
                    height: view.height
                    z: isCurrent ? 10 : 1

                    Behavior on width {
                        NumberAnimation { duration: 280; easing.type: Easing.OutExpo }
                    }

                    function pickWallpaper() {
                        root.pickWallpaper(fileName);
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (view.currentIndex === index) {
                                delegateRoot.pickWallpaper();
                            } else {
                                view.currentIndex = index;
                            }
                        }
                        onDoubleClicked: {
                            delegateRoot.pickWallpaper();
                        }
                    }

                    Item {
                        anchors.centerIn: parent
                        width: parent.width
                        height: delegateRoot.isCurrent ? root.itemHeight : (root.itemHeight - 34)
                        opacity: delegateRoot.isCurrent ? 1.0 : 0.42

                        Behavior on height { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                        Behavior on opacity { NumberAnimation { duration: 240; easing.type: Easing.OutQuad } }

                        // Marco exterior con acento en el elemento seleccionado
                        Rectangle {
                            anchors.fill: parent
                            radius: delegateRoot.isCurrent ? 16 : 10
                            color: delegateRoot.isCurrent ? root.clrAccent : root.clrBgPill
                            border.color: delegateRoot.isCurrent ? root.clrAccent : Qt.rgba(1, 1, 1, 0.08)
                            border.width: delegateRoot.isCurrent ? 2 : 1

                            Behavior on radius { NumberAnimation { duration: 200 } }
                            Behavior on color { ColorAnimation { duration: 200 } }
                            Behavior on border.color { ColorAnimation { duration: 200 } }
                        }

                        // Imagen miniatura recortada con esquinas redondeadas reales (máscara GPU)
                        Item {
                            anchors.fill: parent
                            anchors.margins: delegateRoot.isCurrent ? 3 : 1

                            Rectangle {
                                id: thumbMask
                                anchors.fill: parent
                                radius: delegateRoot.isCurrent ? 14 : 8
                                color: "white"
                                visible: false
                                layer.enabled: true
                            }

                            Image {
                                id: thumbImg
                                anchors.fill: parent
                                fillMode: Image.PreserveAspectCrop
                                source: fileUrl
                                sourceSize.height: 380
                                cache: true
                                asynchronous: true
                                smooth: true
                                visible: false
                                layer.enabled: true
                            }

                            MultiEffect {
                                anchors.fill: parent
                                source: thumbImg
                                maskEnabled: true
                                maskSource: thumbMask
                                antialiasing: true
                            }
                        }

                        // Superposición inferior: Solo Etiquetas generadas por IA
                        Rectangle {
                            anchors.bottom: parent.bottom
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.margins: 6
                            height: 32
                            color: Qt.rgba(0.04, 0.04, 0.06, 0.85)
                            radius: 10
                            border.color: Qt.rgba(1, 1, 1, 0.08)
                            border.width: 1
                            visible: delegateRoot.isCurrent && delegateRoot.currentTags.length > 0
                            opacity: visible ? 1 : 0
                            clip: true

                            Behavior on opacity { NumberAnimation { duration: 200 } }

                            Flickable {
                                anchors.fill: parent
                                anchors.leftMargin: 6
                                anchors.rightMargin: 6
                                contentWidth: tagsRow.implicitWidth
                                clip: true
                                boundsBehavior: Flickable.StopAtBounds

                                Row {
                                    id: tagsRow
                                    spacing: 5
                                    anchors.verticalCenter: parent.verticalCenter

                                    Repeater {
                                        model: delegateRoot.currentTags
                                        Rectangle {
                                            readonly property bool isMatched: {
                                                let q = root.searchQuery.trim().toLowerCase();
                                                return q !== "" && modelData.toLowerCase().indexOf(q) !== -1;
                                            }
                                            width: tagLabel.implicitWidth + 12
                                            height: 20
                                            radius: 10
                                            color: isMatched ? root.clrAccent : (tagMa.containsMouse ? Qt.rgba(1, 1, 1, 0.22) : Qt.rgba(1, 1, 1, 0.12))
                                            border.color: isMatched ? root.clrAccent : Qt.rgba(1, 1, 1, 0.12)
                                            border.width: 1

                                            Behavior on color { ColorAnimation { duration: 150 } }

                                            Text {
                                                id: tagLabel
                                                anchors.centerIn: parent
                                                text: modelData
                                                color: parent.isMatched ? "#050508" : root.clrText
                                                font.family: root.fontSans
                                                font.pixelSize: 10
                                                font.weight: Font.Medium
                                            }

                                            MouseArea {
                                                id: tagMa
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    searchField.text = modelData;
                                                    root.searchQuery = modelData;
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Estado de lista vacía
            Text {
                anchors.centerIn: parent
                visible: view.count === 0
                text: root.searchQuery !== "" ? "No se encontraron fondos con el criterio '" + root.searchQuery + "'" : "No se encontraron miniaturas en ~/.cache/wallpaper"
                color: root.clrMuted
                font.family: root.fontSans
                font.pixelSize: 12
            }
        }
    }
}
