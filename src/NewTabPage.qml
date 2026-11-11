import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import QtQuick.Shapes

// The new tab page: the time, a search box with the engines at hand, the
// shortcuts and what you were reading. Every part can be turned off or
// restyled in Réglages → Nouvel onglet.
Rectangle {
    id: page
    property var owner: null
    readonly property var win: owner ? owner.browserWindow : null
    readonly property bool isPrivate: owner ? owner.isPrivate : false
    function opt(key) { return settings.revision, settings.value(key) }

    // A Chrome theme brings its new tab picture (or colour).
    readonly property var chromeTheme: {
        const raw = opt("appearance/chromeTheme")
        try { return raw ? JSON.parse(raw) : null } catch (e) { return null }
    }
    readonly property string themeImage: chromeTheme && chromeTheme.image ? chromeTheme.image : ""
    readonly property string background: themeImage !== "" ? "image" : opt("newtab/background")
    readonly property var defaultEngine: (engines.revision, engines.engine(opt(isPrivate ? "search/privateEngine" : "search/engine")))
    property date now: new Date()
    Timer { interval: page.opt("newtab/seconds") ? 1000 : 15000; running: page.visible; repeat: true; triggeredOnStart: true; onTriggered: page.now = new Date() }

    color: !isPrivate && chromeTheme && chromeTheme.ntpColor ? chromeTheme.ntpColor : theme.background

    // ------------------------------------------------------------ backgrounds
    Rectangle {
        anchors.fill: parent
        visible: page.background === "gradient" && !page.isPrivate
        gradient: Gradient {
            GradientStop { position: 0; color: theme.alpha(theme.highlight, theme.isDark ? 0.30 : 0.22) }
            GradientStop { position: 0.65; color: theme.background }
        }
    }
    // A soft glow of the accent behind the clock, fading into the page.
    Shape {
        id: glowShape
        anchors.fill: parent
        visible: page.background === "glow" || page.isPrivate
        preferredRendererType: Shape.CurveRenderer
        readonly property color glow: page.isPrivate ? "#9b7bff" : theme.highlight
        ShapePath {
            strokeColor: "transparent"
            fillGradient: RadialGradient {
                centerX: page.width / 2; centerY: -page.height * 0.05
                focalX: centerX; focalY: centerY
                centerRadius: Math.max(page.width, page.height) * 0.62
                focalRadius: 0
                GradientStop { position: 0.0; color: theme.alpha(glowShape.glow, theme.isDark ? 0.26 : 0.20) }
                GradientStop { position: 0.45; color: theme.alpha(glowShape.glow, theme.isDark ? 0.10 : 0.08) }
                GradientStop { position: 1.0; color: theme.alpha(glowShape.glow, 0) }
            }
            PathRectangle { x: 0; y: 0; width: page.width; height: page.height }
        }
    }
    Image {
        id: wallpaper
        anchors.fill: parent
        visible: page.background === "image" && !page.isPrivate && status === Image.Ready
        source: page.background === "image" ? (page.themeImage !== "" ? page.themeImage : page.opt("newtab/image")) : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
    }
    Rectangle {
        anchors.fill: parent
        visible: wallpaper.visible
        color: theme.background
        opacity: page.opt("newtab/dim")
    }

    // ------------------------------------------------------------ content
    Flickable {
        anchors.fill: parent
        contentHeight: Math.max(height, content.implicitHeight + 120)
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        ScrollBar.vertical: ScrollBar {}

        ColumnLayout {
            id: content
            width: Math.min(page.width - 64, 820)
            x: (page.width - width) / 2
            y: Math.max(48, page.height * 0.16)
            spacing: 0

            // Private tab explanation.
            ColumnLayout {
                visible: page.isPrivate
                Layout.alignment: Qt.AlignHCenter
                Layout.bottomMargin: 28
                spacing: 8
                Rectangle {
                    Layout.alignment: Qt.AlignHCenter
                    width: 64; height: 64; radius: 18
                    color: theme.alpha("#9b7bff", 0.18)
                    Icon { anchors.centerIn: parent; name: "mask"; size: 34; color: "#9b7bff" }
                }
                Text { Layout.alignment: Qt.AlignHCenter; text: "Onglet privé"; color: theme.text; font.pixelSize: 26; font.weight: Font.Bold }
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.maximumWidth: 520
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    text: "Rien n'est gardé : ni historique, ni cookies, ni cache, ni icônes de sites. Tout disparaît quand le dernier onglet privé se ferme. Les sites et ton fournisseur d'accès voient toujours ta visite."
                    color: theme.textDim
                    font.pixelSize: 13
                    lineHeight: 1.25
                }
            }

            // Time and greeting.
            ColumnLayout {
                visible: !page.isPrivate && (page.opt("newtab/clock") || page.opt("newtab/greeting"))
                Layout.alignment: Qt.AlignHCenter
                spacing: 2
                Text {
                    visible: page.opt("newtab/clock")
                    Layout.alignment: Qt.AlignHCenter
                    text: Qt.formatTime(page.now, page.opt("newtab/seconds") ? "HH:mm:ss" : "HH:mm")
                    color: theme.text
                    font.pixelSize: Math.max(40, Math.min(76, page.width / 5))
                    font.weight: Font.Light
                    font.letterSpacing: -2
                    font.features: { "tnum": 1 }
                }
                Text {
                    visible: page.opt("newtab/greeting")
                    Layout.alignment: Qt.AlignHCenter
                    text: {
                        const h = page.now.getHours()
                        const hello = h < 5 ? "Bonne nuit" : h < 12 ? "Bonjour" : h < 18 ? "Bon après-midi" : "Bonsoir"
                        const name = page.opt("newtab/name")
                        return hello + (name ? ", " + name : "") + " · " + page.now.toLocaleDateString(Qt.locale("fr_FR"), "dddd d MMMM")
                    }
                    color: theme.textDim
                    font.pixelSize: 15
                }
            }

            // The search box: type here, Enter searches (or opens an
            // address); suggestions from the engine and your history below.
            Rectangle {
                id: box
                visible: page.opt("newtab/search")
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: 30
                Layout.preferredWidth: Math.min(content.width, 640)
                Layout.preferredHeight: 52
                radius: 26
                color: theme.surface
                border.color: field.activeFocus ? theme.highlight : (boxHover.hovered ? theme.alpha(theme.text, 0.18) : theme.line)
                border.width: field.activeFocus ? 2 : 1
                HoverHandler { id: boxHover; cursorShape: Qt.IBeamCursor }

                // An engine picked from the row below, for this search only.
                property string engineKey: ""
                readonly property var engine: (engines.revision, engineKey !== "" ? engines.engine(engineKey) : page.defaultEngine)
                property var rows: []
                property int selected: -1

                function query() { return field.text.trim() }
                function refresh() {
                    const q = query()
                    if (q === "") { rows = []; selected = -1; suggestions.close(); return }
                    const list = []
                    const resolved = engineKey !== "" ? null : engines.resolve(q, page.defaultEngine.key)
                    if (resolved && resolved.kind === "url") list.push({ kind: "url", text: resolved.url })
                    else list.push({ kind: "search", text: resolved && resolved.query ? resolved.query : q,
                                     engine: resolved && resolved.engine ? engines.engine(resolved.engine) : box.engine })
                    if (!page.isPrivate && page.opt("search/historySuggestions") && engineKey === "")
                        for (const h of library.suggest(q, 3)) list.push({ kind: "history", text: h.title || h.url, url: h.url })
                    rows = list
                    selected = -1
                    suggestions.open()
                    const on = page.isPrivate ? page.opt("search/privateSuggestions") : page.opt("search/suggestions")
                    if (on && !(resolved && resolved.kind === "url")) suggestTimer.restart()
                }
                Timer { id: suggestTimer; interval: 120; onTriggered: engines.suggest(box.query(), box.engine.key) }
                Connections {
                    target: engines
                    function onSuggestionsReady(query, list) {
                        if (!field.activeFocus || query !== box.query()) return
                        const known = new Set(box.rows.map(r => (r.text || "").toLowerCase()))
                        const extra = list.filter(t => !known.has(t.toLowerCase())).slice(0, Math.min(6, page.opt("search/maxSuggestions")))
                                          .map(t => ({ kind: "suggest", text: t }))
                        box.rows = box.rows.filter(r => r.kind !== "suggest").concat(extra)
                    }
                }
                // Enter: the selected row, else what is typed. Alt: new tab.
                function go(row, newTab) {
                    let url = ""
                    if (row && row.kind === "url") url = row.text
                    else if (row && row.kind === "history") url = row.url
                    else if (row && row.kind === "search") url = engines.searchUrl(row.engine.key, row.text)
                    else if (row && row.kind === "suggest") url = engines.searchUrl(box.engine.key, row.text)
                    else if (query() !== "") url = engineKey !== "" ? engines.searchUrl(engineKey, query()) : engines.resolve(query(), page.defaultEngine.key).url
                    else if (engineKey !== "") url = engines.homeUrl(engineKey)
                    if (!url || !page.owner) return
                    suggestions.close()
                    field.text = ""
                    engineKey = ""
                    if (newTab && page.win) page.win.openTab(url, { private: page.isPrivate, background: false })
                    else page.owner.load(url)
                }
                function focusSearch(key) {
                    engineKey = key && key !== page.defaultEngine.key ? key : ""
                    field.forceActiveFocus()
                    if (query() !== "") refresh()
                }

                // A click anywhere in the box (the badge, the margins) types in it.
                MouseArea {
                    anchors.fill: parent
                    onPressed: (mouse) => { field.forceActiveFocus(); mouse.accepted = false }
                }
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 16
                    anchors.rightMargin: 16
                    spacing: 12
                    EngineBadge { engine: box.engine; size: 22 }
                    Field {
                        id: field
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        topPadding: 0
                        bottomPadding: 0
                        leftPadding: 0
                        rightPadding: 0
                        verticalAlignment: TextInput.AlignVCenter
                        selectByMouse: true
                        font.pixelSize: 15
                        hint: "Rechercher avec " + (box.engine.name || "le moteur") + " ou saisir une adresse"
                        onTextEdited: box.refresh()
                        onActiveFocusChanged: if (!activeFocus) suggestions.close()
                        Keys.onPressed: (event) => {
                            if (event.key === Qt.Key_Down) {
                                if (box.rows.length) { box.selected = Math.min(box.rows.length - 1, box.selected + 1); suggestions.open() }
                                event.accepted = true
                            } else if (event.key === Qt.Key_Up) {
                                box.selected = Math.max(-1, box.selected - 1); event.accepted = true
                            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                box.go(box.selected >= 0 ? box.rows[box.selected] : null, !!(event.modifiers & Qt.AltModifier))
                                event.accepted = true
                            } else if (event.key === Qt.Key_Escape) {
                                if (suggestions.opened) suggestions.close(); else if (box.engineKey !== "") box.engineKey = ""; else { field.text = ""; box.refresh() }
                                event.accepted = true
                            } else if (event.key === Qt.Key_Backspace && field.text === "" && box.engineKey !== "") {
                                box.engineKey = ""; event.accepted = true
                            }
                        }
                    }
                    IconButton {
                        visible: field.text !== ""
                        implicitWidth: 26; implicitHeight: 26
                        icon: "close"; iconSize: 12; tip: "Effacer"
                        onClicked: { field.text = ""; box.refresh(); field.forceActiveFocus() }
                    }
                }

                Popup {
                    id: suggestions
                    y: box.height + 6
                    width: box.width
                    padding: 6
                    focus: false
                    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
                    background: Rectangle { color: theme.surface; radius: 14; border.color: theme.line }
                    contentItem: ListView {
                        implicitHeight: contentHeight
                        interactive: false
                        model: box.rows
                        delegate: Rectangle {
                            id: suggestion
                            required property var modelData
                            required property int index
                            width: ListView.view.width
                            height: 38
                            radius: 9
                            color: index === box.selected || suggestionHover.containsMouse ? theme.alpha(theme.highlight, 0.14) : "transparent"
                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 12
                                anchors.rightMargin: 12
                                spacing: 12
                                Item {
                                    Layout.preferredWidth: 18; Layout.preferredHeight: 18
                                    EngineBadge { anchors.centerIn: parent; visible: suggestion.modelData.kind === "search"; engine: suggestion.modelData.engine || box.engine; size: 18 }
                                    Icon { anchors.centerIn: parent; visible: suggestion.modelData.kind === "suggest"; name: "search"; size: 15; color: theme.textDim }
                                    Favicon { anchors.centerIn: parent; visible: suggestion.modelData.kind === "url" || suggestion.modelData.kind === "history"; url: suggestion.modelData.url || suggestion.modelData.text; size: 16 }
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: suggestion.modelData.text
                                    textFormat: Text.PlainText
                                    elide: Text.ElideRight
                                    color: theme.text
                                    font.pixelSize: 14
                                }
                                Text {
                                    Layout.maximumWidth: suggestion.width * 0.4
                                    elide: Text.ElideMiddle
                                    color: theme.textFaint
                                    font.pixelSize: 11
                                    text: suggestion.modelData.kind === "search" ? "Rechercher avec " + (suggestion.modelData.engine || box.engine).name
                                        : suggestion.modelData.kind === "url" ? "Aller à l'adresse"
                                        : suggestion.modelData.kind === "history" ? (suggestion.modelData.url || "").replace(/^https?:\/\/(www\.)?/, "") : ""
                                }
                            }
                            MouseArea {
                                id: suggestionHover
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                                onClicked: (mouse) => box.go(suggestion.modelData, mouse.button === Qt.MiddleButton)
                            }
                        }
                    }
                }
            }

            // Engines at hand: one click searches (or will search) with that one.
            // Rows computed here so each one is centred (a Flow can't centre).
            Column {
                id: engineRows
                visible: page.opt("newtab/engines")
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: 14
                Layout.preferredWidth: Math.min(content.width, 760)
                spacing: 8
                readonly property var list: {
                    engines.revision
                    const keys = String(page.opt("newtab/engineKeys")).split(",").map(k => k.trim()).filter(k => k)
                    return keys.map(k => engines.engine(k)).filter(e => e && keys.indexOf(e.key) >= 0)
                }
                FontMetrics { id: chipFont; font.pixelSize: 12 }
                // Badge 16 + spacing 7 + margins 20, as the chip draws it.
                function chipWidth(e) { return Math.ceil(chipFont.advanceWidth(e.name)) + 16 + 7 + 20 }
                readonly property var rows: {
                    const room = Math.max(1, width)
                    const out = []
                    let row = [], used = 0
                    for (const e of list) {
                        const w = chipWidth(e)
                        const next = row.length ? used + spacing + w : w
                        if (row.length && next > room) { out.push(row); row = [e]; used = w }
                        else { row.push(e); used = next }
                    }
                    if (row.length) out.push(row)
                    return out
                }
                Repeater {
                    model: engineRows.rows
                    delegate: Row {
                        required property var modelData
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: 8
                        Repeater {
                            model: modelData
                            delegate: Rectangle {
                                required property var modelData
                                width: chipRow.implicitWidth + 20
                                height: 30
                                radius: 15
                                readonly property bool picked: box.engineKey === modelData.key
                                color: picked ? theme.alpha(theme.highlight, 0.16) : (engineHover.containsMouse ? theme.raised : theme.alpha(theme.surface, 0.7))
                                border.color: picked ? theme.highlight : theme.line
                                Row {
                                    id: chipRow
                                    anchors.centerIn: parent
                                    spacing: 7
                                    EngineBadge { anchors.verticalCenter: parent.verticalCenter; engine: modelData; size: 16 }
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.name; color: theme.textDim; font.pixelSize: 12 }
                                }
                                ToolTip.visible: engineHover.containsMouse && !!modelData.keyword
                                ToolTip.text: "Raccourci : « " + modelData.keyword + " » puis Espace"
                                ToolTip.delay: 600
                                MouseArea {
                                    id: engineHover
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    // With something typed: search it there; else pick
                                    // the engine for the next search.
                                    onClicked: {
                                        if (box.visible && box.query() !== "") { box.engineKey = modelData.key; box.go(null, false) }
                                        else if (box.visible) box.focusSearch(modelData.key)
                                        else if (page.win) page.win.focusAddress("", modelData.key)
                                    }
                                }
                            }

                        }
                    }
                }
            }

            // First run: choose the engine.
            Rectangle {
                visible: !page.isPrivate && !page.opt("search/chosen")
                Layout.fillWidth: true
                Layout.topMargin: 32
                Layout.preferredHeight: chooser.implicitHeight + 36
                radius: 16
                color: theme.surface
                border.color: theme.alpha(theme.highlight, 0.5)
                ColumnLayout {
                    id: chooser
                    anchors.fill: parent
                    anchors.margins: 18
                    spacing: 12
                    RowLayout {
                        spacing: 10
                        Icon { name: "search"; size: 18; color: theme.highlight }
                        Text { text: "Quel moteur de recherche veux-tu ?"; color: theme.text; font.pixelSize: 16; font.weight: Font.Bold }
                        Item { Layout.fillWidth: true }
                        Button { text: "Plus tard"; flat: true; onClicked: settings.set("search/chosen", true) }
                    }
                    Text {
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                        text: "Tu pourras en changer à tout moment, en ajouter d'autres et leur donner des raccourcis (« yt chats » cherche sur YouTube) dans Réglages → Recherche."
                        color: theme.textDim
                        font.pixelSize: 12
                    }
                    GridLayout {
                        Layout.fillWidth: true
                        columns: Math.max(2, Math.floor(chooser.width / 190))
                        columnSpacing: 8
                        rowSpacing: 8
                        Repeater {
                            model: (engines.revision, engines.all().filter(e => e.category === "web" || e.category === "ia"))
                            delegate: Rectangle {
                                required property var modelData
                                readonly property bool chosen: page.defaultEngine.key === modelData.key
                                Layout.fillWidth: true
                                Layout.preferredHeight: 44
                                radius: 10
                                color: chosen ? theme.alpha(theme.highlight, 0.14) : (pickHover.containsMouse ? theme.raised : theme.background)
                                border.color: chosen ? theme.highlight : theme.line
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 12
                                    spacing: 10
                                    EngineBadge { engine: modelData; size: 22 }
                                    ColumnLayout {
                                        spacing: 0
                                        Text { text: modelData.name; color: theme.text; font.pixelSize: 13; font.weight: Font.Medium }
                                        Text { text: modelData.category === "ia" ? "Réponses par IA" : (modelData.suggest ? "avec suggestions" : "sans suggestions"); color: theme.textFaint; font.pixelSize: 10 }
                                    }
                                }
                                MouseArea {
                                    id: pickHover
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        settings.set("search/engine", modelData.key)
                                        settings.set("search/chosen", true)
                                        if (page.win) page.win.flash("Moteur par défaut : " + modelData.name)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Shortcuts.
            GridLayout {
                id: grid
                visible: !page.isPrivate && page.opt("newtab/shortcuts")
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: 40
                readonly property int tile: 96
                columns: Math.max(2, Math.min(page.opt("newtab/columns"), Math.floor(content.width / (tile + 12))))
                columnSpacing: 12
                rowSpacing: 12
                Repeater {
                    model: (library.dialRevision, library.dial())
                    delegate: Rectangle {
                        id: tile
                        required property var modelData
                        required property int index
                        readonly property string shape: page.opt("newtab/tiles")
                        Layout.preferredWidth: grid.tile
                        Layout.preferredHeight: grid.tile
                        radius: 14
                        color: tileHover.containsMouse ? theme.alpha(theme.surface, 0.95) : theme.alpha(theme.surface, wallpaper.visible ? 0.75 : 0.0)
                        border.color: tileHover.containsMouse ? theme.line : "transparent"
                        Behavior on color { ColorAnimation { duration: 100 } }
                        Column {
                            anchors.centerIn: parent
                            spacing: 9
                            Rectangle {
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: 48; height: 48
                                radius: tile.shape === "circle" ? 24 : tile.shape === "square" ? 6 : 14
                                color: theme.surface
                                border.color: theme.line
                                Favicon { anchors.centerIn: parent; url: tile.modelData.url; size: 26 }
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: grid.tile - 10
                                horizontalAlignment: Text.AlignHCenter
                                text: tile.modelData.title
                                color: theme.text
                                font.pixelSize: 12
                                elide: Text.ElideRight
                            }
                        }
                        MouseArea {
                            id: tileHover
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                            onClicked: (mouse) => {
                                if (!page.win) return
                                if (mouse.button === Qt.RightButton) {
                                    const p = tile.mapToItem(null, mouse.x, mouse.y)
                                    page.win.menu.show([
                                        { text: "Ouvrir", icon: "arrowRight", run: () => page.owner.load(tile.modelData.url) },
                                        { text: "Ouvrir dans un nouvel onglet", icon: "plus", run: () => page.win.openTab(tile.modelData.url, { background: true }) },
                                        { text: "Ouvrir dans un onglet privé", icon: "mask", run: () => page.win.openTab(tile.modelData.url, { private: true }) },
                                        { separator: true },
                                        { text: "Modifier…", icon: "pencil", run: () => dialEditor.edit(tile.index, tile.modelData.url, tile.modelData.title) },
                                        { text: "Déplacer à gauche", icon: "arrowLeft", enabled: tile.index > 0, run: () => library.moveDial(tile.index, tile.index - 1) },
                                        { text: "Déplacer à droite", icon: "arrowRight", run: () => library.moveDial(tile.index, tile.index + 1) },
                                        { separator: true },
                                        { text: "Retirer", icon: "trash", danger: true, run: () => library.removeDial(tile.index) }
                                    ], p.x, p.y)
                                } else if (mouse.button === Qt.MiddleButton || (mouse.modifiers & Qt.ControlModifier)) {
                                    page.win.openTab(tile.modelData.url, { background: true })
                                } else {
                                    page.owner.load(tile.modelData.url)
                                }
                            }
                        }
                    }
                }
                // Add one.
                Rectangle {
                    Layout.preferredWidth: grid.tile
                    Layout.preferredHeight: grid.tile
                    radius: 14
                    color: addHover.containsMouse ? theme.alpha(theme.surface, 0.95) : "transparent"
                    border.color: addHover.containsMouse ? theme.line : "transparent"
                    Column {
                        anchors.centerIn: parent
                        spacing: 9
                        Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: 48; height: 48; radius: 14
                            color: "transparent"
                            border.color: theme.line
                            border.width: 1
                            Icon { anchors.centerIn: parent; name: "plus"; size: 20; color: theme.textDim }
                        }
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Ajouter"; color: theme.textDim; font.pixelSize: 12 }
                    }
                    MouseArea { id: addHover; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: dialEditor.edit(-1, "", "") }
                }
            }

            // Pick up where you were.
            ColumnLayout {
                id: recentBlock
                readonly property var items: (library.historyRevision, page.visible ? library.history("", 30) : [])
                    .filter(e => !/[?&](q|query|search_query|search)=/.test(e.url))
                    // One line per page: a redirect leaves two addresses with one title.
                    .filter((e, i, all) => all.findIndex(o => o.url === e.url || (e.title && o.title === e.title && o.host === e.host)) === i)
                    .slice(0, 4)
                visible: !page.isPrivate && page.opt("newtab/recent") && items.length > 0
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: 36
                Layout.preferredWidth: Math.min(content.width, 640)
                spacing: 6
                Text { text: "Reprendre"; color: theme.textFaint; font.pixelSize: 11; font.weight: Font.DemiBold; font.letterSpacing: 0.6; font.capitalization: Font.AllUppercase }
                Repeater {
                    model: recentBlock.items
                    delegate: Rectangle {
                        required property var modelData
                        Layout.fillWidth: true
                        height: 40
                        radius: 10
                        color: recentHover.containsMouse ? theme.surface : (wallpaper.visible ? theme.alpha(theme.surface, 0.6) : "transparent")
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 10
                            anchors.rightMargin: 12
                            spacing: 10
                            Favicon { url: modelData.url; size: 16 }
                            Text { Layout.fillWidth: true; text: modelData.title || modelData.url; color: theme.text; font.pixelSize: 13; elide: Text.ElideRight }
                            Text { text: modelData.host; color: theme.textFaint; font.pixelSize: 11 }
                        }
                        MouseArea { id: recentHover; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: page.owner.load(modelData.url) }
                    }
                }
            }
        }
    }

    // Customize.
    Rectangle {
        visible: !page.isPrivate
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 16
        width: customizeRow.implicitWidth + 22
        height: 32
        ToolTip.visible: customizeHover.containsMouse && page.width < 560
        ToolTip.text: "Personnaliser"
        ToolTip.delay: 500
        radius: 16
        color: customizeHover.containsMouse ? theme.raised : theme.alpha(theme.surface, 0.8)
        border.color: theme.line
        Row {
            id: customizeRow
            anchors.centerIn: parent
            spacing: 7
            Icon { anchors.verticalCenter: parent.verticalCenter; name: "brush"; size: 14; color: theme.textDim }
            Text { visible: page.width >= 560; anchors.verticalCenter: parent.verticalCenter; text: "Personnaliser"; color: theme.textDim; font.pixelSize: 12 }
        }
        MouseArea { id: customizeHover; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if (page.win) page.win.openSettings("newtab") }
    }

    // Adding or editing a shortcut.
    Dialog {
        id: dialEditor
        property int index: -1
        parent: Overlay.overlay
        anchors.centerIn: parent
        modal: true
        width: 440
        title: index < 0 ? "Ajouter un raccourci" : "Modifier le raccourci"
        background: Rectangle { color: theme.surface; radius: 14; border.color: theme.line }
        function edit(i, url, title) {
            index = i
            urlField.text = url
            titleField.text = title
            open()
            urlField.forceActiveFocus()
        }
        onAccepted: {
            const url = engines.isUrl(urlField.text) ? engines.fixUrl(urlField.text) : ""
            if (!url) return
            if (index < 0) library.addDial(url, titleField.text)
            else library.updateDial(index, url, titleField.text)
        }
        footer: DialogButtonBox {
            background: null
            Button { text: "Annuler"; flat: true; DialogButtonBox.buttonRole: DialogButtonBox.RejectRole }
            PrimaryButton { text: dialEditor.index < 0 ? "Ajouter" : "Enregistrer"; DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole }
        }
        ColumnLayout {
            anchors.fill: parent
            spacing: 8
            Text { text: "Adresse"; color: theme.textDim; font.pixelSize: 12 }
            TextField { id: urlField; Layout.fillWidth: true; placeholderText: "exemple.com"; onAccepted: dialEditor.accept() }
            Text { text: "Nom (facultatif)"; color: theme.textDim; font.pixelSize: 12 }
            TextField { id: titleField; Layout.fillWidth: true; placeholderText: "Le nom du site"; onAccepted: dialEditor.accept() }
        }
    }
}
