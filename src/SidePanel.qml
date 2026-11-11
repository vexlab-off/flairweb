import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import QtQuick.Dialogs
import QtWebEngine

// The panel on the right: bookmarks, history, downloads and the page
// assistant, one at a time.
Rectangle {
    id: panel
    property var win: null
    readonly property string section: win ? win.panelSection : "bookmarks"
    property string query: ""
    color: theme.sidebar
    function opt(key) { return settings.revision, settings.value(key) }

    readonly property var sections: [
        { key: "bookmarks", label: "Favoris", icon: "star", shortcut: "Ctrl+Maj+O" },
        { key: "history", label: "Historique", icon: "clock", shortcut: "Ctrl+H" },
        { key: "downloads", label: "Téléchargements", icon: "download", shortcut: "Ctrl+J" },
        { key: "assistant", label: "Assistant", icon: "sparkle", shortcut: "Ctrl+Maj+A" }
    ]
    onSectionChanged: query = ""
    // Opens the assistant and asks it something about the page.
    function ask(prompt) {
        win.panelSection = "assistant"
        assistantPanel.send(prompt)
    }

    function dayLabel(ms) {
        const d = new Date(ms), today = new Date()
        const start = new Date(today.getFullYear(), today.getMonth(), today.getDate()).getTime()
        if (ms >= start) return "Aujourd'hui"
        if (ms >= start - 86400000) return "Hier"
        if (ms >= start - 6 * 86400000) return d.toLocaleDateString(Qt.locale("fr_FR"), "dddd")
        return d.toLocaleDateString(Qt.locale("fr_FR"), "d MMMM yyyy")
    }

    Rectangle { anchors.left: parent.left; width: 1; height: parent.height; color: theme.line }

    ColumnLayout {
        anchors.fill: parent
        anchors.leftMargin: 1
        spacing: 0

        // Section tabs.
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 44
            Layout.leftMargin: 8
            Layout.rightMargin: 6
            spacing: 2
            Repeater {
                model: panel.sections
                delegate: IconButton {
                    required property var modelData
                    icon: modelData.icon
                    active: panel.section === modelData.key
                    tip: modelData.label + " (" + modelData.shortcut + ")"
                    onClicked: panel.win.panelSection = modelData.key
                }
            }
            Text {
                Layout.fillWidth: true
                Layout.leftMargin: 6
                text: panel.sections.find(s => s.key === panel.section).label
                color: theme.text
                font.pixelSize: 14
                font.weight: Font.Bold
                elide: Text.ElideRight
            }
            IconButton { icon: "close"; tip: "Fermer le panneau"; onClicked: panel.win.panelOpen = false }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: theme.line }

        // Search within bookmarks and history.
        Rectangle {
            visible: panel.section === "bookmarks" || panel.section === "history"
            Layout.fillWidth: true
            Layout.margins: 10
            Layout.preferredHeight: 32
            radius: 8
            color: theme.surface
            border.color: search.activeFocus ? theme.highlight : theme.line
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                spacing: 6
                Icon { name: "search"; size: 14; color: theme.textFaint }
                Field {
                    id: search
                    Layout.fillWidth: true
                    font.pixelSize: 13
                    hint: panel.section === "bookmarks" ? "Chercher dans les favoris" : "Chercher dans l'historique"
                    text: panel.query
                    onTextEdited: panel.query = text
                    Keys.onEscapePressed: panel.query = ""
                }
            }
        }

        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: ["bookmarks", "history", "downloads", "assistant"].indexOf(panel.section)

            // ---------------------------------------------- bookmarks
            ColumnLayout {
                spacing: 0
                ListView {
                    id: bookmarkList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: {
                        library.bookmarksRevision
                        const list = library.bookmarks(panel.query)
                        // Bar first, then folders by name.
                        return list.sort((a, b) => a.folder === b.folder ? a.index - b.index : a.folder === "" ? -1 : b.folder === "" ? 1 : a.folder.localeCompare(b.folder))
                    }
                    ScrollBar.vertical: ScrollBar {}
                    delegate: Column {
                        id: bmRow
                        required property var modelData
                        required property int index
                        width: ListView.view.width
                        readonly property bool header: index === 0 || bookmarkList.model[index - 1].folder !== modelData.folder
                        Text {
                            visible: bmRow.header
                            leftPadding: 16; topPadding: 10; bottomPadding: 4
                            text: bmRow.modelData.folder === "" ? "Barre de favoris" : bmRow.modelData.folder
                            color: theme.textFaint
                            font.pixelSize: 10; font.weight: Font.DemiBold; font.letterSpacing: 0.6; font.capitalization: Font.AllUppercase
                        }
                        PlaceRow {
                            width: parent.width
                            url: bmRow.modelData.url
                            title: bmRow.modelData.title
                            detail: bmRow.modelData.host
                            win: panel.win
                            extraMenu: [
                                { text: "Modifier…", icon: "pencil", run: () => panel.win.editBookmark(bmRow.modelData.url) },
                                { text: "Retirer des favoris", icon: "trash", danger: true, run: () => library.removeBookmark(bmRow.modelData.url) }
                            ]
                        }
                    }
                    Text {
                        anchors.centerIn: parent
                        width: parent.width - 40
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.Wrap
                        visible: bookmarkList.count === 0
                        text: panel.query ? "Aucun favori ne correspond." : "Pas encore de favoris.\nCtrl+D ajoute la page ouverte, ou importe-les d'un autre navigateur."
                        color: theme.textFaint
                        font.pixelSize: 12
                    }
                }
                Rectangle { Layout.fillWidth: true; height: 1; color: theme.line }
                RowLayout {
                    Layout.fillWidth: true
                    Layout.margins: 6
                    spacing: 4
                    Button {
                        id: importButton
                        text: "Importer…"
                        flat: true
                        onClicked: {
                            const list = [{ header: "Importer depuis" }]
                            for (const s of library.importSources())
                                list.push({ text: s.name, icon: "globe", run: ((path, name) => () => {
                                    const n = library.importBookmarks(path)
                                    panel.win.flash(n < 0 ? "Impossible de lire les favoris de " + name : n + " favori" + (n > 1 ? "s" : "") + " importé" + (n > 1 ? "s" : "") + " de " + name)
                                })(s.path, s.name) })
                            list.push({ text: "Fichier HTML (Firefox, Safari…)", icon: "file", run: () => importDialog.open() })
                            panel.win.menu.showBelow(importButton, list, false)
                        }
                    }
                    Button { text: "Exporter…"; flat: true; onClicked: exportDialog.open() }
                    Item { Layout.fillWidth: true }
                    Text { text: (library.bookmarksRevision, library.bookmarks("").length) + " favoris"; color: theme.textFaint; font.pixelSize: 11; Layout.rightMargin: 8 }
                }
            }

            // ---------------------------------------------- history
            ColumnLayout {
                spacing: 0
                ListView {
                    id: historyList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: panel.section === "history" && panel.win && panel.win.panelOpen ? (library.historyRevision, library.history(panel.query, 400)) : []
                    ScrollBar.vertical: ScrollBar {}
                    delegate: Column {
                        id: hRow
                        required property var modelData
                        required property int index
                        width: ListView.view.width
                        readonly property string day: panel.dayLabel(modelData.last)
                        readonly property bool header: index === 0 || panel.dayLabel(historyList.model[index - 1].last) !== day
                        Text {
                            visible: hRow.header
                            leftPadding: 16; topPadding: 10; bottomPadding: 4
                            text: hRow.day
                            color: theme.textFaint
                            font.pixelSize: 10; font.weight: Font.DemiBold; font.letterSpacing: 0.6; font.capitalization: Font.AllUppercase
                        }
                        PlaceRow {
                            width: parent.width
                            url: hRow.modelData.url
                            title: hRow.modelData.title || hRow.modelData.url
                            detail: Qt.formatTime(new Date(hRow.modelData.last), "HH:mm")
                            win: panel.win
                            extraMenu: [
                                { text: "Retirer de l'historique", icon: "trash", danger: true, run: () => library.removeHistory(hRow.modelData.url) }
                            ]
                        }
                    }
                    Text {
                        anchors.centerIn: parent
                        visible: historyList.count === 0
                        text: panel.query ? "Rien ne correspond." : (panel.opt("privacy/history") ? "L'historique est vide." : "L'historique est désactivé (Réglages → Confidentialité).")
                        color: theme.textFaint
                        font.pixelSize: 12
                    }
                }
                Rectangle { Layout.fillWidth: true; height: 1; color: theme.line }
                RowLayout {
                    Layout.fillWidth: true
                    Layout.margins: 6
                    Button {
                        id: clearButton
                        text: "Effacer…"
                        flat: true
                        onClicked: panel.win.menu.showBelow(clearButton, [
                            { header: "Effacer l'historique" },
                            { text: "De la dernière heure", icon: "clock", run: () => library.clearHistory(Date.now() - 3600000) },
                            { text: "D'aujourd'hui", icon: "clock", run: () => { const d = new Date(); library.clearHistory(new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime()) } },
                            { text: "Des 7 derniers jours", icon: "clock", run: () => library.clearHistory(Date.now() - 7 * 86400000) },
                            { text: "Tout", icon: "trash", danger: true, run: () => library.clearHistory(0) }
                        ], false)
                    }
                    Item { Layout.fillWidth: true }
                    Text { text: (library.historyRevision, library.historyCount()) + " pages"; color: theme.textFaint; font.pixelSize: 11; Layout.rightMargin: 8 }
                }
            }

            // ---------------------------------------------- downloads
            ColumnLayout {
                spacing: 0
                ListView {
                    id: downloadList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    spacing: 2
                    ScrollBar.vertical: ScrollBar {}
                    model: {
                        library.downloadsRevision
                        const live = app.downloads.filter(d => d && d.state !== WebEngineDownloadRequest.DownloadCompleted)
                                         .map(d => ({ live: true, item: d }))
                        return live.concat(library.downloads().map(d => ({ live: false, item: d })))
                    }
                    delegate: Rectangle {
                        id: dl
                        required property var modelData
                        readonly property var d: modelData.item
                        readonly property bool live: modelData.live
                        readonly property string name: live ? d.downloadFileName : d.name
                        readonly property string path: live ? d.downloadDirectory + "/" + d.downloadFileName : d.path
                        readonly property bool failed: live ? (d.state === WebEngineDownloadRequest.DownloadCancelled || d.state === WebEngineDownloadRequest.DownloadInterrupted) : !d.ok
                        width: ListView.view.width
                        height: live ? 70 : 52
                        color: dlHover.containsMouse ? theme.alpha(theme.text, 0.04) : "transparent"
                        MouseArea {
                            id: dlHover
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            onDoubleClicked: if (!dl.live && dl.d.exists) panel.win.openDownloaded(dl.path)
                            onClicked: (mouse) => {
                                if (mouse.button !== Qt.RightButton) return
                                const p = dl.mapToItem(null, mouse.x, mouse.y)
                                panel.win.menu.show([
                                    { text: "Ouvrir", icon: "external", enabled: !dl.live && dl.d.exists, run: () => browser.openFile(dl.path) },
                                    { text: "Afficher dans flair", icon: "folder", run: () => browser.showInFolder(dl.path) },
                                    { text: "Copier l'adresse d'origine", icon: "link", run: () => browser.copy(dl.live ? dl.d.url.toString() : dl.d.url) },
                                    { separator: true },
                                    { text: "Retirer de la liste", icon: "close", enabled: !dl.live, run: () => library.removeDownload(dl.path) }
                                ], p.x, p.y)
                            }
                        }
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 14
                            anchors.rightMargin: 8
                            spacing: 12
                            Rectangle {
                                Layout.preferredWidth: 32; Layout.preferredHeight: 32; radius: 8
                                color: theme.alpha(dl.failed ? theme.danger : theme.highlight, 0.14)
                                Icon { anchors.centerIn: parent; name: dl.failed ? "alert" : "download"; size: 16; color: dl.failed ? theme.danger : theme.highlight }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 3
                                Text { Layout.fillWidth: true; text: dl.name; color: !dl.live && !dl.d.exists ? theme.textFaint : theme.text; font.pixelSize: 13; font.strikeout: !dl.live && !dl.d.exists && !dl.failed; elide: Text.ElideMiddle }
                                ProgressBar {
                                    visible: dl.live && !dl.failed
                                    Layout.fillWidth: true
                                    Material.accent: theme.highlight
                                    from: 0; to: 1
                                    indeterminate: dl.live && dl.d.totalBytes <= 0
                                    value: dl.live && dl.d.totalBytes > 0 ? dl.d.receivedBytes / dl.d.totalBytes : 0
                                }
                                Text {
                                    Layout.fillWidth: true
                                    color: dl.failed ? theme.danger : theme.textFaint
                                    font.pixelSize: 11
                                    elide: Text.ElideRight
                                    text: {
                                        if (dl.live) {
                                            if (dl.failed) return dl.d.state === WebEngineDownloadRequest.DownloadCancelled ? "Annulé" : "Interrompu : " + dl.d.interruptReasonString
                                            const got = browser.humanSize(dl.d.receivedBytes)
                                            return (dl.d.isPaused ? "En pause · " : "") + got + (dl.d.totalBytes > 0 ? " sur " + browser.humanSize(dl.d.totalBytes) : "")
                                        }
                                        if (dl.failed) return "Échec"
                                        return (dl.d.exists ? browser.humanSize(dl.d.size) : "Fichier supprimé") + " · " + panel.dayLabel(dl.d.finished).toLowerCase() + " " + Qt.formatTime(new Date(dl.d.finished), "HH:mm")
                                    }
                                }
                            }
                            IconButton {
                                visible: dl.live && !dl.failed
                                icon: dl.live && dl.d.isPaused ? "play" : "pause"
                                tip: dl.live && dl.d.isPaused ? "Reprendre" : "Pause"
                                onClicked: dl.d.isPaused ? dl.d.resume() : dl.d.pause()
                            }
                            IconButton {
                                visible: dl.live && !dl.failed
                                icon: "close"; tip: "Annuler"
                                onClicked: dl.d.cancel()
                            }
                            IconButton {
                                visible: !dl.live && dl.d.exists
                                icon: "folder"; tip: "Afficher dans flair"
                                onClicked: browser.showInFolder(dl.path)
                            }
                        }
                    }
                    Text {
                        anchors.centerIn: parent
                        visible: downloadList.count === 0
                        text: "Aucun téléchargement."
                        color: theme.textFaint
                        font.pixelSize: 12
                    }
                }
                Rectangle { Layout.fillWidth: true; height: 1; color: theme.line }
                RowLayout {
                    Layout.fillWidth: true
                    Layout.margins: 6
                    Button { text: "Ouvrir le dossier"; flat: true; onClicked: browser.showInFolder(settings.downloadDirectory()) }
                    Item { Layout.fillWidth: true }
                    Button { text: "Effacer la liste"; flat: true; onClicked: library.clearDownloads() }
                }
            }

            // ---------------------------------------------- assistant
            AssistantPanel { id: assistantPanel; win: panel.win }
        }
    }

    FileDialog {
        id: importDialog
        title: "Importer des favoris"
        nameFilters: ["Favoris (*.html *.htm *.json)", "Tous les fichiers (*)"]
        onAccepted: {
            const n = library.importBookmarks(selectedFile.toString())
            panel.win.flash(n < 0 ? "Impossible de lire ce fichier." : n + " favori" + (n > 1 ? "s" : "") + " importé" + (n > 1 ? "s" : ""))
        }
    }
    FileDialog {
        id: exportDialog
        title: "Exporter les favoris"
        fileMode: FileDialog.SaveFile
        defaultSuffix: "html"
        currentFile: "file://" + browser.homePath() + "/favoris-flairweb.html"
        nameFilters: ["Fichier de favoris (*.html)"]
        onAccepted: panel.win.flash(library.exportBookmarks(selectedFile.toString()) ? "Favoris exportés." : "L'export a échoué.")
    }
}
