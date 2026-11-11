import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// The address bar: shows where you are, takes an address or a search, and
// suggests from the engine, your history, bookmarks and open tabs.
// "yt chats" or "!yt chats" searches YouTube; the badge on the left picks
// the engine for one search.
Rectangle {
    id: bar
    property var win: null
    readonly property var tab: win ? win.currentTab : null
    readonly property bool isPrivate: tab ? tab.isPrivate : false
    property string engineKey: ""       // chosen for this search only
    property var keyword: ({})          // a keyword typed at the start
    property var rows: []
    property int selected: -1
    property string lastTyped: ""
    property bool completing: false
    // Something was typed since the bar took the focus.
    property bool typed: false
    readonly property bool editing: field.activeFocus
    readonly property string defaultEngineKey: (settings.revision, settings.value(isPrivate ? "search/privateEngine" : "search/engine"))
    readonly property var activeEngine: (engines.revision, engines.engine(engineKey || keyword.engine || defaultEngineKey))
    function opt(key) { return settings.revision, settings.value(key) }

    implicitHeight: 34
    radius: Math.min(height / 2, opt("appearance/radius") + 6)
    color: editing ? theme.surface : (hover.containsMouse ? theme.alpha(theme.text, 0.075) : theme.alpha(theme.text, 0.05))
    border.color: editing ? theme.highlight : "transparent"
    border.width: editing ? 1.5 : 0
    Behavior on color { ColorAnimation { duration: 100 } }

    function displayUrl(url) {
        if (!url || url === "about:blank") return ""
        if (opt("toolbar/fullUrl")) return url
        return url.replace(/^https?:\/\//, "").replace(/^www\./, "").replace(/\/$/, "")
    }
    function resetText() {
        if (!editing) field.text = tab && !tab.isNewTab ? (opt("toolbar/fullUrl") ? tab.url : displayUrl(tab.url)) : ""
    }
    function focusWith(text, engine) {
        engineKey = engine || ""
        keyword = ({})
        field.forceActiveFocus()
        if (text !== undefined && text !== null && text !== "") {
            field.text = text
            field.cursorPosition = text.length
            refresh(true)
        } else {
            field.text = tab && !tab.isNewTab ? tab.url : ""
            field.selectAll()
            refresh(false)
        }
    }
    function blur() {
        popup.close()
        engineKey = ""
        keyword = ({})
        if (tab && tab.view) tab.view.forceActiveFocus(); else win.contentItem.forceActiveFocus()
        resetText()
    }

    // Another tab, with a page and nothing typed here: the bar steps aside.
    onTabChanged: {
        popup.close()
        if (editing && !typed && tab && !tab.isNewTab) blur(); else resetText()
    }
    Connections {
        target: bar.tab
        // A page opened from elsewhere (a shortcut on the new tab page, a
        // link) while the bar had the focus but nothing typed: the bar steps
        // aside and shows the address, with its buttons.
        function onUrlChanged() {
            if (bar.editing && !bar.typed && bar.tab && !bar.tab.isNewTab) bar.blur()
            else bar.resetText()
        }
    }
    Connections {
        target: engines
        function onSuggestionsReady(query, list) {
            if (!bar.editing || query !== bar.queryText()) return
            const known = new Set(bar.rows.map(r => (r.text || "").toLowerCase()))
            const extra = list.filter(s => !known.has(s.toLowerCase())).slice(0, bar.opt("search/maxSuggestions"))
                              .map(s => ({ kind: "suggest", text: s }))
            if (extra.length) bar.rows = bar.rows.filter(r => r.kind !== "suggest").concat(extra)
        }
    }

    function queryText() {
        return keyword.engine ? keyword.rest : field.text.trim()
    }

    // Builds the list for what is typed; engine suggestions arrive later.
    function refresh(typed) {
        const text = field.text
        if (!engineKey) {
            const km = engines.matchKeyword(text)
            // A keyword turns into a badge as soon as it is followed by a space.
            if (km.engine && !km.bang && km.rest === "" && text.endsWith(" ")) {
                engineKey = km.engine
                field.text = ""
                keyword = ({})
                rows = [{ kind: "hint", text: "Rechercher avec " + km.name }]
                selected = -1
                popup.open()
                return
            }
            keyword = km.engine && km.rest !== "" ? km : ({})
        }
        const q = queryText()
        if (q === "" && !engineKey) { rows = []; popup.close(); return }
        const list = []
        const engineName = activeEngine.name || "le moteur"
        const isUrl = !engineKey && !keyword.engine && engines.isUrl(text)
        if (isUrl) list.push({ kind: "url", text: engines.fixUrl(text), title: "Aller à l'adresse" })
        if (q !== "") list.push({ kind: "search", text: q, engine: activeEngine })
        if (!engineKey && !keyword.engine && q.length > 0) {
            // Open tabs first: no need to open a site twice.
            const lower = q.toLowerCase()
            let tabs = 0
            for (const t of win.tabs) {
                if (t === bar.tab || tabs >= 2) continue
                if ((t.title || "").toLowerCase().indexOf(lower) >= 0 || t.url.toLowerCase().indexOf(lower) >= 0) {
                    list.push({ kind: "tab", text: t.title, url: t.url, tabRef: t })
                    tabs++
                }
            }
            const seen = new Set(list.map(r => r.url))
            if (opt("search/bookmarkSuggestions"))
                for (const b of library.bookmarks(q).slice(0, 3))
                    if (!seen.has(b.url)) { seen.add(b.url); list.push({ kind: "bookmark", text: b.title, url: b.url }) }
            if (opt("search/historySuggestions"))
                for (const h of library.suggest(q, 5))
                    if (!seen.has(h.url)) { seen.add(h.url); list.push({ kind: "history", text: h.title || h.url, url: h.url }) }
            // Inline completion of a site you know.
            if (typed && text.length > lastTyped.length && field.cursorPosition === text.length && !/\s|\//.test(text)) {
                const top = list.find(r => r.kind === "history" || r.kind === "bookmark")
                if (top) {
                    const host = top.url.replace(/^https?:\/\//, "").replace(/^www\./, "").split("/")[0]
                    if (host.toLowerCase().startsWith(text.toLowerCase()) && host.length > text.length) {
                        completing = true
                        field.text = text + host.substring(text.length)
                        field.select(text.length, field.text.length)
                        completing = false
                    }
                }
            }
        }
        lastTyped = text
        rows = list
        selected = -1
        if (list.length) popup.open(); else popup.close()
        const suggestOn = isPrivate ? opt("search/privateSuggestions") : opt("search/suggestions")
        if (suggestOn && q !== "" && !isUrl) suggestTimer.restart()
    }
    Timer { id: suggestTimer; interval: 120; onTriggered: engines.suggest(bar.queryText(), bar.activeEngine.key) }

    // Enter: the selected row, or what is typed.
    function go(where) {
        const row = selected >= 0 ? rows[selected] : null
        if (row) { activate(row, where); return }
        let text = field.text.trim()
        if (text === "" && !engineKey) return
        let url
        if (engineKey) url = text === "" ? engines.homeUrl(engineKey) : engines.searchUrl(engineKey, text)
        else url = engines.resolve(text, defaultEngineKey).url
        finish(url, where, !engines.isUrl(text))
    }
    function activate(row, where) {
        if (row.kind === "tab") { popup.close(); win.selectTab(row.tabRef); blur(); return }
        if (row.kind === "hint") return
        if (row.kind === "suggest" || row.kind === "search") {
            const key = activeEngine.key
            finish(engines.searchUrl(key, row.text), where, true)
            return
        }
        finish(row.url || row.text, where, false)
    }
    function finish(url, where, isSearch) {
        popup.close()
        engineKey = ""
        keyword = ({})
        if (!url) return
        const target = where || (isSearch && opt("search/newTab") && tab && !tab.isNewTab ? "tab" : "here")
        win.openAddress(url, target)
        field.text = displayUrl(url)
        if (tab && tab.view) tab.view.forceActiveFocus()
    }

    MouseArea { id: hover; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 5
        anchors.rightMargin: 6
        spacing: 4

        // Left: the engine while typing, the site's security otherwise.
        Rectangle {
            Layout.preferredWidth: 26
            Layout.preferredHeight: 26
            radius: 13
            color: leftHover.containsMouse ? theme.raised : "transparent"
            EngineBadge {
                anchors.centerIn: parent
                visible: bar.editing || (bar.tab && bar.tab.isNewTab)
                engine: bar.activeEngine
                size: 18
            }
            Icon {
                anchors.centerIn: parent
                visible: !(bar.editing || (bar.tab && bar.tab.isNewTab))
                name: bar.isPrivate ? "mask" : bar.tab && bar.tab.security === "secure" ? "lock" : bar.tab && bar.tab.security === "file" ? "file" : bar.tab && bar.tab.security === "insecure" ? "alert" : "globe"
                size: 14
                color: bar.isPrivate ? "#9b7bff" : bar.tab && bar.tab.security === "insecure" ? theme.warning : theme.textDim
            }
            ToolTip.visible: leftHover.containsMouse
            ToolTip.text: bar.editing || (bar.tab && bar.tab.isNewTab) ? "Moteur : " + bar.activeEngine.name + " (clic pour changer)" : "Informations sur le site"
            ToolTip.delay: 500
            MouseArea {
                id: leftHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    if (bar.editing || (bar.tab && bar.tab.isNewTab)) bar.showEngineMenu(parent)
                    else siteInfo.toggle(parent)
                }
            }
            SiteInfo { id: siteInfo; win: bar.win }
        }

        // The keyword badge.
        Rectangle {
            visible: bar.engineKey !== ""
            Layout.preferredHeight: 24
            Layout.preferredWidth: chipText.implicitWidth + 30
            radius: 12
            color: theme.alpha(bar.activeEngine.color || theme.highlight, 0.18)
            border.color: theme.alpha(bar.activeEngine.color || theme.highlight, 0.5)
            Row {
                anchors.centerIn: parent
                spacing: 4
                Text { id: chipText; anchors.verticalCenter: parent.verticalCenter; text: bar.activeEngine.name || ""; color: theme.text; font.pixelSize: 12; font.weight: Font.DemiBold }
                Icon { anchors.verticalCenter: parent.verticalCenter; name: "close"; size: 10; color: theme.textDim }
            }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { bar.engineKey = ""; field.forceActiveFocus(); bar.refresh(false) } }
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Field {
                id: field
                anchors.fill: parent
                leftPadding: 4
                rightPadding: 4
                topPadding: 0
                bottomPadding: 0
                font.pixelSize: 13
                selectByMouse: true
                color: bar.editing ? theme.text : "transparent"
                hint: bar.editing || (bar.tab && bar.tab.isNewTab)
                    ? (bar.engineKey ? "Rechercher avec " + bar.activeEngine.name : "Rechercher avec " + bar.activeEngine.name + " ou saisir une adresse")
                    : ""
                verticalAlignment: TextInput.AlignVCenter
                onActiveFocusChanged: {
                    if (activeFocus) {
                        if (bar.tab && !bar.tab.isNewTab && text === bar.displayUrl(bar.tab.url)) text = bar.tab.url
                        Qt.callLater(selectAll)
                        bar.lastTyped = ""
                        bar.typed = false
                    } else {
                        popup.close()
                        Qt.callLater(bar.resetText)
                    }
                }
                onTextEdited: { bar.typed = true; if (!bar.completing) bar.refresh(true) }
                Keys.onPressed: (event) => {
                    if (event.key === Qt.Key_Down) { bar.selected = Math.min(bar.rows.length - 1, bar.selected + 1); if (bar.rows.length) popup.open(); event.accepted = true }
                    else if (event.key === Qt.Key_Up) { bar.selected = Math.max(-1, bar.selected - 1); event.accepted = true }
                    else if (event.key === Qt.Key_Escape) {
                        if (popup.opened) popup.close(); else bar.blur()
                        event.accepted = true
                    } else if (event.key === Qt.Key_Backspace && text === "" && bar.engineKey) {
                        bar.engineKey = ""; bar.refresh(false); event.accepted = true
                    } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
                        if (event.modifiers & Qt.ControlModifier && /^[\w-]+$/.test(text.trim())) text = "www." + text.trim() + ".com"
                        bar.go(event.modifiers & Qt.AltModifier ? "tab" : (event.modifiers & Qt.ShiftModifier ? "window" : ""))
                        event.accepted = true
                    } else if (event.key === Qt.Key_Delete && (event.modifiers & Qt.ShiftModifier) && bar.selected >= 0) {
                        const row = bar.rows[bar.selected]
                        if (row && row.kind === "history") { library.removeHistory(row.url); bar.refresh(false) }
                        event.accepted = true
                    } else if (event.key === Qt.Key_Tab && bar.rows.length) {
                        bar.selected = (bar.selected + 1) % bar.rows.length
                        event.accepted = true
                    }
                }
            }
            // The resting display: the site stands out, the rest is quieter.
            Text {
                anchors.fill: parent
                anchors.leftMargin: 4
                anchors.rightMargin: 4
                visible: !bar.editing && bar.tab !== null && !bar.tab.isNewTab
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
                textFormat: Text.StyledText
                font.pixelSize: 13
                color: theme.textDim
                text: {
                    if (!bar.tab) return ""
                    const url = bar.tab.url
                    const esc = s => s.replace(/&/g, "&amp;").replace(/</g, "&lt;")
                    const m = /^([a-z\-]+:\/\/)(www\.)?([^\/?#]*)(.*)$/i.exec(url)
                    if (!m) return esc(url)
                    if (bar.opt("toolbar/fullUrl"))
                        return esc(m[1] + (m[2] || "")) + "<font color='" + theme.text + "'>" + esc(m[3]) + "</font>" + esc(m[4])
                    const rest = m[4] === "/" ? "" : m[4]
                    return "<font color='" + theme.text + "'>" + esc(m[3]) + "</font>" + esc(rest)
                }
            }
        }

        // Right: what is going on with this page.
        Rectangle {
            visible: bar.tab !== null && bar.tab.started && Math.abs(bar.tab.zoom - bar.opt("web/zoom")) > 0.01 && !bar.editing
            Layout.preferredHeight: 22
            Layout.preferredWidth: zoomText.implicitWidth + 14
            radius: 11
            color: zoomHover.containsMouse ? theme.raised : theme.alpha(theme.text, 0.06)
            Text { id: zoomText; anchors.centerIn: parent; text: bar.tab ? Math.round(bar.tab.zoom * 100) + " %" : ""; color: theme.textDim; font.pixelSize: 11 }
            ToolTip.visible: zoomHover.containsMouse
            ToolTip.text: "Revenir au zoom par défaut (Ctrl+0)"
            MouseArea { id: zoomHover; anchors.fill: parent; hoverEnabled: true; onClicked: bar.tab.setZoom(bar.opt("web/zoom")) }
        }
        IconButton {
            // On an extension's page in the Chrome Web Store: install it here.
            readonly property string storeId: bar.tab && /^https:\/\/(chromewebstore\.google\.com|chrome\.google\.com\/webstore)\/detail\//.test(bar.tab.url)
                                              ? browser.storeExtensionId(bar.tab.url.split(/[?#]/)[0]) : ""
            visible: storeId !== "" && browser.extensionsSupported && !bar.editing
            implicitWidth: 26; implicitHeight: 26
            icon: "puzzle"; iconSize: 15
            iconColor: theme.highlight
            enabledButton: !browser.installing
            tip: "Ajouter cette extension à Flair Web"
            onClicked: browser.installFromStore(storeId)
        }
        IconButton {
            visible: bar.opt("toolbar/reader") && bar.tab !== null && bar.tab.started && !bar.editing
            implicitWidth: 26; implicitHeight: 26
            icon: "book"; iconSize: 15
            active: bar.tab !== null && bar.tab.readerOpen
            tip: "Mode lecture (F9)"
            onClicked: bar.tab.readerOpen = !bar.tab.readerOpen
        }
        IconButton {
            id: shieldButton
            visible: bar.opt("toolbar/shield") && bar.tab !== null && bar.tab.started && !bar.editing
            implicitWidth: 26; implicitHeight: 26
            readonly property bool off: (settings.revision, !shield.active() || shield.isAllowed(bar.tab ? bar.tab.url : ""))
            icon: off ? "shieldOff" : "shieldCheck"; iconSize: 15
            iconColor: off ? theme.textFaint : theme.success
            badge: !off && bar.tab && bar.tab.blocked > 0 ? (bar.tab.blocked > 99 ? "99+" : String(bar.tab.blocked)) : ""
            tip: siteInfo.opened ? "" : off ? "Bouclier désactivé sur ce site" : (bar.tab && bar.tab.blocked ? bar.tab.blocked + " pubs et traceurs bloqués" : "Bouclier actif")
            onClicked: siteInfo.toggle(shieldButton)
        }
        IconButton {
            visible: bar.tab !== null && !bar.tab.isNewTab && !bar.editing && !bar.isPrivate
            implicitWidth: 26; implicitHeight: 26
            readonly property bool marked: (library.bookmarksRevision, bar.tab ? library.isBookmarked(bar.tab.url) : false)
            icon: "star"; iconSize: 15
            iconColor: marked ? theme.highlight : theme.textDim
            tip: marked ? "Modifier le favori (Ctrl+D)" : "Ajouter aux favoris (Ctrl+D)"
            onClicked: bar.win.bookmarkCurrent()
        }
    }

    function showEngineMenu(anchor) {
        const list = [{ header: "Rechercher avec" }]
        const all = engines.all()
        for (const e of all) {
            if (e.category === "site" && list.length > 14) continue
            list.push({ text: e.name, engine: e,
                        shortcut: e.keyword || "", checked: e.key === bar.activeEngine.key,
                        run: ((k) => () => { bar.engineKey = k === bar.defaultEngineKey ? "" : k; field.forceActiveFocus(); bar.refresh(false) })(e.key) })
        }
        list.push({ separator: true })
        list.push({ text: "Gérer les moteurs…", icon: "sliders", run: () => bar.win.openSettings("search") })
        win.menu.showBelow(anchor, list, false)
    }

    // ------------------------------------------------------------ suggestions
    Popup {
        id: popup
        y: bar.height + 6
        x: -1
        width: bar.width + 2
        padding: 6
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
        focus: false
        background: Rectangle { color: theme.surface; radius: 12; border.color: theme.line }
        contentItem: ListView {
            id: list
            implicitHeight: contentHeight
            interactive: false
            model: bar.rows
            currentIndex: bar.selected
            delegate: Rectangle {
                id: rowItem
                required property var modelData
                required property int index
                width: ListView.view.width
                height: 36
                radius: 8
                color: index === bar.selected || rowHover.containsMouse ? theme.alpha(theme.highlight, 0.14) : "transparent"
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 12
                    spacing: 12
                    Item {
                        Layout.preferredWidth: 18
                        Layout.preferredHeight: 18
                        EngineBadge { anchors.centerIn: parent; visible: rowItem.modelData.kind === "search" || rowItem.modelData.kind === "hint"; engine: bar.activeEngine; size: 18 }
                        Icon { anchors.centerIn: parent; visible: rowItem.modelData.kind === "suggest"; name: "search"; size: 15; color: theme.textDim }
                        Favicon { anchors.centerIn: parent; visible: ["url", "history", "bookmark", "tab"].indexOf(rowItem.modelData.kind) >= 0; url: rowItem.modelData.url || rowItem.modelData.text; size: 16 }
                    }
                    Text {
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                        font.pixelSize: 13
                        color: theme.text
                        text: rowItem.modelData.kind === "search" ? rowItem.modelData.text
                            : rowItem.modelData.kind === "url" ? rowItem.modelData.text
                            : rowItem.modelData.text
                    }
                    Text {
                        Layout.maximumWidth: rowItem.width * 0.45
                        elide: Text.ElideMiddle
                        font.pixelSize: 11
                        color: theme.textFaint
                        text: {
                            const r = rowItem.modelData
                            if (r.kind === "search") return "Rechercher avec " + bar.activeEngine.name
                            if (r.kind === "url") return r.title
                            if (r.kind === "tab") return "Basculer vers l'onglet"
                            if (r.kind === "history" || r.kind === "bookmark") return (r.url || "").replace(/^https?:\/\/(www\.)?/, "")
                            if (r.kind === "hint") return "Tape ta recherche, Retour arrière pour annuler"
                            return ""
                        }
                    }
                    Icon {
                        visible: rowItem.modelData.kind === "bookmark" || rowItem.modelData.kind === "tab"
                        name: rowItem.modelData.kind === "bookmark" ? "star" : "tabs"
                        size: 13
                        color: theme.highlight
                    }
                }
                MouseArea {
                    id: rowHover
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                    onClicked: (mouse) => bar.activate(rowItem.modelData, mouse.button === Qt.MiddleButton ? "tab" : "")
                }
            }
        }
    }
}
