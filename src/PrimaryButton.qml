import QtQuick
import QtQuick.Controls

// The main action of a dialog or panel: filled with the accent colour.
Button {
    id: button
    font.pixelSize: 13
    font.weight: Font.DemiBold
    leftPadding: 16
    rightPadding: 16
    background: Rectangle {
        implicitWidth: 80
        implicitHeight: 34
        radius: 8
        color: !button.enabled ? theme.alpha(theme.highlight, 0.3)
             : button.down ? Qt.darker(theme.highlight, 1.15)
             : button.hovered ? Qt.lighter(theme.highlight, 1.08) : theme.highlight
    }
    contentItem: Text {
        text: button.text
        font: button.font
        color: button.enabled ? theme.highlightText : theme.alpha(theme.highlightText, 0.6)
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }
}
