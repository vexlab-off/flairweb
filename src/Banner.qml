import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// A strip above the page that asks something or warns: an icon, a sentence
// and a few buttons ({text, run, primary}).
Rectangle {
    id: banner
    property string icon: "info"
    property string text
    property string tone: "info"   // "info", "danger"
    property var actions: []
    signal dismissed()
    readonly property color toneColor: tone === "danger" ? theme.danger : theme.highlight
    implicitHeight: visible ? row.implicitHeight + 16 : 0
    color: theme.alpha(toneColor, theme.isDark ? 0.12 : 0.10)
    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: theme.alpha(banner.toneColor, 0.35) }
    RowLayout {
        id: row
        anchors.fill: parent
        anchors.leftMargin: 14
        anchors.rightMargin: 10
        spacing: 12
        Icon { name: banner.icon; size: 17; color: banner.toneColor }
        Text {
            Layout.fillWidth: true
            text: banner.text
            textFormat: Text.StyledText
            color: theme.text
            font.pixelSize: 13
            wrapMode: Text.Wrap
        }
        Repeater {
            model: banner.actions
            delegate: Loader {
                required property var modelData
                sourceComponent: modelData.primary ? primaryButton : flatButton
                Component { id: primaryButton; PrimaryButton { text: modelData.text; onClicked: modelData.run() } }
                Component { id: flatButton; Button { text: modelData.text; flat: true; onClicked: modelData.run() } }
            }
        }
    }
}
