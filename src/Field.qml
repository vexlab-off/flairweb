import QtQuick
import QtQuick.Controls

// A bare text field (no frame, no floating label) with its own quiet hint,
// for fields that sit inside a drawn box.
TextField {
    id: field
    property string hint: ""
    background: null
    placeholderText: ""
    Text {
        anchors.fill: parent
        anchors.leftMargin: field.leftPadding
        anchors.rightMargin: field.rightPadding
        anchors.topMargin: field.topPadding
        anchors.bottomMargin: field.bottomPadding
        verticalAlignment: Text.AlignVCenter
        visible: field.text === "" && field.preeditText === ""
        text: field.hint
        color: theme.textFaint
        font: field.font
        elide: Text.ElideRight
    }
}
