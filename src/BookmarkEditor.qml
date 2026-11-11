import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Editing a bookmark: its name, address and folder (empty: the bar).
Dialog {
    id: editor
    property var win: null
    property string url: ""
    parent: Overlay.overlay
    anchors.centerIn: parent
    modal: true
    width: 460
    title: "Modifier le favori"
    background: Rectangle { color: theme.surface; radius: 14; border.color: theme.line }

    function edit(address) {
        const b = library.bookmark(address)
        if (!b.url) return
        url = address
        titleField.text = b.title
        urlField.text = b.url
        folderField.editText = b.folder || ""
        folderField.model = [""].concat(library.folders())
        folderField.editText = b.folder || ""
        open()
        titleField.forceActiveFocus()
        titleField.selectAll()
    }
    onAccepted: library.editBookmark(url, titleField.text, urlField.text, folderField.editText)

    footer: DialogButtonBox {
        background: null
        Button {
            text: "Retirer"
            flat: true
            DialogButtonBox.buttonRole: DialogButtonBox.DestructiveRole
            onClicked: { library.removeBookmark(editor.url); editor.close(); editor.win.flash("Favori retiré.") }
        }
        Button { text: "Annuler"; flat: true; DialogButtonBox.buttonRole: DialogButtonBox.RejectRole }
        PrimaryButton { text: "Enregistrer"; DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole }
    }
    ColumnLayout {
        anchors.fill: parent
        spacing: 6
        Text { text: "Nom"; color: theme.textDim; font.pixelSize: 12 }
        TextField { id: titleField; Layout.fillWidth: true; onAccepted: editor.accept() }
        Text { text: "Adresse"; color: theme.textDim; font.pixelSize: 12 }
        TextField { id: urlField; Layout.fillWidth: true; onAccepted: editor.accept() }
        Text { text: "Dossier (vide : la barre de favoris)"; color: theme.textDim; font.pixelSize: 12 }
        ComboBox { id: folderField; Layout.fillWidth: true; editable: true; model: [""] }
    }
}
