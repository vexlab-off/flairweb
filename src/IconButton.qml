import QtQuick
import QtQuick.Controls

// A square toolbar button with a line icon, a tooltip and an optional badge.
Rectangle {
    id: button
    property string icon
    property string tip
    property bool active: false
    property bool enabledButton: true
    property color iconColor: active ? theme.highlight : theme.textDim
    property real iconSize: 16
    property string badge: ""
    property real progress: -1   // 0..1 draws a ring under the icon
    signal clicked()
    signal rightClicked(var mouse)
    implicitWidth: 30
    implicitHeight: 30
    radius: 7
    opacity: enabledButton ? 1 : 0.35
    color: active ? theme.alpha(theme.highlight, 0.16) : (hit.containsMouse && enabledButton ? theme.raised : "transparent")
    Behavior on color { ColorAnimation { duration: 90 } }
    Icon { anchors.centerIn: parent; name: button.icon; size: button.iconSize; color: button.iconColor }
    Canvas {
        id: ring
        anchors.fill: parent
        anchors.margins: 3
        visible: button.progress >= 0
        property real value: button.progress
        onValueChanged: requestPaint()
        onPaint: {
            const ctx = getContext("2d")
            ctx.reset()
            ctx.lineWidth = 2
            ctx.strokeStyle = theme.alpha(theme.highlight, 0.25)
            ctx.beginPath(); ctx.arc(width / 2, height / 2, width / 2 - 1, 0, Math.PI * 2); ctx.stroke()
            ctx.strokeStyle = theme.highlight
            ctx.beginPath(); ctx.arc(width / 2, height / 2, width / 2 - 1, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * Math.max(0.02, value)); ctx.stroke()
        }
    }
    Rectangle {
        visible: button.badge !== ""
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 1
        height: 14
        width: Math.max(14, badgeText.implicitWidth + 6)
        radius: 7
        color: theme.highlight
        Text { id: badgeText; anchors.centerIn: parent; text: button.badge; color: theme.highlightText; font.pixelSize: 9; font.weight: Font.Bold }
    }
    ToolTip.visible: hit.containsMouse && tip !== ""
    ToolTip.text: tip
    ToolTip.delay: 500
    MouseArea {
        id: hit
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: (mouse) => {
            if (!button.enabledButton) return
            if (mouse.button === Qt.RightButton) button.rightClicked(mouse)
            else button.clicked()
        }
    }
}
