import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Ctrl+F: find in the page, with the count of matches.
Rectangle {
    id: bar
    property var tab: null
    visible: false
    width: 380
    height: 40
    radius: 10
    color: theme.surface
    border.color: theme.line

    function show() {
        if (!tab || !tab.view) return
        visible = true
        field.forceActiveFocus()
        field.selectAll()
        if (field.text) tab.find(field.text, false)
    }
    function close() {
        if (!visible) return
        visible = false
        if (tab) { tab.stopFind(); if (tab.view) tab.view.forceActiveFocus() }
    }
    function next(backward) {
        if (!visible) { show(); return }
        if (tab && field.text) tab.find(field.text, backward)
    }
    // Switching tabs: the highlights go from the tab that had them.
    property var searchedTab: null
    onTabChanged: {
        if (visible) {
            // (The tab may be closed already.)
            if (searchedTab && searchedTab !== tab) { try { searchedTab.stopFind() } catch (e) {} }
            visible = false
        }
        searchedTab = tab
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 12
        anchors.rightMargin: 6
        spacing: 4
        Icon { name: "search"; size: 14; color: theme.textFaint }
        Field {
            id: field
            Layout.fillWidth: true
            font.pixelSize: 13
            hint: "Rechercher dans la page"
            onTextChanged: if (bar.tab) bar.tab.find(text, false)
            Keys.onReturnPressed: (event) => bar.next(event.modifiers & Qt.ShiftModifier)
            Keys.onEscapePressed: bar.close()
        }
        Text {
            visible: field.text !== ""
            text: bar.tab && bar.tab.findResult.count > 0 ? bar.tab.findResult.active + " / " + bar.tab.findResult.count : "Aucun"
            color: bar.tab && bar.tab.findResult.count > 0 ? theme.textDim : theme.danger
            font.pixelSize: 12
            font.features: { "tnum": 1 }
        }
        IconButton { icon: "arrowUp"; tip: "Précédent (Maj+Entrée)"; onClicked: bar.next(true) }
        IconButton { icon: "arrowDown"; tip: "Suivant (Entrée)"; onClicked: bar.next(false) }
        IconButton { icon: "close"; tip: "Fermer (Échap)"; onClicked: bar.close() }
    }
}
