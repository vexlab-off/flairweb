import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtQuick.Layouts
import QtWebEngine

// A window a page opened as a dialog (sign-in with Google, payment…): just
// the page and its address, which stays visible so you know who asks.
Window {
    id: popup
    property var appRoot: null
    property bool isPrivate: false
    width: 520
    height: 680
    color: theme.background
    title: (view.title || "Fenêtre") + " — Flair Web"

    function adopt(request) {
        const g = request.requestedGeometry
        if (g.width > 100 && g.height > 100) { width = g.width; height = g.height + 36 }
        request.openIn(view)
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 36
            color: theme.sidebar
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                spacing: 8
                Icon { name: view.url.toString().startsWith("https:") ? "lock" : "alert"; size: 13; color: view.url.toString().startsWith("https:") ? theme.textDim : theme.warning }
                Text { Layout.fillWidth: true; text: view.url.toString(); color: theme.textDim; font.pixelSize: 12; elide: Text.ElideMiddle }
            }
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: theme.line }
        }
        WebEngineView {
            id: view
            Layout.fillWidth: true
            Layout.fillHeight: true
            profile: popup.isPrivate ? browser.privateProfile : browser.profile
            onWindowCloseRequested: popup.close()
            onNewWindowRequested: (request) => {
                if (popup.appRoot && popup.appRoot.lastActive) popup.appRoot.lastActive.openFromRequest(request, null, popup.isPrivate)
            }
            onGeometryChangeRequested: (geometry) => { popup.width = geometry.width; popup.height = geometry.height + 36 }
        }
    }
    onClosing: Qt.callLater(popup.destroy)
}
