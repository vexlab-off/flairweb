import QtQuick
import QtQuick.Window
import QtWebEngine

// A bare window for an extension page: windows.create({type: "popup"}) or
// a sign-in flow (identity.launchWebAuthFlow).
Window {
    id: w
    property int windowId: 0
    property int tabId: 0
    readonly property string currentUrl: view.url.toString()
    readonly property bool loading: view.loading
    signal addressChanged(string url)
    function load(url) { view.url = url }
    color: theme.surface
    title: view.title || "Flair Web"
    WebEngineView {
        id: view
        anchors.fill: parent
        profile: browser.profile
        onUrlChanged: w.addressChanged(url.toString())
        onWindowCloseRequested: w.close()
        onNewWindowRequested: (request) => {
            const target = appRoot.lastActive
            if (target) target.openFromRequest(request, null)
        }
    }
    property var appRoot: null
}
