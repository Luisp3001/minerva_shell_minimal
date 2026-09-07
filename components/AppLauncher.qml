import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Caelestia

// ── App Launcher (Isla Dinámica + SQLite Frequency + Qalculator) ──────────────
// Integración nativa con AppDb (persistencia SQLite en ~/.cache/quickshell_appdb.sqlite)
// y evaluación matemática asíncrona en tiempo real con Qalculator.
// ─────────────────────────────────────────────────────────────────────────────
Item {
    id: launcher

    // ── Señales y control público ─────────────────────────────────────────────
    signal closeRequested()
    signal appLaunched()

    property bool active: false
    property alias queryText: searchInput.text

    // ── Dimensiones y Márgenes Generosos ──────────────────────────────────────
    readonly property int topPadding: 14
    readonly property int bottomPadding: 14
    readonly property int sidePadding: 16
    readonly property int searchBarH: 46
    readonly property int itemH: 50
    readonly property int headerH: 26
    readonly property int itemSpacing: 4
    readonly property int maxRecent: 6
    readonly property int maxAppsSearch: 6

    // ── Colores (Catppuccin Mocha con acento Sky/Sapphire) ────────────────────
    readonly property color clrText:     "#cdd6f4"
    readonly property color clrSubtext:  "#6c7086"
    readonly property color clrAccent:   "#89dceb"
    readonly property color clrBorder:   "#313244"
    readonly property color clrSelected: Qt.rgba(0.537, 0.863, 0.922, 0.14)
    readonly property color clrHover:    Qt.rgba(0.804, 0.753, 0.961, 0.07)
    readonly property color clrInputBg:  "#0b0b10"

    // ── Tipografía ───────────────────────────────────────────────────────────
    readonly property string fontSans: "Noto Sans, Inter, system-ui, sans-serif"
    readonly property string fontNerd: "Iosevka Nerd Font, Symbols Nerd Font"
    readonly property string fontMono: "JetBrains Mono, monospace"

    // ── Estado interno ───────────────────────────────────────────────────────
    property var results: []
    property var selectableIndices: []
    property int selectedIdx: 0

    property string searchMode: "apps"   // "apps" | "math"
    property string cleanQuery: ""
    property string calcResult: ""
    property bool calcPending: false
    property bool justCopied: false
    property var appResults: []

    // ── Cálculo reactivo de altura para la Isla Dinámica ──────────────────────
    readonly property int contentHeight: {
        let listH = 0
        if (results.length === 0) {
            listH = searchInput.text.trim().length > 0 ? 54 : 0
        } else {
            for (let i = 0; i < results.length; i++) {
                listH += (results[i].type === "header") ? headerH : itemH
                if (i > 0) listH += itemSpacing
            }
        }
        let sepH = (results.length > 0 || searchInput.text.trim().length > 0) ? 14 : 0
        let total = topPadding + searchBarH + sepH + listH + bottomPadding
        return Math.min(total, 540)
    }

    // ── Base de datos SQLite (AppDb desde Caelestia) ──────────────────────────
    AppDb {
        id: appDb
        path: Quickshell.env("HOME") + "/.cache/quickshell_appdb.sqlite"
        favouriteApps: []
        entries: DesktopEntries.applications.values
        onAppsChanged: launcher.updateSearch()
    }

    // Inicialización del fichero SQLite si no existiera
    Process {
        id: initProc
        command: ["bash", "-c",
            "db=\"$HOME/.cache/quickshell_appdb.sqlite\"; "
            + "[ -f \"$db\" ] || sqlite3 \"$db\" 'CREATE TABLE IF NOT EXISTS frequencies (id TEXT PRIMARY KEY, frequency INTEGER)' 2>/dev/null;"
        ]
        running: true
    }

    // ── Qalculator: conexión a señales y debounce ─────────────────────────────
    Connections {
        target: Qalculator
        function onRawResultChanged() {
            if (launcher.searchMode !== "math") return
            let raw = Qalculator.rawResult ? Qalculator.rawResult.trim() : ""
            let q = launcher.cleanQuery.trim()
            if (raw.length > 0 && raw !== q && !raw.startsWith("warning:") && raw !== "error") {
                launcher.calcResult = raw
            } else {
                launcher.calcResult = ""
            }
            launcher.buildResults()
        }
        function onBusyChanged() {
            if (launcher.searchMode !== "math") return
            launcher.calcPending = Qalculator.busy
            launcher.buildResults()
        }
    }

    Timer {
        id: calcDebounce
        interval: 120
        onTriggered: {
            if (launcher.searchMode === "math" && launcher.cleanQuery.length >= 1) {
                Qalculator.evalAsync(launcher.cleanQuery)
            }
        }
    }

    Timer {
        id: copiedTimer
        interval: 1600
        onTriggered: launcher.justCopied = false
    }

    // ── Procesos para portapapeles y ejecución ────────────────────────────────
    Process {
        id: clipProc
        property string textToCopy: ""
        command: ["bash", "-c", "printf '%s' " + JSON.stringify(textToCopy) + " | wl-copy"]
    }

    Process {
        id: launchProc
        property string launchCmd: ""
        command: ["bash", "-c", launchCmd]
    }

    Timer {
        id: focusTimer
        interval: 50
        onTriggered: searchInput.forceActiveFocus()
    }

    // ── Métodos de control ───────────────────────────────────────────────────
    function open() {
        active = true
        searchInput.text = ""
        justCopied = false
        updateSearch()
        selectedIdx = 0
        if (selectableIndices.length > 0) {
            resultList.currentIndex = selectableIndices[0]
        }
        focusTimer.restart()
    }

    function close() {
        active = false
        searchInput.text = ""
        calcResult = ""
        justCopied = false
    }

    function reset() {
        searchInput.text = ""
        updateSearch()
        selectedIdx = 0
    }

    // ── Búsqueda y Algoritmo Fuzzy ───────────────────────────────────────────
    function fuzzyScore(name, genericName, keywords, query) {
        let n = name.toLowerCase()
        let q = query.toLowerCase()

        if (n === q) return 100
        if (n.startsWith(q)) return 85
        if (n.includes(q)) return 65

        if (genericName) {
            let gn = genericName.toLowerCase()
            if (gn === q) return 75
            if (gn.startsWith(q)) return 60
            if (gn.includes(q)) return 45
        }

        if (keywords) {
            let kw = keywords.toLowerCase()
            if (kw.startsWith(q)) return 40
            if (kw.includes(q)) return 30
        }

        let qi = 0
        for (let i = 0; i < n.length && qi < q.length; i++) {
            if (n[i] === q[qi]) qi++
        }
        return qi === q.length ? 15 : 0
    }

    function updateSearch() {
        let raw = searchInput.text.trim()
        let isMath = raw.startsWith("=")
        cleanQuery = isMath ? raw.substring(1).trim() : raw

        if (isMath) {
            searchMode = "math"
            calcResult = ""
            if (cleanQuery.length >= 1) {
                calcPending = true
                buildResults()
                calcDebounce.restart()
            } else {
                calcPending = false
                buildResults()
            }
            return
        }

        searchMode = "apps"
        calcPending = false
        calcResult = ""
        filterApps(cleanQuery)
    }

    function filterApps(q) {
        let scored = []
        let appsList = appDb.apps

        for (let i = 0; i < appsList.length; i++) {
            let app = appsList[i]
            if (!app.entry || !app.name) continue
            if (app.entry.noDisplay) continue

            let freq = app.frequency || 0
            let sc = 0

            if (!q) {
                // Sin búsqueda: ordenar por frecuencia de SQLite
                sc = freq * 10 + 1
            } else {
                sc = fuzzyScore(app.name, app.genericName, app.keywords, q)
                if (sc === 0) continue
                // Boost por uso frecuente
                sc += freq * 0.1
            }
            scored.push({ sc: sc, app: app })
        }

        scored.sort((a, b) => b.sc - a.sc || a.app.name.localeCompare(b.app.name))
        let limit = q ? maxAppsSearch : maxRecent

        appResults = scored.slice(0, limit).map(s => ({
            type: "app",
            id: s.app.id,
            name: s.app.name,
            genericName: s.app.genericName || "",
            comment: s.app.comment || "",
            icon: s.app.entry ? (s.app.entry.icon || "") : "",
            execString: s.app.execString || "",
            runInTerminal: s.app.entry ? s.app.entry.runInTerminal : false,
            frequency: s.app.frequency,
            entry: s.app.entry
        }))
        buildResults()
    }

    function buildResults() {
        let items = []
        let indices = []
        let q = cleanQuery
        let mode = searchMode

        if (mode === "math") {
            items.push({ type: "header", label: "CALCULADORA" })
            let label = ""
            if (calcPending) {
                label = "Calculando..."
            } else if (calcResult.length > 0) {
                label = q + "  =  " + calcResult
            } else {
                label = q.length > 0 ? "Expresión no válida" : "Escribe una expresión (ej. =2^10, =sin(45 deg))..."
            }
            indices.push(items.length)
            items.push({
                type: "calc",
                label: label,
                calcValue: calcResult,
                rawQuery: q,
                isValid: calcResult.length > 0
            })
        } else {
            if (!q) {
                if (appResults.length > 0) {
                    items.push({ type: "header", label: "MÁS USADAS" })
                    for (let a of appResults) {
                        indices.push(items.length)
                        items.push(a)
                    }
                }
            } else {
                if (appResults.length > 0) {
                    items.push({ type: "header", label: "APLICACIONES" })
                    for (let a of appResults) {
                        indices.push(items.length)
                        items.push(a)
                    }
                }
            }
        }

        results = items
        selectableIndices = indices
        if (indices.length > 0) {
            selectedIdx = 0
            resultList.currentIndex = indices[0]
        } else {
            selectedIdx = -1
            resultList.currentIndex = -1
        }
    }

    // ── Navegación y Ejecución ───────────────────────────────────────────────
    function cleanExec(execStr) {
        return execStr.replace(/%[uUfFdDnNvmick]/g, "").replace(/\s+/g, " ").trim()
    }

    function launchApp(app) {
        if (!app) return

        let id = app.id || ""
        if (id) {
            appDb.incrementFrequency(id)
        }

        if (app.runInTerminal) {
            let execCmd = app.execString ? cleanExec(app.execString) : app.name
            launchProc.launchCmd = "kitty -e zsh -i -c '" + execCmd + "'"
            launchProc.running = false
            launchProc.running = true
        } else if (app.entry && typeof app.entry.execute === "function") {
            app.entry.execute()
        } else if (app.execString) {
            launchProc.launchCmd = cleanExec(app.execString)
            launchProc.running = false
            launchProc.running = true
        }

        appLaunched()
        closeRequested()
    }

    function executeSelected() {
        if (selectedIdx < 0 || selectedIdx >= selectableIndices.length) return
        let actualIdx = selectableIndices[selectedIdx]
        executeItem(actualIdx)
    }

    function executeItem(actualIdx) {
        if (actualIdx < 0 || actualIdx >= results.length) return
        let item = results[actualIdx]
        if (!item || item.type === "header") return

        if (item.type === "app") {
            launchApp(item)
        } else if (item.type === "calc") {
            if (item.calcValue && item.calcValue.length > 0) {
                clipProc.textToCopy = item.calcValue
                clipProc.running = false
                clipProc.running = true
                justCopied = true
                copiedTimer.restart()
            }
        }
    }

    function navigateUp() {
        if (selectableIndices.length === 0) return
        if (selectedIdx > 0) {
            selectedIdx--
            resultList.currentIndex = selectableIndices[selectedIdx]
        }
    }

    function navigateDown() {
        if (selectableIndices.length === 0) return
        if (selectedIdx < selectableIndices.length - 1) {
            selectedIdx++
            resultList.currentIndex = selectableIndices[selectedIdx]
        }
    }

    // ── Estructura de la UI ──────────────────────────────────────────────────
    Column {
        anchors.fill: parent
        spacing: 0

        // ── 0. Espaciador Superior (Margen para la curva de la isla) ─────────────
        Item {
            width: parent.width
            height: launcher.topPadding
        }

        // ── 1. Barra de búsqueda estilizada ──────────────────────────────────
        Item {
            width: parent.width
            height: launcher.searchBarH

            Rectangle {
                anchors {
                    left: parent.left;   leftMargin: launcher.sidePadding
                    right: parent.right; rightMargin: launcher.sidePadding
                    top: parent.top
                    bottom: parent.bottom
                }
                radius: 14
                color: launcher.clrInputBg

                Behavior on border.color { ColorAnimation { duration: 150 } }

                Row {
                    anchors {
                        left: parent.left;   leftMargin: 14
                        right: parent.right; rightMargin: 12
                        verticalCenter: parent.verticalCenter
                    }
                    spacing: 10

                    // Icono reactivo (búsqueda o calculadora)
                    Text {
                        text: launcher.searchMode === "math" ? "󰪚" : "󰍉"
                        font.family: launcher.fontNerd
                        font.pixelSize: 17
                        color: (searchInput.text.length > 0 || launcher.searchMode === "math")
                            ? launcher.clrAccent
                            : launcher.clrSubtext
                        anchors.verticalCenter: parent.verticalCenter
                        Behavior on color { ColorAnimation { duration: 150 } }
                    }

                    // Input con placeholder
                    Item {
                        width: parent.width - 27 - (clearBtn.visible ? 26 : 0)
                        height: launcher.searchBarH
                        anchors.verticalCenter: parent.verticalCenter

                        Text {
                            visible: searchInput.text.length === 0
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Buscar aplicación o '=' para calculadora..."
                            font.family: launcher.fontSans
                            font.pixelSize: 14
                            color: launcher.clrSubtext
                        }

                        TextInput {
                            id: searchInput
                            anchors.fill: parent
                            font.family: launcher.searchMode === "math" ? launcher.fontMono : launcher.fontSans
                            font.pixelSize: 14
                            font.weight: Font.Medium
                            color: launcher.clrText
                            verticalAlignment: TextInput.AlignVCenter
                            selectionColor: Qt.rgba(0.537, 0.863, 0.922, 0.30)
                            clip: true

                            onTextChanged: launcher.updateSearch()

                            Keys.onUpPressed:      function(e) { launcher.navigateUp();      e.accepted = true }
                            Keys.onDownPressed:    function(e) { launcher.navigateDown();    e.accepted = true }
                            Keys.onTabPressed:     function(e) { launcher.navigateDown();    e.accepted = true }
                            Keys.onBacktabPressed: function(e) { launcher.navigateUp();      e.accepted = true }
                            Keys.onReturnPressed:  function(e) { launcher.executeSelected(); e.accepted = true }
                            Keys.onEscapePressed:  function(e) { launcher.closeRequested();  e.accepted = true }
                        }
                    }

                    // Botón para limpiar búsqueda
                    Rectangle {
                        id: clearBtn
                        visible: searchInput.text.length > 0
                        width: 20
                        height: 20
                        radius: 10
                        color: clearMouse.containsMouse ? "#313244" : "transparent"
                        anchors.verticalCenter: parent.verticalCenter

                        Behavior on color { ColorAnimation { duration: 100 } }

                        Text {
                            anchors.centerIn: parent
                            text: "󰅖"
                            font.family: launcher.fontNerd
                            font.pixelSize: 12
                            color: clearMouse.containsMouse ? "#ffffff" : launcher.clrSubtext
                        }

                        MouseArea {
                            id: clearMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                searchInput.text = ""
                                searchInput.forceActiveFocus()
                            }
                        }
                    }
                }
            }
        }

        // ── 2. Separador sutil ────────────────────────────────────────────────
        Item {
            width: parent.width
            height: (launcher.results.length > 0 || searchInput.text.trim().length > 0) ? 14 : 0
            visible: height > 0

            Rectangle {
                anchors.centerIn: parent
                width: parent.width - (launcher.sidePadding * 2)
                height: 1
                color: launcher.clrBorder
            }
        }

        // ── 3. Mensaje si no hay resultados ───────────────────────────────────
        Item {
            width: parent.width
            height: 54
            visible: launcher.results.length === 0 && searchInput.text.trim().length > 0

            Row {
                anchors.centerIn: parent
                spacing: 8
                Text {
                    text: "󰱵"
                    font.family: launcher.fontNerd
                    font.pixelSize: 16
                    color: launcher.clrSubtext
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: "No se encontraron resultados"
                    font.family: launcher.fontSans
                    font.pixelSize: 13
                    color: launcher.clrSubtext
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }

        // ── 4. Lista de resultados (Apps / Calculadora / Cabeceras) ────────────
        ListView {
            id: resultList
            width: parent.width
            height: {
                let h = 0
                for (let i = 0; i < launcher.results.length; i++) {
                    h += (launcher.results[i].type === "header") ? launcher.headerH : launcher.itemH
                    if (i > 0) h += launcher.itemSpacing
                }
                return h
            }
            clip: true
            spacing: launcher.itemSpacing
            model: launcher.results
            currentIndex: 0
            boundsBehavior: Flickable.StopAtBounds
            onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

            delegate: Loader {
                id: itemLoader
                required property var modelData
                required property int index

                width: resultList.width
                height: (modelData && modelData.type === "header") ? launcher.headerH : launcher.itemH

                sourceComponent: (modelData && modelData.type === "header") ? headerComp : rowComp
            }
        }

        // ── 5. Espaciador Inferior (Margen para la curva de la isla) ─────────────
        Item {
            width: parent.width
            height: launcher.bottomPadding
        }
    }

    // ── Componente: Cabecera de Categoría ────────────────────────────────────
    Component {
        id: headerComp
        Item {
            width: resultList.width
            height: launcher.headerH

            Text {
                anchors {
                    left: parent.left
                    leftMargin: launcher.sidePadding + 4
                    bottom: parent.bottom
                    bottomMargin: 4
                }
                text: modelData.label || ""
                font.family: launcher.fontSans
                font.pixelSize: 10
                font.weight: Font.Bold
                font.letterSpacing: 1.2
                color: launcher.clrSubtext
                opacity: 0.8
            }
        }
    }

    // ── Componente: Elemento Ejecutable (App / Calculadora) ───────────────────
    Component {
        id: rowComp
        Item {
            width: resultList.width
            height: launcher.itemH

            Rectangle {
                id: itemRow
                readonly property bool isSelected: resultList.currentIndex === index

                anchors {
                    left: parent.left;   leftMargin: launcher.sidePadding
                    right: parent.right; rightMargin: launcher.sidePadding
                    top: parent.top
                    bottom: parent.bottom
                }
                radius: 12
                color: isSelected ? launcher.clrSelected : (itemMouse.containsMouse ? launcher.clrHover : "transparent")
                border.color: isSelected ? Qt.rgba(0.537, 0.863, 0.922, 0.25) : "transparent"
                border.width: isSelected ? 1 : 0

                Behavior on color { ColorAnimation { duration: 100 } }

                Row {
                    anchors {
                        left: parent.left;   leftMargin: 14
                        right: parent.right; rightMargin: 14
                        verticalCenter: parent.verticalCenter
                    }
                    spacing: 14

                    // Icono: Calculadora o Aplicación
                    Item {
                        width: 32; height: 32
                        anchors.verticalCenter: parent.verticalCenter
                        visible: modelData.type === "calc"

                        Rectangle {
                            anchors.fill: parent
                            radius: 8
                            color: Qt.rgba(0.537, 0.863, 0.922, 0.15)

                            Text {
                                anchors.centerIn: parent
                                text: "󰪚"
                                font.family: launcher.fontNerd
                                font.pixelSize: 18
                                color: launcher.clrAccent
                            }
                        }
                    }

                    Item {
                        id: iconBox
                        width: 32; height: 32
                        anchors.verticalCenter: parent.verticalCenter
                        visible: modelData.type === "app"

                        readonly property string rawIcon: (modelData.type === "app" && modelData.icon) ? modelData.icon : ""
                        readonly property bool isAbsPath: rawIcon.startsWith("/")

                        Image {
                            id: appIcon
                            anchors.fill: parent
                            source: iconBox.isAbsPath ? ("file://" + iconBox.rawIcon) : (iconBox.rawIcon ? Quickshell.iconPath(iconBox.rawIcon) : "")
                            sourceSize.width: 32
                            sourceSize.height: 32
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                            smooth: true
                            visible: status === Image.Ready
                        }

                        Image {
                            id: papirusFallback
                            anchors.fill: parent
                            source: (appIcon.status === Image.Error && !iconBox.isAbsPath && iconBox.rawIcon)
                                ? ("file:///usr/share/icons/Papirus/64x64/apps/" + iconBox.rawIcon + ".svg")
                                : ""
                            sourceSize.width: 32
                            sourceSize.height: 32
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                            smooth: true
                            visible: status === Image.Ready
                        }

                        Text {
                            anchors.centerIn: parent
                            visible: !appIcon.visible && !papirusFallback.visible
                            text: (modelData.type === "app" && modelData.runInTerminal) ? "󰞷" : "󰀻"
                            font.family: launcher.fontNerd
                            font.pixelSize: 18
                            color: itemRow.isSelected ? launcher.clrAccent : launcher.clrSubtext
                        }
                    }

                    // Información del resultado
                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 32 - 14 - (itemRow.isSelected ? 24 : 0)
                        spacing: 3

                        Text {
                            width: parent.width
                            text: modelData.type === "calc" ? modelData.label : (modelData.name || "")
                            font.family: modelData.type === "calc" ? launcher.fontMono : launcher.fontSans
                            font.pixelSize: 14
                            font.weight: Font.DemiBold
                            color: itemRow.isSelected ? launcher.clrAccent : launcher.clrText
                            elide: Text.ElideRight
                            Behavior on color { ColorAnimation { duration: 100 } }
                        }

                        Text {
                            width: parent.width
                            visible: text.length > 0
                            text: {
                                if (modelData.type === "calc") {
                                    return launcher.justCopied
                                        ? "¡Copiado al portapapeles! 󰄬"
                                        : (modelData.isValid ? "Presiona Enter para copiar resultado" : "Escribe una expresión válida")
                            }
                                return modelData.genericName || modelData.comment || ""
                            }
                            font.family: launcher.fontSans
                            font.pixelSize: 11
                            color: (modelData.type === "calc" && launcher.justCopied) ? launcher.clrAccent : launcher.clrSubtext
                            elide: Text.ElideRight
                        }
                    }

                    // Indicador de tecla Return
                    Text {
                        visible: itemRow.isSelected
                        anchors.verticalCenter: parent.verticalCenter
                        text: "󰌑"
                        font.family: launcher.fontNerd
                        font.pixelSize: 14
                        color: launcher.clrAccent
                    }
                }

                MouseArea {
                    id: itemMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        launcher.executeItem(index)
                    }
                    onEntered: {
                        resultList.currentIndex = index
                        launcher.selectedIdx = launcher.selectableIndices.indexOf(index)
                    }
                }
            }
        }
    }
}
