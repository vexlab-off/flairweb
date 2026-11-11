import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import QtWebEngine

// The extensions menu (each extension, adding one from the Chrome Web
// Store) and an extension's own popup, sized to its page like Chrome does.
Popup {
    id: popup
    property var win: null
    property string popupUrl: ""
    property string extensionId: ""
    property var anchorItem: null
    // The page's natural size, once it has laid out.
    property real pageWidth: 0
    property real pageHeight: 0
    parent: Overlay.overlay
    width: popupUrl ? Math.max(160, Math.min(800, pageWidth || 220)) : 340
    // Never past the bottom of the window: what doesn't fit scrolls.
    readonly property real room: parent ? Math.max(120, parent.height - y - 8) : 600
    height: Math.min(room, popupUrl ? Math.max(60, Math.min(600, pageHeight || 100)) : Math.min(460, column.implicitHeight + 24))
    padding: popupUrl ? 0 : 10
    background: Rectangle { color: popup.popupUrl ? "white" : theme.surface; radius: 12; border.color: theme.line; clip: true }
    onClosed: { popupUrl = ""; extensionId = ""; pageWidth = 0; pageHeight = 0 }
    onWidthChanged: place()

    function place() {
        if (!anchorItem || !parent) return
        const p = anchorItem.mapToItem(parent, anchorItem.width, anchorItem.height + 6)
        x = Math.max(8, Math.min(parent.width - width - 8, p.x - width))
        y = p.y
    }
    function showMenu(anchor) {
        popupUrl = ""
        anchorItem = anchor
        place()
        open()
    }
    function showPopup(ext, url, anchor) {
        extensionId = ext
        pageWidth = 0
        pageHeight = 0
        popupUrl = url
        anchorItem = anchor
        place()
        open()
    }

    contentItem: Item {
        Flickable {
            anchors.fill: parent
            visible: popup.popupUrl === ""
            clip: true
            contentHeight: column.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
        ColumnLayout {
            id: column
            width: popup.availableWidth
            spacing: 2
            Repeater {
                model: browser.extensions.filter(e => e.installed)
                delegate: Rectangle {
                    required property var modelData
                    Layout.fillWidth: true
                    height: 40
                    radius: 8
                    color: extHover.containsMouse ? theme.raised : "transparent"
                    opacity: modelData.enabled ? 1 : 0.5
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 6
                        spacing: 10
                        Item {
                            Layout.preferredWidth: 18; Layout.preferredHeight: 18
                            Image { anchors.fill: parent; source: modelData.icon || ""; sourceSize: Qt.size(36, 36); visible: status === Image.Ready; mipmap: true }
                            Icon { anchors.centerIn: parent; visible: !modelData.icon; name: "puzzle"; size: 16; color: modelData.error ? theme.danger : theme.highlight }
                        }
                        Text { Layout.fillWidth: true; text: modelData.name || modelData.id; color: theme.text; font.pixelSize: 13; elide: Text.ElideRight }
                        Icon { visible: !!modelData.popup; name: "chevron"; size: 13; color: theme.textFaint }
                    }
                    MouseArea {
                        id: extHover
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: {
                            if (!modelData.enabled) { popup.close(); popup.win.openSettings("extensions"); return }
                            const hub = popup.win.appRoot.extensions
                            const url = hub.popupFor(modelData.id, popup.win.currentTab)
                            if (url) { popup.extensionId = modelData.id; popup.pageWidth = 0; popup.pageHeight = 0; popup.popupUrl = url }
                            else { popup.close(); hub.actionClicked(modelData.id, popup.win, null) }
                        }
                    }
                }
            }
            Text {
                visible: !browser.extensions.some(e => e.installed)
                Layout.fillWidth: true
                Layout.margins: 6
                text: "<b>Aucune extension.</b> Sur le Chrome Web Store, le bouton « Ajouter à Flair Web » de chaque extension l'installe. Tu peux aussi coller son lien ici."
                textFormat: Text.StyledText
                wrapMode: Text.Wrap
                color: theme.textDim
                font.pixelSize: 12
            }
            StoreInstall { Layout.fillWidth: true; Layout.leftMargin: 4; Layout.rightMargin: 4; win: popup.win }
            Rectangle { Layout.fillWidth: true; Layout.topMargin: 4; height: 1; color: theme.line }
            RowLayout {
                Layout.fillWidth: true
                spacing: 0
                Button { Layout.fillWidth: true; text: "Chrome Web Store"; flat: true; onClicked: { popup.close(); popup.win.openTab("https://chromewebstore.google.com/", {}) } }
                Button { Layout.fillWidth: true; text: "Gérer…"; flat: true; onClicked: { popup.close(); popup.win.openSettings("extensions") } }
            }
        }
        }
        Loader {
            anchors.fill: parent
            active: popup.popupUrl !== ""
            sourceComponent: WebEngineView {
                profile: browser.profile
                url: popup.popupUrl
                backgroundColor: "white"
                // Grow to the page's own size (never shrink: that would loop).
                onContentsSizeChanged: {
                    if (contentsSize.width > popup.pageWidth) popup.pageWidth = Math.ceil(contentsSize.width)
                    if (contentsSize.height > popup.pageHeight) popup.pageHeight = Math.ceil(contentsSize.height)
                }
                onNewWindowRequested: (request) => { popup.win.openFromRequest(request, null, false); popup.close() }
                onWindowCloseRequested: popup.close()
                onContextMenuRequested: (request) => { request.accepted = false }
                onJavaScriptConsoleMessage: (level, message, line, source) => { if (browser.traceExtensions) console.log("[popup]", level, message, source + ":" + line) }
            }
        }
    }
}
