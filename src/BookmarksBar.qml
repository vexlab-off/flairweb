import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The bookmarks bar: bookmarks outside folders as buttons, each folder as a
// menu, and what does not fit behind a chevron.
Rectangle {
    id: bookmarksBar
    property var win: null
    readonly property var all: (library.bookmarksRevision, library.bookmarks(""))
    readonly property var loose: all.filter(b => b.folder === "")
    readonly property var folderNames: (library.bookmarksRevision, library.folders())
    implicitHeight: 32
    color: theme.sidebar

    function itemsFor(list) {
        return list.map(b => ({ text: b.title, image: favicons.forUrl(b.url), icon: favicons.forUrl(b.url) ? "" : "globe",
                                run: () => win.openAddress(b.url, "here") }))
    }

    // More bookmarks than room: the ones cut off are behind a chevron.
    readonly property bool overflowing: row.implicitWidth > width - 20
    function hiddenItems() {
        const out = []
        for (let i = 0; i < looseRepeater.count; ++i) {
            const item = looseRepeater.itemAt(i)
            if (item && item.x + item.width > row.width) out.push(loose[i])
        }
        return out
    }
    RowLayout {
        id: row
        anchors.fill: parent
        anchors.leftMargin: 10
        anchors.rightMargin: bookmarksBar.overflowing ? 40 : 10
        spacing: 2
        clip: true
        Text {
            visible: bookmarksBar.all.length === 0
            text: "Ctrl+D ajoute la page aux favoris ; ils apparaissent ici."
            color: theme.textFaint
            font.pixelSize: 11
        }
        Repeater {
            model: bookmarksBar.folderNames
            delegate: BarButton {
                id: folderButton
                required property string modelData
                label: modelData
                folder: true
                onClicked: bookmarksBar.win.menu.showBelow(folderButton, bookmarksBar.itemsFor(bookmarksBar.all.filter(b => b.folder === folderButton.modelData)), false)
            }
        }
        Repeater {
            id: looseRepeater
            model: bookmarksBar.loose
            delegate: BarButton {
                required property var modelData
                label: modelData.title
                url: modelData.url
                onClicked: bookmarksBar.win.openAddress(modelData.url, "here")
                onMiddleClicked: bookmarksBar.win.openTab(modelData.url, { background: true })
                onRightClicked: (x, y) => bookmarksBar.win.menu.show([
                    { text: "Ouvrir dans un nouvel onglet", icon: "plus", run: () => bookmarksBar.win.openTab(modelData.url, { background: true }) },
                    { text: "Ouvrir dans un onglet privé", icon: "mask", run: () => bookmarksBar.win.openTab(modelData.url, { private: true }) },
                    { text: "Modifier…", icon: "pencil", run: () => bookmarksBar.win.editBookmark(modelData.url) },
                    { text: "Copier l'adresse", icon: "link", run: () => browser.copy(modelData.url) },
                    { separator: true },
                    { text: "Retirer", icon: "trash", danger: true, run: () => library.removeBookmark(modelData.url) }
                ], x, y)
            }
        }
        Item { Layout.fillWidth: true }
    }
    IconButton {
        id: chevron
        visible: bookmarksBar.overflowing
        anchors.right: parent.right
        anchors.rightMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        implicitWidth: 26; implicitHeight: 24
        icon: "chevron"; iconSize: 13
        tip: "Autres favoris"
        onClicked: {
            const hidden = bookmarksBar.hiddenItems()
            if (hidden.length) bookmarksBar.win.menu.showBelow(chevron, bookmarksBar.itemsFor(hidden), true)
        }
    }
    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: theme.alpha(theme.line, 0.6) }

    component BarButton: Rectangle {
        id: button
        property string label
        property string url: ""
        property bool folder: false
        signal clicked()
        signal middleClicked()
        signal rightClicked(real x, real y)
        Layout.preferredHeight: 26
        Layout.preferredWidth: Math.min(180, row.implicitWidth + 16)
        radius: 6
        color: hit.containsMouse ? theme.raised : "transparent"
        Row {
            id: row
            anchors.verticalCenter: parent.verticalCenter
            x: 8
            spacing: 6
            Icon { visible: button.folder; anchors.verticalCenter: parent.verticalCenter; name: "folder"; size: 14; color: theme.kindColor("dossier") }
            Favicon { visible: !button.folder; anchors.verticalCenter: parent.verticalCenter; url: button.url; size: 14 }
            Text { anchors.verticalCenter: parent.verticalCenter; text: button.label; color: theme.textDim; font.pixelSize: 12; elide: Text.ElideRight; width: Math.min(implicitWidth, 140) }
        }
        ToolTip.visible: hit.containsMouse && button.url !== ""
        ToolTip.text: button.label + "\n" + button.url
        ToolTip.delay: 800
        MouseArea {
            id: hit
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
            onClicked: (mouse) => {
                if (mouse.button === Qt.MiddleButton) button.middleClicked()
                else if (mouse.button === Qt.RightButton) { const p = button.mapToItem(null, mouse.x, mouse.y); button.rightClicked(p.x, p.y) }
                else button.clicked()
            }
        }
    }
}
