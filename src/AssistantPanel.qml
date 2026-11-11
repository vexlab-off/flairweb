import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// The page assistant: ask about the page that is open (or a selection) to
// Claude, OpenAI, Gemini or a local model. Answers stream in, in Markdown.
Item {
    id: assistant
    property var win: null
    property var messages: []       // [{id, role, text, error}]
    property bool includePage: true
    property string provider: (settings.revision, settings.value("ai/provider"))
    readonly property var tab: win ? win.currentTab : null
    readonly property bool ready: (settings.revision, pageAi.ready(provider))

    readonly property var quick: [
        { label: "Résumer", icon: "texte", prompt: "Résume cette page en quelques paragraphes courts, puis donne la conclusion en une phrase." },
        { label: "Points clés", icon: "plan", prompt: "Liste les points clés de cette page, du plus important au moins important." },
        { label: "Expliquer simplement", icon: "sparkle", prompt: "Explique le contenu de cette page simplement, comme à quelqu'un qui découvre le sujet." },
        { label: "Traduire", icon: "globe", prompt: "Traduis l'essentiel de cette page en français, fidèlement." },
        { label: "Vérifier", icon: "shieldCheck", prompt: "Quelles affirmations de cette page mériteraient d'être vérifiées, et pourquoi ? Signale les biais éventuels." },
        { label: "Questions", icon: "chat", prompt: "Quelles bonnes questions poser après avoir lu cette page ? Propose-en cinq." }
    ]

    // The conversation as shown: updated in place while an answer streams
    // (rebuilding it would lose the scroll position and any selection).
    ListModel { id: conversation }
    function show(m) { conversation.append({ mrole: m.role, mtext: m.text || "", merror: !!m.error, mpending: !!m.pending }) }
    function clear() { messages = []; conversation.clear() }
    function update(id, fields) {
        const i = messages.findIndex(m => m.id === id)
        if (i < 0) return
        const follow = list.atYEnd
        messages[i] = Object.assign({}, messages[i], fields)
        if (fields.text !== undefined) conversation.setProperty(i, "mtext", fields.text)
        if (fields.error !== undefined) conversation.setProperty(i, "merror", !!fields.error)
        if (fields.pending !== undefined) conversation.setProperty(i, "mpending", !!fields.pending)
        if (follow) Qt.callLater(() => list.positionViewAtEnd())
    }

    function send(text) {
        const question = (text || "").trim()
        if (!question || pageAi.busy) return
        if (!ready) { win.openSettings("ai"); return }
        const id = "a" + Date.now()
        const added = [{ id: "u" + Date.now(), role: "user", text: question }, { id: id, role: "assistant", text: "", pending: true }]
        messages = messages.concat(added)
        added.forEach(show)
        input.text = ""
        Qt.callLater(() => list.positionViewAtEnd())
        const turns = messages.filter(m => !m.pending && !m.error).map(m => ({ role: m.role, text: m.text }))
        const t = tab
        const go = (pageText, selection) => {
            let content = pageText
            if (selection && selection.length > 20) content = "[Sélection de l'utilisateur]\n" + selection + "\n\n[Page]\n" + pageText
            pageAi.ask(id, turns, t && includePage ? t.title : "", t && includePage ? t.url : "", includePage ? content : "", provider)
        }
        if (t && includePage && t.view && !t.isNewTab) t.pageText(go); else go("", "")
    }

    Connections {
        target: pageAi
        function onPartial(id, text) { assistant.update(id, { text: text }) }
        function onFinished(id, text) { assistant.update(id, { text: text, pending: false }) }
        function onFailed(id, message) { assistant.update(id, { text: message, pending: false, error: true }) }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Provider and context.
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: 10
            spacing: 6
            Repeater {
                model: [["claude", "Claude"], ["openai", "OpenAI"], ["gemini", "Gemini"], ["local", "Local"]]
                delegate: Chip {
                    required property var modelData
                    text: modelData[1]
                    chosen: assistant.provider === modelData[0]
                    onClicked: settings.set("ai/provider", modelData[0])
                }
            }
            Item { Layout.fillWidth: true }
            IconButton {
                icon: "refresh"; tip: "Nouvelle conversation"
                enabledButton: assistant.messages.length > 0
                onClicked: { pageAi.cancel(); assistant.clear() }
            }
        }
        Rectangle {
            Layout.fillWidth: true
            Layout.leftMargin: 10
            Layout.rightMargin: 10
            Layout.preferredHeight: 34
            radius: 8
            color: assistant.includePage ? theme.alpha(theme.highlight, 0.10) : theme.surface
            border.color: assistant.includePage ? theme.alpha(theme.highlight, 0.4) : theme.line
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 4
                spacing: 8
                Favicon { url: assistant.tab ? assistant.tab.url : ""; source: assistant.tab ? assistant.tab.icon : ""; size: 14 }
                Text {
                    Layout.fillWidth: true
                    text: assistant.tab && !assistant.tab.isNewTab ? assistant.tab.title : "Aucune page ouverte"
                    color: assistant.includePage ? theme.text : theme.textFaint
                    font.pixelSize: 12
                    elide: Text.ElideRight
                }
                Switch {
                    Material.accent: theme.highlight
                    checked: assistant.includePage
                    onToggled: assistant.includePage = checked
                    ToolTip.visible: hovered
                    ToolTip.text: "Joindre le texte de la page à la question"
                }
            }
        }

        // Conversation.
        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.topMargin: 8
            clip: true
            spacing: 10
            model: conversation
            ScrollBar.vertical: ScrollBar {}
            delegate: Item {
                id: message
                required property string mrole
                required property string mtext
                required property bool merror
                required property bool mpending
                width: ListView.view.width
                height: bubble.height
                Rectangle {
                    id: bubble
                    x: message.mrole === "user" ? message.width - width - 12 : 12
                    width: message.mrole === "user" ? Math.min(message.width * 0.85, userText.implicitWidth + 24) : message.width - 24
                    height: (message.mrole === "user" ? userText.implicitHeight : answer.implicitHeight) + 20
                    radius: 12
                    color: message.mrole === "user" ? theme.alpha(theme.highlight, 0.16)
                         : message.merror ? theme.alpha(theme.danger, 0.10) : theme.surface
                    border.color: message.mrole === "user" ? "transparent" : theme.line
                    Text {
                        id: userText
                        visible: message.mrole === "user"
                        x: 12; y: 10
                        width: Math.min(message.width * 0.85 - 24, implicitWidth)
                        text: message.mtext
                        color: theme.text
                        font.pixelSize: 13
                        wrapMode: Text.Wrap
                    }
                    TextEdit {
                        id: answer
                        visible: message.mrole !== "user"
                        x: 12; y: 10
                        width: parent.width - 24
                        readOnly: true
                        selectByMouse: true
                        textFormat: message.merror ? TextEdit.PlainText : TextEdit.MarkdownText
                        text: message.mtext || (message.mpending ? "…" : "")
                        color: message.merror ? theme.danger : theme.text
                        selectionColor: theme.alpha(theme.highlight, 0.4)
                        font.pixelSize: 13
                        wrapMode: TextEdit.Wrap
                        onLinkActivated: (link) => assistant.win.openTab(link, {})
                    }
                    IconButton {
                        visible: message.mrole !== "user" && !message.mpending && !message.merror && bubbleHover.containsMouse
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 4
                        icon: "copy"; tip: "Copier la réponse"
                        onClicked: { browser.copy(message.mtext); assistant.win.flash("Réponse copiée.") }
                    }
                    MouseArea { id: bubbleHover; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                }
            }

            // Empty: what it can do.
            ColumnLayout {
                anchors.centerIn: parent
                width: parent.width - 32
                visible: list.count === 0
                spacing: 10
                Icon { Layout.alignment: Qt.AlignHCenter; name: "sparkle"; size: 30; color: theme.highlight }
                Text {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    text: assistant.ready ? "Demande ce que tu veux sur la page ouverte." : "Ajoute une clé " + pageAi.providerName(assistant.provider) + " ou l'adresse d'un modèle local pour commencer."
                    color: theme.textDim
                    font.pixelSize: 13
                }
                Button {
                    visible: !assistant.ready
                    Layout.alignment: Qt.AlignHCenter
                    text: "Réglages de l'IA"
                    onClicked: assistant.win.openSettings("ai")
                }
                Flow {
                    visible: assistant.ready
                    Layout.fillWidth: true
                    spacing: 6
                    Repeater {
                        model: assistant.quick
                        delegate: Chip {
                            required property var modelData
                            text: modelData.label
                            icon: modelData.icon
                            onClicked: assistant.send(modelData.prompt)
                        }
                    }
                }
            }
        }

        // Quick actions above the input once a conversation started.
        Flickable {
            visible: list.count > 0 && assistant.ready
            Layout.fillWidth: true
            Layout.preferredHeight: 38
            Layout.leftMargin: 10
            Layout.rightMargin: 10
            contentWidth: quickRow.implicitWidth
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            Row {
                id: quickRow
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6
                Repeater {
                    model: assistant.quick
                    delegate: Chip {
                        required property var modelData
                        text: modelData.label
                        onClicked: assistant.send(modelData.prompt)
                    }
                }
            }
        }

        // Input.
        Rectangle {
            Layout.fillWidth: true
            Layout.margins: 10
            Layout.preferredHeight: Math.min(160, Math.max(44, input.implicitHeight + 16))
            radius: 12
            color: theme.surface
            border.color: input.activeFocus ? theme.highlight : theme.line
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 4
                anchors.rightMargin: 6
                spacing: 4
                ScrollView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    TextArea {
                        id: input
                        background: null
                        wrapMode: TextArea.Wrap
                        font.pixelSize: 13
                        Text {
                            x: input.leftPadding
                            y: input.topPadding
                            visible: input.text === "" && input.preeditText === ""
                            text: pageAi.busy ? "L'assistant écrit…" : "Une question sur la page…"
                            color: theme.textFaint
                            font: input.font
                        }
                        Keys.onReturnPressed: (event) => {
                            if (event.modifiers & Qt.ShiftModifier) { event.accepted = false; return }
                            assistant.send(text)
                        }
                    }
                }
                IconButton {
                    icon: pageAi.busy ? "stop" : "arrowUp"
                    iconColor: pageAi.busy || input.text.trim() !== "" ? theme.highlight : theme.textFaint
                    tip: pageAi.busy ? "Arrêter" : "Envoyer (Entrée)"
                    onClicked: pageAi.busy ? pageAi.cancel() : assistant.send(input.text)
                }
            }
        }
        Text {
            Layout.leftMargin: 12
            Layout.bottomMargin: 8
            text: pageAi.providerName(assistant.provider) + " · " + ((settings.revision, pageAi.model(assistant.provider)) || "modèle par défaut")
            color: theme.textFaint
            font.pixelSize: 10
        }
    }
}
