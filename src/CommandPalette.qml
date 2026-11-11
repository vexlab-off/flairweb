import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Ctrl+Maj+P: every command, searchable, with its shortcut and what it does,
// plus the open tabs and matching bookmarks.
Popup {
    id: palette
    property var win: null
    property var results: []

    modal: true
    focus: true
    x: (parent.width - width) / 2
    y: 70
    width: Math.min(parent.width - 80, 680)
    height: Math.min(parent.height - 140, column.implicitHeight + 16)
    padding: 8
    Overlay.modal: Rectangle { color: theme.alpha(theme.background, 0.5) }
    background: Rectangle { color: theme.surface; radius: 12; border.color: theme.line }

    function show(prefix) {
        field.text = prefix || ""
        filter()
        open()
        field.forceActiveFocus()
    }

    function score(query, item) {
        if (!query) return 1
        const hay = (item.name + " " + item.description + " " + item.category).toLowerCase()
        const words = query.toLowerCase().split(/\s+/).filter(w => w)
        let s = 0
        for (const w of words) {
            const i = hay.indexOf(w)
            if (i < 0) return -1
            s += item.name.toLowerCase().startsWith(w) ? 30 : (i < item.name.length ? 15 : 5)
        }
        return s
    }

    function filter() {
        const q = field.text.trim()
        const items = win.commands.slice()
        for (const t of win.tabs)
            items.push({ id: "tab", category: "Onglets ouverts", name: t.title, description: t.url || "Nouvel onglet",
                         shortcut: "", run: ((tab) => () => win.selectTab(tab))(t) })
        if (q.length > 1)
            for (const b of library.bookmarks(q).slice(0, 6))
                items.push({ id: "bookmark", category: "Favoris", name: b.title, description: b.url, shortcut: "",
                             run: ((u) => () => win.openAddress(u, "here"))(b.url) })
        const scored = []
        for (const c of items) {
            if (c.enabled && !c.enabled()) continue
            const s = score(q, c)
            if (s >= 0) scored.push({ s: s, c: c })
        }
        // Without a query, commands keep their order and tabs come first.
        if (q) scored.sort((a, b) => b.s - a.s)
        else scored.sort((a, b) => (a.c.id === "tab" ? 0 : 1) - (b.c.id === "tab" ? 0 : 1))
        results = scored.slice(0, 100).map(x => x.c)
        list.currentIndex = 0
    }

    function accept() {
        const item = results[list.currentIndex]
        if (!item) return
        close()
        Qt.callLater(item.run)
    }

    ColumnLayout {
        id: column
        anchors.fill: parent
        spacing: 6
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Icon { name: "sparkle"; size: 15; color: theme.highlight; Layout.leftMargin: 6 }
            TextField {
                id: field
                Layout.fillWidth: true
                placeholderText: "Que veux-tu faire ? (« privé », « zoom », « lecture », un onglet, un favori…)"
                background: null
                font.pixelSize: 14
                onTextChanged: palette.filter()
                onAccepted: palette.accept()
                Keys.onDownPressed: list.incrementCurrentIndex()
                Keys.onUpPressed: list.decrementCurrentIndex()
                Keys.onEscapePressed: palette.close()
            }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: theme.line }
        ListView {
            id: list
            Layout.fillWidth: true
            // Room for the "nothing matches" line when the list is empty.
            Layout.preferredHeight: count > 0 ? Math.min(contentHeight, 460) : 56
            clip: true
            model: palette.results
            highlightMoveDuration: 0
            delegate: Rectangle {
                required property var modelData
                required property int index
                width: ListView.view.width
                height: 46
                radius: 7
                color: ListView.isCurrentItem ? theme.alpha(theme.highlight, 0.14) : (hit.containsMouse ? theme.raised : "transparent")
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    spacing: 12
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1
                        RowLayout {
                            spacing: 8
                            Text { text: modelData.name; color: theme.text; font.pixelSize: 13; font.weight: Font.Medium }
                            Text { text: modelData.category; color: theme.textFaint; font.pixelSize: 10 }
                        }
                        Text {
                            Layout.fillWidth: true
                            text: modelData.description
                            color: theme.textDim
                            font.pixelSize: 11
                            elide: Text.ElideRight
                        }
                    }
                    Keycap { visible: !!modelData.shortcut; text: modelData.shortcut || "" }
                }
                MouseArea { id: hit; anchors.fill: parent; hoverEnabled: true; onClicked: { list.currentIndex = index; palette.accept() } }
            }
            Text {
                anchors.centerIn: parent
                visible: list.count === 0
                text: "Aucune commande ne correspond."
                color: theme.textFaint
            }
        }
    }
}
