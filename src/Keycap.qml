import QtQuick

// A key as it reads on the keyboard, for hints next to actions.
Rectangle {
    property alias text: label.text
    implicitWidth: Math.max(18, label.implicitWidth + 10)
    implicitHeight: 18
    radius: 4
    color: theme.raised
    border.color: theme.line
    border.width: 1

    Text {
        id: label
        anchors.centerIn: parent
        color: theme.textDim
        font.pixelSize: 10
        font.weight: Font.Medium
    }
}
