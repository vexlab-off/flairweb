import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// A place (bookmark, history entry): its icon, title and a detail. Click
// opens it here, middle-click behind, right-click offers the rest.
Rectangle {
    id: row
    property var win: null
    property string url
    property string title
    property string detail
    property var extraMenu: []
    height: 34
    color: hit.containsMouse ? theme.alpha(theme.text, 0.05) : "transparent"
    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 14
        anchors.rightMargin: 12
        spacing: 10
        Favicon { url: row.url; size: 16 }
        Text { Layout.fillWidth: true; text: row.title; color: theme.text; font.pixelSize: 13; elide: Text.ElideRight }
        Text { text: row.detail; color: theme.textFaint; font.pixelSize: 11; Layout.maximumWidth: row.width * 0.35; elide: Text.ElideMiddle }
    }
    ToolTip.visible: hit.containsMouse
    ToolTip.text: row.url
    ToolTip.delay: 900
    MouseArea {
        id: hit
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
        onClicked: (mouse) => {
            if (mouse.button === Qt.RightButton) {
                const p = row.mapToItem(null, mouse.x, mouse.y)
                row.win.menu.show([
                    { text: "Ouvrir", icon: "arrowRight", run: () => row.win.openAddress(row.url, "here") },
                    { text: "Ouvrir dans un nouvel onglet", icon: "plus", run: () => row.win.openTab(row.url, { background: true }) },
                    { text: "Ouvrir dans un onglet privé", icon: "mask", run: () => row.win.openTab(row.url, { private: true }) },
                    { text: "Copier l'adresse", icon: "link", run: () => browser.copy(row.url) },
                    { text: "Ajouter aux raccourcis", icon: "grid", enabled: !library.inDial(row.url), run: () => library.addDial(row.url, row.title) },
                    { separator: true }
                ].concat(row.extraMenu), p.x, p.y)
            } else if (mouse.button === Qt.MiddleButton || (mouse.modifiers & Qt.ControlModifier)) {
                row.win.openTab(row.url, { background: true })
            } else {
                row.win.openAddress(row.url, "here")
            }
        }
    }
}
