import QtQuick

// A site's icon: the one the tab reported, else the cached one (fetched
// from the site), else a neutral globe while there is none.
Item {
    id: favicon
    property string url
    property string source: ""
    property real size: 16
    property bool loading: false
    readonly property string host: {
        const m = /^[a-z]+:\/\/(?:www\.)?([^\/:?#]+)/i.exec(url || "")
        return m ? m[1].toLowerCase() : ""
    }
    // A site with a bundled logo (the engines' sites) uses it, in the
    // variant that reads on the theme; others, the icon fetched from them.
    readonly property string bundled: host !== "" ? engines.logoForUrl(url, theme.isDark) : ""
    readonly property string cached: bundled !== "" ? bundled : (favicons.revision, host !== "" ? favicons.forUrl(url) : "")
    // The tab's own icon failed to load: the cached one takes over.
    property bool ownFailed: false
    onSourceChanged: ownFailed = false
    implicitWidth: size
    implicitHeight: size

    Image {
        id: image
        anchors.fill: parent
        source: favicon.bundled !== "" ? favicon.bundled : (favicon.source !== "" && !favicon.ownFailed ? favicon.source : favicon.cached)
        onStatusChanged: if (status === Image.Error && favicon.source !== "" && !favicon.ownFailed) favicon.ownFailed = true
        sourceSize: Qt.size(favicon.size * 2, favicon.size * 2)
        fillMode: Image.PreserveAspectFit
        smooth: true
        asynchronous: true
        visible: status === Image.Ready && !favicon.loading
    }
    Icon {
        anchors.centerIn: parent
        visible: image.status !== Image.Ready && !favicon.loading
        name: (favicon.url || "").startsWith("file:") ? "file" : "globe"
        size: favicon.size * 0.85
        color: theme.textDim
    }
    // A spinner while the page loads.
    Item {
        anchors.fill: parent
        visible: favicon.loading
        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: "transparent"
            border.width: Math.max(1.5, favicon.size / 9)
            border.color: theme.alpha(theme.highlight, 0.25)
        }
        Canvas {
            id: arc
            anchors.fill: parent
            onPaint: {
                const ctx = getContext("2d")
                ctx.reset()
                ctx.lineWidth = Math.max(1.5, favicon.size / 9)
                ctx.lineCap = "round"
                ctx.strokeStyle = theme.highlight
                ctx.beginPath()
                ctx.arc(width / 2, height / 2, width / 2 - ctx.lineWidth / 2, 0, Math.PI * 0.6)
                ctx.stroke()
            }
        }
        RotationAnimator on rotation { from: 0; to: 360; duration: 800; loops: Animation.Infinite; running: favicon.loading }
    }
}
