import QtQuick

// A search engine's mark: its bundled logo, else the icon of its site (for
// the engines you add), else its initials on its colour while that icon is
// on its way.
Item {
    id: badge
    property var engine: ({})
    property real size: 18
    implicitWidth: size
    implicitHeight: size

    readonly property string logo: engine ? ((theme.isDark ? engine.logoDark : engine.logo) || "") : ""
    // The site behind the engine: its search page's address.
    readonly property string siteUrl: engine && engine.url ? String(engine.url).replace("%s", "") : ""
    readonly property string siteIcon: logo === "" && /^https?:/.test(siteUrl) ? (favicons.revision, favicons.forUrl(siteUrl)) : ""
    readonly property string source: logo !== "" ? logo : siteIcon
    readonly property bool hasImage: image.status === Image.Ready

    Image {
        id: image
        anchors.fill: parent
        source: badge.source
        sourceSize: Qt.size(badge.size * 2, badge.size * 2)
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: true
        asynchronous: badge.logo === ""
        visible: badge.hasImage
    }

    Rectangle {
        anchors.fill: parent
        visible: !badge.hasImage
        radius: badge.size * 0.28
        color: badge.engine && badge.engine.color ? badge.engine.color : theme.raised
        readonly property string initials: {
            const name = badge.engine && badge.engine.name ? badge.engine.name : "?"
            const words = name.split(/[\s\-]+/).filter(w => w)
            if (words.length >= 2 && badge.size >= 22) return (words[0][0] + words[1][0]).toUpperCase()
            return name.charAt(0).toUpperCase()
        }
        Text {
            anchors.centerIn: parent
            text: parent.initials
            color: Qt.colorEqual(parent.color, "#f5c518") || Qt.colorEqual(parent.color, "#ffb319") || Qt.colorEqual(parent.color, "#83d0f2") || Qt.colorEqual(parent.color, "#a2a9b1") ? "#111111" : "white"
            font.pixelSize: badge.size * (parent.initials.length > 1 ? 0.42 : 0.56)
            font.weight: Font.Black
        }
    }
}
