import QtQuick
import QtQuick.Controls

// A rounded choice: text, an optional icon or swatch, chosen or not.
Rectangle {
    id: chip
    property string text
    property string icon: ""
    property bool chosen: false
    property color swatch: "transparent"
    signal clicked()
    implicitWidth: row.implicitWidth + 22
    implicitHeight: 30
    radius: height / 2
    color: chosen ? theme.alpha(theme.highlight, 0.16) : (hit.containsMouse ? theme.raised : "transparent")
    border.color: chosen ? theme.highlight : theme.line
    Row {
        id: row
        anchors.centerIn: parent
        spacing: 7
        Rectangle {
            visible: chip.swatch.a > 0
            anchors.verticalCenter: parent.verticalCenter
            width: 12; height: 12; radius: 6
            color: chip.swatch
            border.color: theme.line
        }
        Icon {
            visible: chip.icon !== ""
            anchors.verticalCenter: parent.verticalCenter
            name: chip.icon
            size: 14
            color: chip.chosen ? theme.highlight : theme.textDim
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: chip.text
            color: theme.text
            font.pixelSize: 12
        }
    }
    MouseArea { id: hit; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: chip.clicked() }
}
