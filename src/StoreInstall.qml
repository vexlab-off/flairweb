import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Paste a Chrome Web Store link (or an extension id) and install it.
RowLayout {
    id: box
    property var win: null
    spacing: 6
    function submit() {
        if (field.text.trim() === "" || browser.installing) return
        browser.installFromStore(field.text)
        field.text = ""
    }
    Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: 34
        radius: 8
        color: theme.alpha(theme.text, 0.05)
        border.color: field.activeFocus ? theme.highlight : theme.line
        Field {
            id: field
            anchors.fill: parent
            leftPadding: 10; rightPadding: 10; topPadding: 0; bottomPadding: 0
            font.pixelSize: 12
            hint: "Lien du Chrome Web Store…"
            onAccepted: box.submit()
        }
    }
    PrimaryButton {
        text: browser.installing ? "…" : "Ajouter"
        enabled: !browser.installing
        onClicked: box.submit()
    }
}
