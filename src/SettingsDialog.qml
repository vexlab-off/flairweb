import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import QtQuick.Dialogs

// Every setting, grouped, each with a sentence on what it changes. Changes
// apply as you make them, so the browser changes behind the dialog.
Popup {
    id: dialog
    property var win: null
    property string section: "appearance"
    property string extra: ""
    parent: Overlay.overlay
    modal: true
    focus: true
    anchors.centerIn: parent
    width: Math.min(parent.width - 40, 1000)
    height: Math.min(parent.height - 40, 780)
    padding: 0
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    Overlay.modal: Rectangle { color: theme.alpha(theme.background, 0.6) }
    background: Rectangle { color: theme.surface; radius: 16; border.color: theme.line }

    function openAt(name, extraValue) {
        section = name || "appearance"
        extra = extraValue || ""
        // From a site's panel: that site gets its rule, every time.
        if (section === "style" && extra !== "") {
            let rules = []
            try { rules = JSON.parse(v("style/sites")) || [] } catch (e) { rules = [] }
            if (!rules.some(r => r.pattern === extra))
                settings.set("style/sites", JSON.stringify(rules.concat([{ pattern: extra, css: "", js: "", enabled: true }])))
        }
        open()
        scroller.contentItem.contentY = 0
    }
    function v(key) { return settings.revision, settings.value(key) }
    function set(key, value) { settings.set(key, value) }
    readonly property bool synced: (settings.revision, settings.suiteSync())
    function suite(key, fallback) { return settings.revision, settings.suiteValue(key, fallback) }
    function accentNow() { return synced ? suite("appearance/accent", "#ff8a3d") : v("appearance/accent") }
    // A colour or a mode picked here replaces a Chrome theme's.
    function setAccent(value) { dropChromeTheme(); synced ? settings.setSuiteValue("appearance/accent", value) : settings.set("appearance/accent", value) }
    function dropChromeTheme() { if (v("appearance/chromeTheme") !== "") browser.removeChromeTheme() }
    readonly property var chromeTheme: { const raw = v("appearance/chromeTheme"); try { return raw ? JSON.parse(raw) : null } catch (e) { return null } }
    function modeNow() { return synced ? suite("appearance/mode", "auto") : v("appearance/mode") }
    function setMode(value) { dropChromeTheme(); synced ? settings.setSuiteValue("appearance/mode", value) : settings.set("appearance/mode", value) }

    readonly property var sections: [
        { key: "appearance", label: "Apparence", icon: "eye" },
        { key: "tabs", label: "Onglets", icon: "tabs" },
        { key: "toolbar", label: "Barre d'outils", icon: "sliders" },
        { key: "search", label: "Recherche", icon: "search" },
        { key: "newtab", label: "Nouvel onglet", icon: "grid" },
        { key: "start", label: "Démarrage", icon: "home" },
        { key: "privacy", label: "Confidentialité", icon: "shield" },
        { key: "web", label: "Contenu web", icon: "globe" },
        { key: "style", label: "Styles et scripts", icon: "brush" },
        { key: "downloads", label: "Téléchargements", icon: "download" },
        { key: "extensions", label: "Extensions", icon: "puzzle" },
        { key: "ai", label: "Assistant IA", icon: "sparkle" },
        { key: "keys", label: "Raccourcis", icon: "keyboard" }
    ]

    // ------------------------------------------------------------ pieces
    component Heading: ColumnLayout {
        property string title
        property string intro
        Layout.fillWidth: true
        spacing: 4
        Text { text: parent.title; color: theme.text; font.pixelSize: 21; font.weight: Font.Bold; font.letterSpacing: -0.3 }
        Text { Layout.fillWidth: true; visible: text !== ""; text: parent.intro; color: theme.textDim; font.pixelSize: 12; wrapMode: Text.Wrap; lineHeight: 1.2; textFormat: Text.StyledText }
    }
    component Subheading: Text {
        Layout.topMargin: 6
        color: theme.textFaint
        font.pixelSize: 11
        font.weight: Font.DemiBold
        font.letterSpacing: 0.6
        font.capitalization: Font.AllUppercase
    }
    component Setting: RowLayout {
        id: setting
        property string label
        property string help
        default property alias control: holder.data
        Layout.fillWidth: true
        spacing: 16
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2
            Text { Layout.fillWidth: true; text: setting.label; color: theme.text; font.pixelSize: 13; font.weight: Font.DemiBold; wrapMode: Text.Wrap }
            Text { Layout.fillWidth: true; visible: text !== ""; text: setting.help; color: theme.textDim; font.pixelSize: 12; wrapMode: Text.Wrap; textFormat: Text.StyledText }
        }
        Item {
            id: holder
            Layout.preferredWidth: Math.max(childrenRect.width, 10)
            Layout.preferredHeight: childrenRect.height
        }
    }
    component Toggle: Setting {
        id: toggle
        property string key
        Switch {
            Material.accent: theme.highlight
            checked: dialog.v(toggle.key)
            onToggled: settings.set(toggle.key, checked)
        }
    }
    // A row of choices: options [[value, label, icon]].
    component Choice: ColumnLayout {
        id: choice
        property string key
        property string label
        property string help
        property var options: []
        Layout.fillWidth: true
        spacing: 8
        Setting { label: choice.label; help: choice.help }
        Flow {
            Layout.fillWidth: true
            spacing: 8
            Repeater {
                model: choice.options
                delegate: Chip {
                    required property var modelData
                    text: modelData[1]
                    icon: modelData[2] || ""
                    chosen: String(dialog.v(choice.key)) === String(modelData[0])
                    onClicked: settings.set(choice.key, modelData[0])
                }
            }
        }
    }
    component TextSetting: Setting {
        id: textSetting
        property string key
        property string placeholder
        property int fieldWidth: 280
        TextField {
            id: textField
            width: Math.min(textSetting.fieldWidth, Math.max(140, dialog.width * 0.4))
            // Not a binding: another setting changing while you type here
            // would put the old value back.
            Component.onCompleted: text = dialog.v(textSetting.key)
            Connections {
                target: settings
                function onChanged() { if (!textField.activeFocus) textField.text = dialog.v(textSetting.key) }
            }
            placeholderText: textSetting.placeholder
            onEditingFinished: settings.set(textSetting.key, text.trim())
        }
    }
    component NumberSetting: Setting {
        id: numberSetting
        property string key
        property real from: 0
        property real to: 100
        property real step: 1
        property string unit: ""
        property int decimals: 0
        Row {
            spacing: 10
            Slider {
                anchors.verticalCenter: parent.verticalCenter
                width: 180
                Material.accent: theme.highlight
                from: numberSetting.from; to: numberSetting.to; stepSize: numberSetting.step
                value: dialog.v(numberSetting.key)
                onMoved: settings.set(numberSetting.key, numberSetting.decimals > 0 ? Math.round(value * 100) / 100 : Math.round(value))
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: 56
                text: Number(dialog.v(numberSetting.key)).toFixed(numberSetting.decimals) + numberSetting.unit
                color: theme.textDim
                font.pixelSize: 12
                font.features: { "tnum": 1 }
            }
        }
    }
    component Code: ScrollView {
        id: code
        property string key
        property string placeholder
        Layout.fillWidth: true
        Layout.preferredHeight: 150
        background: Rectangle { radius: 8; color: theme.background; border.color: area.activeFocus ? theme.highlight : theme.line }
        TextArea {
            id: area
            Component.onCompleted: text = dialog.v(code.key)
            Connections {
                target: settings
                function onChanged() { if (!area.activeFocus) area.text = dialog.v(code.key) }
            }
            placeholderText: code.placeholder
            font.family: "JetBrains Mono, monospace"
            font.pixelSize: 12
            wrapMode: TextArea.NoWrap
            background: null
            onActiveFocusChanged: if (!activeFocus) settings.set(code.key, text)
        }
    }
    component Divider: Rectangle { Layout.fillWidth: true; Layout.topMargin: 4; Layout.bottomMargin: 4; height: 1; color: theme.line }
    component Card: Rectangle {
        default property alias content: cardColumn.data
        Layout.fillWidth: true
        Layout.preferredHeight: cardColumn.implicitHeight + 24
        radius: 12
        color: theme.background
        border.color: theme.line
        ColumnLayout {
            id: cardColumn
            anchors.fill: parent
            anchors.margins: 12
            spacing: 8
        }
    }

    // ------------------------------------------------------------ layout
    RowLayout {
        anchors.fill: parent
        spacing: 0

        Rectangle {
            Layout.preferredWidth: Math.round(Math.min(230, Math.max(170, dialog.width * 0.3)))
            Layout.fillHeight: true
            color: theme.sidebar
            radius: 16
            Rectangle { anchors.right: parent.right; width: 16; height: parent.height; color: theme.sidebar }
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 14
                spacing: 2
                RowLayout {
                    Layout.bottomMargin: 14
                    Layout.leftMargin: 4
                    spacing: 10
                    Logo { size: 28 }
                    ColumnLayout {
                        spacing: 0
                        Text { text: "Réglages"; color: theme.text; font.pixelSize: 15; font.weight: Font.Bold }
                        Text { text: "Flair Web"; color: theme.textFaint; font.pixelSize: 11 }
                    }
                }
                // The sections scroll in a small window; "Fermer" stays in view.
                Flickable {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.preferredHeight: 0
                    Layout.minimumHeight: 0
                    clip: true
                    contentHeight: navColumn.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                Column {
                    id: navColumn
                    width: parent.width
                    spacing: 2
                Repeater {
                    model: dialog.sections
                    delegate: Rectangle {
                        required property var modelData
                        readonly property bool active: dialog.section === modelData.key
                        width: navColumn.width
                        height: 32
                        radius: 8
                        color: active ? theme.alpha(theme.highlight, 0.14) : (navHover.containsMouse ? theme.alpha(theme.text, 0.04) : "transparent")
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 10
                            spacing: 10
                            Icon { name: modelData.icon; size: 15; color: parent.parent.active ? theme.highlight : theme.textDim }
                            Text { Layout.fillWidth: true; text: modelData.label; color: parent.parent.active ? theme.text : theme.textDim; font.pixelSize: 13; font.weight: parent.parent.active ? Font.DemiBold : Font.Normal }
                        }
                        MouseArea { id: navHover; anchors.fill: parent; hoverEnabled: true; onClicked: { dialog.section = modelData.key; scroller.contentItem.contentY = 0 } }
                    }
                }
                }
                }
                Text { visible: dialog.height > 520; Layout.fillWidth: true; text: "Les changements s'appliquent tout de suite."; color: theme.textFaint; font.pixelSize: 11; wrapMode: Text.Wrap }
                Button { Layout.fillWidth: true; text: "Fermer"; flat: true; onClicked: dialog.close() }
            }
        }

        ScrollView {
            id: scroller
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: availableWidth
            ColumnLayout {
                x: 28
                width: scroller.availableWidth - 56
                spacing: 18
                Item { height: 10 }
                Loader {
                    Layout.fillWidth: true
                    sourceComponent: ({ appearance: appearancePage, tabs: tabsPage, toolbar: toolbarPage, search: searchPage,
                                        newtab: newtabPage, start: startPage, privacy: privacyPage, web: webPage, style: stylePage,
                                        downloads: downloadsPage, extensions: extensionsPage, ai: aiPage, keys: keysPage })[dialog.section]
                }
                Item { height: 24 }
            }
        }
    }

    // ------------------------------------------------------------ appearance
    Component {
        id: appearancePage
        ColumnLayout {
            spacing: 18
            Heading { title: "Apparence"; intro: "Les couleurs, le mode clair ou sombre et l'allure générale du navigateur." }
            Setting {
                label: "Synchroniser les couleurs de la suite flair"
                help: "Couleur d'accent, mode clair/sombre et style du logo identiques dans flair, Flair Code et Flair Web. Un changement ici s'applique aux autres."
                Switch { Material.accent: theme.highlight; checked: dialog.synced; onToggled: settings.setSuiteSync(checked) }
            }
            // A theme from the Chrome Web Store.
            Setting {
                label: dialog.chromeTheme ? "Thème : " + dialog.chromeTheme.name : "Thèmes Chrome"
                help: dialog.chromeTheme ? "Installé depuis le Chrome Web Store : il donne la couleur d'accent, le mode et le fond du nouvel onglet. Choisir une couleur ou un mode ci-dessous le remplace."
                                         : "Les thèmes du Chrome Web Store s'installent avec leur bouton « Ajouter à Flair Web » : couleur d'accent, mode clair ou sombre, image du nouvel onglet."
                RowLayout {
                    spacing: 6
                    Rectangle {
                        visible: !!(dialog.chromeTheme && dialog.chromeTheme.accent)
                        width: 18; height: 18; radius: 9
                        color: dialog.chromeTheme && dialog.chromeTheme.accent ? dialog.chromeTheme.accent : "transparent"
                        border.color: theme.line
                    }
                    Button { visible: !!dialog.chromeTheme; text: "Retirer"; flat: true; onClicked: browser.removeChromeTheme() }
                    Button { text: "Parcourir les thèmes"; flat: true; onClicked: { dialog.close(); dialog.win.openTab("https://chromewebstore.google.com/category/themes", {}) } }
                }
            }
            Divider {}
            Setting { label: "Mode"; help: dialog.synced ? "« Automatique » suit le thème Vex." : "« Comme flair » suit le réglage de flair ; « Automatique » suit Vex." }
            Flow {
                Layout.fillWidth: true
                spacing: 8
                Repeater {
                    model: dialog.synced ? [["auto", "Automatique", "refresh"], ["light", "Clair", "sun"], ["dark", "Sombre", "moon"]]
                                         : [["flair", "Comme flair", "sparkle"], ["auto", "Automatique", "refresh"], ["light", "Clair", "sun"], ["dark", "Sombre", "moon"]]
                    delegate: Chip {
                        required property var modelData
                        text: modelData[1]; icon: modelData[2]
                        chosen: dialog.modeNow() === modelData[0]
                        onClicked: dialog.setMode(modelData[0])
                    }
                }
            }
            Divider {}
            Setting { label: "Couleur d'accent"; help: dialog.synced ? "Partagée par toute la suite flair." : "« Comme flair » reprend la couleur de flair ; sinon, une couleur pour Flair Web seul." }
            Flow {
                Layout.fillWidth: true
                spacing: 8
                Chip { visible: !dialog.synced; text: "Comme flair"; icon: "sparkle"; chosen: dialog.v("appearance/accent") === "flair"; onClicked: settings.set("appearance/accent", "flair") }
                Chip { visible: dialog.synced; text: "Thème Vex"; icon: "refresh"; chosen: dialog.accentNow() === "theme"; onClicked: dialog.setAccent("theme") }
                Repeater {
                    model: [["Orange", "#ff8a3d"], ["Ambre", "#f5b942"], ["Rouge", "#f05252"], ["Rose", "#ec5fa6"], ["Violet", "#9b7bff"], ["Bleu", "#5c9df5"], ["Vert", "#3ecf8e"], ["Turquoise", "#4fd6c4"]]
                    delegate: Chip {
                        required property var modelData
                        text: modelData[0]; swatch: modelData[1]
                        chosen: dialog.accentNow() === modelData[1]
                        onClicked: dialog.setAccent(modelData[1])
                    }
                }
                TextField {
                    width: 110
                    placeholderText: "#rrggbb"
                    font.family: "monospace"
                    onEditingFinished: if (/^#[0-9a-fA-F]{6}$/.test(text.trim())) dialog.setAccent(text.trim().toLowerCase())
                }
            }
            Divider {}
            Choice { key: "appearance/density"; label: "Densité"; help: "Compacte : une barre d'outils plus basse, plus de place pour la page."; options: [["comfortable", "Confortable", "expand"], ["compact", "Compacte", "shrink"]] }
            Toggle { key: "appearance/pageCard"; label: "La page dans une carte"; help: "Une marge et des coins arrondis autour de la page, comme une feuille posée sur le navigateur. Désactivé : la page va d'un bord à l'autre." }
            NumberSetting { key: "appearance/radius"; label: "Arrondi des coins"; help: "De la carte, de la barre d'adresse."; from: 0; to: 20; unit: " px" }
        }
    }

    // ------------------------------------------------------------ tabs
    Component {
        id: tabsPage
        ColumnLayout {
            spacing: 18
            Heading { title: "Onglets"; intro: "Où ils sont, comment ils s'ouvrent, quand ils s'endorment." }
            Choice { key: "tabs/position"; label: "Position"; help: "Sur le côté, les titres restent lisibles même avec beaucoup d'onglets ; en haut, comme partout ailleurs."; options: [["side", "Sur le côté", "sidebar"], ["top", "En haut", "tabs"]] }
            Toggle { key: "tabs/compact"; label: "Onglets latéraux compacts"; help: "Juste les icônes, dans une colonne étroite (Ctrl+B)." }
            NumberSetting { key: "tabs/sideWidth"; label: "Largeur de la colonne d'onglets"; help: "Aussi réglable en tirant son bord."; from: 170; to: 440; unit: " px" }
            Choice { key: "tabs/closeButton"; label: "Bouton de fermeture"; options: [["hover", "Au survol", "eye"], ["always", "Toujours", "close"], ["never", "Jamais (clic du milieu)", "minus"]] }
            Choice { key: "tabs/newTabPosition"; label: "Les nouveaux onglets s'ouvrent"; options: [["afterCurrent", "À côté de l'onglet courant", "arrowRight"], ["end", "À la fin", "chevron"]] }
            Toggle { key: "tabs/backgroundLinks"; label: "Liens en arrière-plan"; help: "Un clic du milieu (ou Ctrl+clic) ouvre le lien derrière, sans quitter la page." }
            NumberSetting { key: "tabs/sleepMinutes"; label: "Endormir les onglets inactifs après"; help: "Un onglet endormi libère sa mémoire et se réveille quand tu y reviens. 0 : jamais. Les onglets qui jouent du son ne dorment pas."; from: 0; to: 240; step: 5; unit: " min" }
            Toggle { key: "tabs/confirmCloseMany"; label: "Confirmer avant de fermer une fenêtre de plusieurs onglets" }
            Toggle { key: "tabs/closeWindowWithLastTab"; label: "Fermer la fenêtre avec son dernier onglet"; help: "Sinon, un nouvel onglet le remplace." }
        }
    }

    // ------------------------------------------------------------ toolbar
    Component {
        id: toolbarPage
        ColumnLayout {
            spacing: 18
            Heading { title: "Barre d'outils"; intro: "Ce qui s'affiche autour de la barre d'adresse." }
            Choice { key: "toolbar/bookmarksBar"; label: "Barre de favoris"; help: "Ctrl+Maj+Espace passe d'un mode à l'autre."; options: [["always", "Toujours", "check"], ["newtab", "Sur les nouveaux onglets", "grid"], ["never", "Jamais", "close"]] }
            Toggle { key: "toolbar/fullUrl"; label: "Adresse complète"; help: "Afficher https://, www. et la fin de l'adresse ; sinon le site ressort et le reste s'efface." }
            Toggle { key: "toolbar/linkPreview"; label: "Aperçu des liens"; help: "En bas de la page, l'adresse du lien survolé." }
            Subheading { text: "Boutons" }
            Toggle { key: "toolbar/home"; label: "Accueil" }
            Toggle { key: "toolbar/reader"; label: "Mode lecture (dans la barre d'adresse)" }
            Toggle { key: "toolbar/shield"; label: "Bouclier (dans la barre d'adresse)"; help: "Avec le nombre de pubs et traceurs bloqués sur la page." }
            Toggle { key: "toolbar/library"; label: "Favoris et historique" }
            Toggle { key: "toolbar/ai"; label: "Assistant" }
            Toggle { key: "toolbar/downloads"; label: "Téléchargements"; help: "Visible dès qu'il y a un téléchargement." }
            Toggle { key: "toolbar/extensions"; label: "Extensions"; help: "Les extensions installées, et l'ajout depuis le Chrome Web Store." }
            Toggle { key: "toolbar/extensionIcons"; label: "Boutons des extensions"; help: "Le bouton de chaque extension, avec son badge (pubs bloquées…)." }
            Toggle { key: "toolbar/settings"; label: "Réglages"; help: "Aussi dans le menu ⋯ et avec Ctrl+," }
            Toggle { key: "toolbar/devtools"; label: "Outils de développement" }
        }
    }

    // ------------------------------------------------------------ search
    Component {
        id: searchPage
        ColumnLayout {
            id: searchColumn
            spacing: 18
            readonly property var list: (engines.revision, engines.all(true))
            Heading { title: "Recherche"; intro: "Le moteur que tu veux, d'autres à portée de mot-clé : tape <b>yt chats</b> pour chercher sur YouTube, <b>wiki Lyon</b> sur Wikipédia, ou <b>!gh flair</b> n'importe où dans la recherche." }
            Setting { label: "Moteur par défaut" }
            GridLayout {
                Layout.fillWidth: true
                columns: Math.max(2, Math.floor(searchColumn.width / 210))
                columnSpacing: 8
                rowSpacing: 8
                Repeater {
                    model: searchColumn.list.filter(e => !e.hidden && e.category !== "site")
                    delegate: Rectangle {
                        required property var modelData
                        readonly property bool chosen: dialog.v("search/engine") === modelData.key
                        Layout.fillWidth: true
                        Layout.preferredHeight: 42
                        radius: 10
                        color: chosen ? theme.alpha(theme.highlight, 0.14) : (pick.containsMouse ? theme.raised : theme.background)
                        border.color: chosen ? theme.highlight : theme.line
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 10
                            spacing: 10
                            EngineBadge { engine: modelData; size: 22 }
                            Text { Layout.fillWidth: true; text: modelData.name; color: theme.text; font.pixelSize: 13; elide: Text.ElideRight }
                        }
                        MouseArea { id: pick; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { settings.set("search/engine", modelData.key); settings.set("search/chosen", true) } }
                    }
                }
            }
            Setting {
                label: "Moteur des onglets privés"
                help: "Un moteur qui ne te piste pas est un bon choix ici."
                ComboBox {
                    width: 220
                    model: searchColumn.list.filter(e => !e.hidden)
                    textRole: "name"
                    currentIndex: model.findIndex(e => e.key === dialog.v("search/privateEngine"))
                    onActivated: (i) => settings.set("search/privateEngine", model[i].key)
                }
            }
            Divider {}
            Toggle { key: "search/suggestions"; label: "Suggestions du moteur"; help: "Ce que tu tapes est envoyé au moteur pendant que tu tapes, pour proposer des recherches." }
            Toggle { key: "search/privateSuggestions"; label: "Suggestions du moteur en onglet privé" }
            Toggle { key: "search/historySuggestions"; label: "Suggérer depuis l'historique"; help: "Et compléter l'adresse d'un site déjà visité pendant la frappe." }
            Toggle { key: "search/bookmarkSuggestions"; label: "Suggérer depuis les favoris" }
            NumberSetting { key: "search/maxSuggestions"; label: "Suggestions du moteur au plus"; from: 0; to: 12 }
            Choice { key: "search/keywords"; label: "Mots-clés des moteurs"; help: "« Espace » : <b>yt chats</b> et <b>!yt chats</b>. « ! seulement » évite qu'un mot courant déclenche un moteur."; options: [["space", "Mot-clé + espace", "keyboard"], ["bang", "! seulement", "alert"], ["off", "Désactivés", "close"]] }
            Toggle { key: "search/newTab"; label: "Ouvrir les recherches dans un nouvel onglet"; help: "Depuis la barre d'adresse, quand une page est déjà ouverte. Alt+Entrée le fait au cas par cas." }
            Divider {}
            Subheading { text: "Tous les moteurs" }
            Text { Layout.fillWidth: true; wrapMode: Text.Wrap; color: theme.textDim; font.pixelSize: 12; text: "Change un mot-clé directement dans sa case. L'œil masque un moteur des listes (il reste utilisable par son mot-clé tant qu'il en a un)." }
            Repeater {
                model: searchColumn.list
                delegate: RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 10
                    opacity: modelData.hidden ? 0.5 : 1
                    EngineBadge { engine: modelData; size: 22 }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        Text { text: modelData.name + (modelData.builtin ? "" : "  · personnel"); color: theme.text; font.pixelSize: 13 }
                        Text { Layout.fillWidth: true; text: modelData.url; color: theme.textFaint; font.pixelSize: 10; elide: Text.ElideMiddle }
                    }
                    TextField {
                        Layout.preferredWidth: 80
                        text: modelData.keyword || ""
                        placeholderText: "mot-clé"
                        horizontalAlignment: TextInput.AlignHCenter
                        font.family: "monospace"
                        onEditingFinished: if (text.trim() !== (modelData.keyword || "")) engines.updateEngine(modelData.key, modelData.name, text.trim(), modelData.url, modelData.suggest || "")
                    }
                    IconButton { icon: modelData.hidden ? "eye" : "eye"; active: !modelData.hidden; tip: modelData.hidden ? "Afficher dans les listes" : "Masquer des listes"; onClicked: engines.setHidden(modelData.key, !modelData.hidden) }
                    IconButton { icon: "pencil"; tip: "Modifier"; onClicked: engineEditor.edit(modelData) }
                    IconButton {
                        icon: modelData.builtin ? "refresh" : "trash"
                        enabledButton: !modelData.builtin || modelData.custom
                        tip: modelData.builtin ? "Revenir à l'original" : "Supprimer"
                        onClicked: modelData.builtin ? engines.resetBuiltin(modelData.key) : engines.removeCustom(modelData.key)
                    }
                }
            }
            RowLayout {
                PrimaryButton { text: "Ajouter un moteur"; onClicked: engineEditor.edit(null) }
                Text { Layout.fillWidth: true; Layout.leftMargin: 8; wrapMode: Text.Wrap; color: theme.textFaint; font.pixelSize: 11; text: "N'importe quel site qui a une page de résultats : mets %s à la place de la recherche dans son adresse." }
            }
        }
    }

    // ------------------------------------------------------------ new tab
    Component {
        id: newtabPage
        ColumnLayout {
            spacing: 18
            Heading { title: "Nouvel onglet"; intro: "La page qui s'ouvre avec Ctrl+T : chaque élément peut être retiré." }
            Choice { key: "newtab/background"; label: "Fond"; options: [["glow", "Lueur d'accent", "sparkle"], ["gradient", "Dégradé", "layers"], ["plain", "Uni", "minus"], ["image", "Image", "image"]] }
            Setting {
                visible: dialog.v("newtab/background") === "image"
                label: "Image de fond"
                help: dialog.v("newtab/image") ? browser.localPath(dialog.v("newtab/image")) : "Aucune image choisie."
                Button { text: "Choisir…"; onClicked: imageDialog.open() }
            }
            NumberSetting { visible: dialog.v("newtab/background") === "image"; key: "newtab/dim"; label: "Assombrir l'image"; help: "Pour que le texte reste lisible."; from: 0; to: 0.9; step: 0.05; decimals: 2 }
            Divider {}
            Toggle { key: "newtab/clock"; label: "Horloge" }
            Toggle { key: "newtab/seconds"; label: "Avec les secondes" }
            Toggle { key: "newtab/greeting"; label: "Salutation et date" }
            TextSetting { key: "newtab/name"; label: "Ton prénom"; help: "« Bonsoir, … »"; placeholder: "facultatif"; fieldWidth: 200 }
            Toggle { key: "newtab/search"; label: "Champ de recherche" }
            Toggle { key: "newtab/engines"; label: "Moteurs à portée de clic"; help: "Sous le champ de recherche." }
            TextSetting { key: "newtab/engineKeys"; label: "Lesquels"; help: "Leurs identifiants, séparés par des virgules : " + (engines.revision, engines.all().map(e => e.key).join(", ")); fieldWidth: 320 }
            Toggle { key: "newtab/shortcuts"; label: "Raccourcis"; help: "Les tuiles des sites ; clic droit dessus pour les modifier ou les déplacer." }
            NumberSetting { key: "newtab/columns"; label: "Raccourcis par ligne au plus"; from: 3; to: 10 }
            Choice { key: "newtab/tiles"; label: "Forme des tuiles"; options: [["rounded", "Arrondies", "grid"], ["circle", "Rondes", "globe"], ["square", "Carrées", "copy"]] }
            Toggle { key: "newtab/recent"; label: "Reprendre"; help: "Les dernières pages visitées." }
        }
    }

    // ------------------------------------------------------------ start
    Component {
        id: startPage
        ColumnLayout {
            spacing: 18
            Heading { title: "Démarrage"; intro: "Ce qui s'ouvre au lancement de Flair Web." }
            Choice { key: "start/mode"; label: "Au démarrage"; options: [["session", "Reprendre là où j'en étais", "refresh"], ["newtab", "Un nouvel onglet", "plus"], ["home", "Ma page d'accueil", "home"]] }
            TextSetting { key: "start/home"; label: "Page d'accueil"; help: "Aussi pour le bouton et Alt+Origine. Vide : la page de nouvel onglet."; placeholder: "exemple.com" }
            Divider {}
            Setting {
                id: defaultSetting
                property bool isDefault: browser.isDefaultBrowser()
                label: "Navigateur par défaut"
                help: isDefault ? "Flair Web ouvre les liens des autres applications." : "Les liens ouverts depuis les autres applications arrivent dans un onglet de Flair Web."
                PrimaryButton {
                    text: defaultSetting.isDefault ? "C'est le cas ✓" : "Définir par défaut"
                    enabled: !defaultSetting.isDefault
                    onClicked: defaultSetting.isDefault = browser.makeDefaultBrowser()
                }
            }
        }
    }

    // ------------------------------------------------------------ privacy
    Component {
        id: privacyPage
        ColumnLayout {
            spacing: 18
            Heading { title: "Confidentialité"; intro: "Le bouclier bloque les pubs et les traceurs avant même qu'ils se chargent. Rien n'est envoyé ailleurs qu'aux sites que tu visites (et au moteur, pour les suggestions)." }
            Toggle { key: "privacy/shield"; label: "Bouclier"; help: (shield.revision, shield.listSize) + " domaines bloqués" + (shield.listUpdated ? " · listes du " + shield.listUpdated : "") + "." }
            Toggle { key: "privacy/cosmetic"; label: "Masquer les emplacements vides"; help: "Retire les cadres laissés par les pubs bloquées." }
            Card {
                Text { text: "Listes de blocage"; color: theme.text; font.pixelSize: 13; font.weight: Font.DemiBold }
                Text { Layout.fillWidth: true; wrapMode: Text.Wrap; color: theme.textDim; font.pixelSize: 12; text: "En plus de la liste intégrée. Téléchargées depuis leurs auteurs, gardées sur ta machine." }
                Repeater {
                    model: (shield.revision, settings.revision, shield.lists())
                    delegate: RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        CheckBox { Material.accent: theme.highlight; checked: modelData.enabled; onToggled: shield.setListEnabled(modelData.key, checked) }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            Text { text: modelData.name; color: theme.text; font.pixelSize: 12 }
                            Text { text: modelData.downloaded ? "à jour du " + modelData.updated : "pas encore téléchargée"; color: theme.textFaint; font.pixelSize: 10 }
                        }
                    }
                }
                RowLayout {
                    PrimaryButton { text: shield.updating ? "Téléchargement…" : "Mettre à jour les listes"; enabled: !shield.updating; onClicked: shield.updateLists() }
                    Text { Layout.fillWidth: true; Layout.leftMargin: 8; text: shield.status; color: theme.textDim; font.pixelSize: 11; wrapMode: Text.Wrap }
                }
            }
            Setting { label: "Domaines à bloquer en plus"; help: "Un par ligne. Les sous-domaines sont bloqués aussi." }
            Code { key: "privacy/blocked"; placeholder: "pubs.exemple.com\ntraceur.net"; Layout.preferredHeight: 90 }
            Setting { label: "Sites sans bouclier"; help: "Un par ligne. Aussi réglable depuis le bouclier de la barre d'adresse." }
            Code { key: "privacy/allowed"; placeholder: "monjournal.fr"; Layout.preferredHeight: 90 }
            Divider {}
            Toggle { key: "privacy/dnt"; label: "Demander de ne pas être pisté"; help: "Envoie Do Not Track et Global Privacy Control. Ce n'est qu'une demande, que certains sites respectent (et que la loi impose parfois)." }
            Toggle { key: "privacy/httpsUpgrade"; label: "HTTPS uniquement"; help: "Passe en https:// toute adresse en http://. Les rares sites sans HTTPS ne s'ouvriront plus." }
            Toggle { key: "privacy/thirdPartyCookies"; label: "Autoriser les cookies tiers"; help: "Désactivé, un site ne peut pas déposer de cookie quand il est inclus dans un autre : c'est ainsi que les traceurs suivent d'un site à l'autre." }
            Choice { key: "privacy/cookies"; label: "Cookies des sites"; help: "« Pour la session » : effacés à la fermeture, donc reconnexion à chaque fois."; options: [["persistent", "Gardés", "check"], ["session", "Pour la session", "clock"]] }
            Choice { key: "privacy/permissions"; label: "Caméra, micro, position, notifications…"; options: [["ask", "Demander", "chat"], ["deny", "Toujours refuser", "close"]] }
            Toggle { key: "privacy/history"; label: "Garder l'historique" }
            Divider {}
            Subheading { text: "À la fermeture, effacer" }
            Toggle { key: "privacy/clearHistoryOnExit"; label: "L'historique" }
            Toggle { key: "privacy/clearCookiesOnExit"; label: "Les cookies (déconnecte des sites)" }
            Toggle { key: "privacy/clearCacheOnExit"; label: "Le cache" }
            Subheading { text: "Effacer maintenant" }
            Flow {
                Layout.fillWidth: true
                spacing: 8
                Button { text: "L'historique"; onClicked: { library.clearHistory(0); dialog.win.flash("Historique effacé.") } }
                Button { text: "Les cookies"; onClicked: { browser.clearCookies(); dialog.win.flash("Cookies effacés.") } }
                Button { text: "Le cache"; onClicked: { browser.clearCache(); dialog.win.flash("Cache vidé.") } }
                Button { text: "Les icônes de sites"; onClicked: { favicons.clear(); dialog.win.flash("Icônes effacées.") } }
                Button { text: "Les téléchargements (liste)"; onClicked: library.clearDownloads() }
            }
        }
    }

    // ------------------------------------------------------------ web
    Component {
        id: webPage
        ColumnLayout {
            spacing: 18
            Heading { title: "Contenu web"; intro: "Comment les pages s'affichent et ce qu'elles ont le droit de faire." }
            Choice { key: "web/scheme"; label: "Clair ou sombre pour les sites"; help: "Ce que les sites voient de tes préférences : ceux qui ont un thème sombre l'utilisent."; options: [["flair", "Comme Flair Web", "sparkle"], ["light", "Clair", "sun"], ["dark", "Sombre", "moon"]] }
            Toggle { key: "web/forceDark"; label: "Mode sombre forcé"; help: "Assombrit toutes les pages, même celles qui n'ont pas de mode sombre (Alt+Maj+N)." }
            Setting {
                label: "Zoom par défaut"
                help: "Chaque site garde son propre zoom si tu le changes (Ctrl+= et Ctrl+-)."
                ComboBox {
                    width: 120
                    readonly property var levels: [0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]
                    model: levels.map(l => Math.round(l * 100) + " %")
                    currentIndex: levels.findIndex(l => Math.abs(l - dialog.v("web/zoom")) < 0.001)
                    onActivated: (i) => settings.set("web/zoom", levels[i])
                }
            }
            Toggle { key: "web/javascript"; label: "JavaScript"; help: "Désactivé, beaucoup de sites ne fonctionnent plus, mais tout est plus léger." }
            Toggle { key: "web/images"; label: "Images" }
            Toggle { key: "web/autoplay"; label: "Lecture automatique des vidéos"; help: "Désactivé, une vidéo avec du son attend un clic pour démarrer." }
            Toggle { key: "web/smoothScroll"; label: "Défilement doux" }
            Toggle { key: "web/scrollbars"; label: "Barres de défilement" }
            Toggle { key: "web/pdf"; label: "Lire les PDF dans le navigateur"; help: "Sinon, ils sont téléchargés." }
            Toggle { key: "web/webgl"; label: "WebGL (3D)" }
            Toggle { key: "web/clipboard"; label: "Les pages peuvent lire le presse-papiers" }
            Toggle { key: "web/spatialNavigation"; label: "Navigation aux flèches"; help: "Les flèches passent d'un lien à l'autre." }
            Toggle { key: "web/dnsPrefetch"; label: "Préchargement DNS"; help: "Un peu plus rapide, un peu plus bavard." }
            Divider {}
            Choice { key: "web/userAgent"; label: "Se présenter comme"; help: "L'identité envoyée aux sites (User-Agent). Utile quand un site refuse un navigateur qu'il ne connaît pas."; options: [["default", "Flair Web (Chromium)", "globe"], ["chrome", "Chrome", "globe"], ["firefox", "Firefox", "globe"], ["safari", "Safari (Mac)", "globe"], ["mobile", "Mobile Android", "phone"], ["custom", "Personnalisé", "pencil"]] }
            TextSetting { visible: dialog.v("web/userAgent") === "custom"; key: "web/customAgent"; label: "User-Agent personnalisé"; fieldWidth: 360; placeholder: "Mozilla/5.0 …" }
            TextSetting { key: "web/language"; label: "Langues des pages"; help: "Dans l'ordre de préférence (en-tête Accept-Language)."; fieldWidth: 320 }
        }
    }

    // ------------------------------------------------------------ style
    Component {
        id: stylePage
        ColumnLayout {
            id: styleColumn
            spacing: 18
            // Parsed again only when the rules themselves change (a new list
            // would rebuild every card, and the field being typed in).
            readonly property string rulesText: dialog.v("style/sites")
            property var rules: { try { return JSON.parse(rulesText) || [] } catch (e) { return [] } }
            function save(list) { settings.set("style/sites", JSON.stringify(list)) }
            Heading { title: "Styles et scripts"; intro: "Ton CSS et ton JavaScript, sur toutes les pages ou site par site. Appliqués au prochain chargement de la page. Un motif comme <b>youtube.com</b> couvre ses sous-domaines ; <b>*.wiki*</b> accepte les jokers." }
            Setting { label: "CSS sur toutes les pages" }
            Code { key: "style/css"; placeholder: "/* exemple */\n::selection { background: orange; }\n* { font-family: Inter !important; }" }
            Setting { label: "JavaScript sur toutes les pages"; help: "Lancé quand la page est prête, dans la page elle-même." }
            Code { key: "style/js"; placeholder: "// exemple\ndocument.querySelectorAll('video').forEach(v => v.playbackRate = 1.25)" }
            Divider {}
            RowLayout {
                Layout.fillWidth: true
                Subheading { text: "Par site" }
                Item { Layout.fillWidth: true }
                PrimaryButton { text: "Ajouter un site"; onClicked: styleColumn.save(styleColumn.rules.concat([{ pattern: "", css: "", js: "", enabled: true }])) }
            }
            Repeater {
                model: styleColumn.rules
                delegate: Card {
                    id: ruleCard
                    required property var modelData
                    required property int index
                    function update(field, value) {
                        const list = styleColumn.rules.slice()
                        list[index] = Object.assign({}, list[index], { [field]: value })
                        styleColumn.save(list)
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        Switch { Material.accent: theme.highlight; checked: ruleCard.modelData.enabled !== false; onToggled: ruleCard.update("enabled", checked) }
                        TextField {
                            Layout.fillWidth: true
                            text: ruleCard.modelData.pattern
                            placeholderText: "site.com"
                            font.family: "monospace"
                            onEditingFinished: if (text.trim() !== ruleCard.modelData.pattern) ruleCard.update("pattern", text.trim())
                        }
                        IconButton {
                            icon: "trash"; tip: "Supprimer"
                            onClicked: { const list = styleColumn.rules.slice(); list.splice(ruleCard.index, 1); styleColumn.save(list) }
                        }
                    }
                    Text { text: "CSS"; color: theme.textFaint; font.pixelSize: 11 }
                    ScrollView {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 90
                        background: Rectangle { radius: 8; color: theme.surface; border.color: cssArea.activeFocus ? theme.highlight : theme.line }
                        TextArea {
                            id: cssArea
                            text: ruleCard.modelData.css || ""
                            font.family: "JetBrains Mono, monospace"; font.pixelSize: 12
                            background: null
                            placeholderText: "#secondary { display: none !important; }"
                            onActiveFocusChanged: if (!activeFocus && text !== (ruleCard.modelData.css || "")) ruleCard.update("css", text)
                        }
                    }
                    Text { text: "JavaScript"; color: theme.textFaint; font.pixelSize: 11 }
                    ScrollView {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 90
                        background: Rectangle { radius: 8; color: theme.surface; border.color: jsArea.activeFocus ? theme.highlight : theme.line }
                        TextArea {
                            id: jsArea
                            text: ruleCard.modelData.js || ""
                            font.family: "JetBrains Mono, monospace"; font.pixelSize: 12
                            background: null
                            placeholderText: "document.title = '…'"
                            onActiveFocusChanged: if (!activeFocus && text !== (ruleCard.modelData.js || "")) ruleCard.update("js", text)
                        }
                    }
                }
            }
            Text {
                visible: styleColumn.rules.length === 0
                text: "Aucun site pour l'instant. Depuis une page, le panneau du site (le cadenas) mène ici avec le site déjà rempli."
                color: theme.textFaint
                font.pixelSize: 12
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
        }
    }

    // ------------------------------------------------------------ downloads
    Component {
        id: downloadsPage
        ColumnLayout {
            spacing: 18
            Heading { title: "Téléchargements"; intro: "Où vont les fichiers, et ce qui se passe ensuite." }
            Setting {
                label: "Dossier"
                help: (settings.revision, settings.downloadDirectory())
                Row {
                    spacing: 6
                    Button { text: "Choisir…"; onClicked: folderDialog.open() }
                    Button { text: "Par défaut"; flat: true; visible: dialog.v("downloads/dir") !== ""; onClicked: settings.reset("downloads/dir") }
                }
            }
            Toggle { key: "downloads/openPanel"; label: "Montrer le panneau au début d'un téléchargement" }
            Choice { key: "downloads/after"; label: "Une fois terminé"; options: [["nothing", "Ne rien faire", "check"], ["open", "Ouvrir le fichier", "external"], ["folder", "Le montrer dans flair", "folder"]] }
        }
    }

    // ------------------------------------------------------------ extensions
    Component {
        id: extensionsPage
        ColumnLayout {
            spacing: 18
            Heading { title: "Extensions"; intro: "Les extensions Chrome (Manifest V3) et les thèmes : depuis le Chrome Web Store (son bouton « Ajouter à Flair Web », ou le lien de la page collé ici), un .crx, un .zip ou un dossier. Flair Web leur fournit ce que Qt WebEngine n'a pas (onglets, menus, badges, scripts, règles de blocage…) : bloqueurs de pub comme uBlock Origin Lite, gestionnaires de mots de passe comme NordPass ou Bitwarden, Dark Reader… Elles ne voient jamais les onglets privés." }
            Text { visible: !browser.extensionsSupported; text: "Cette version de Qt WebEngine ne gère pas les extensions."; color: theme.warning; font.pixelSize: 13 }
            StoreInstall {
                visible: browser.extensionsSupported
                Layout.fillWidth: true
                Layout.maximumWidth: 560
            }
            RowLayout {
                visible: browser.extensionsSupported
                spacing: 8
                Button { text: "Ouvrir le Chrome Web Store"; onClicked: { dialog.close(); dialog.win.openTab("https://chromewebstore.google.com/", {}) } }
                Button { text: "Fichier .crx ou .zip…"; flat: true; onClicked: extensionZipDialog.open() }
                Button { text: "Dossier…"; flat: true; onClicked: extensionFolderDialog.open() }
            }
            Repeater {
                model: browser.extensions.filter(e => e.installed)
                delegate: Card {
                    required property var modelData
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10
                        Item {
                            Layout.preferredWidth: 22; Layout.preferredHeight: 22
                            Image { anchors.fill: parent; source: modelData.icon || ""; sourceSize: Qt.size(44, 44); mipmap: true; visible: status === Image.Ready && !modelData.error }
                            Icon { anchors.centerIn: parent; visible: !modelData.icon || !!modelData.error; name: "puzzle"; size: 20; color: modelData.error ? theme.danger : theme.highlight }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 1
                            Text { Layout.fillWidth: true; text: (modelData.name || modelData.id) + (modelData.version ? "  " + modelData.version : ""); color: theme.text; font.pixelSize: 13; font.weight: Font.DemiBold; elide: Text.ElideRight }
                            Text { Layout.fillWidth: true; visible: text !== ""; text: modelData.error || modelData.description; color: modelData.error ? theme.danger : theme.textDim; font.pixelSize: 11; wrapMode: Text.Wrap }
                        }
                        Switch { Material.accent: theme.highlight; checked: modelData.enabled; onToggled: browser.setExtensionEnabled(modelData.id, checked) }
                        IconButton { icon: "trash"; tip: "Désinstaller"; onClicked: browser.uninstallExtension(modelData.id) }
                    }
                }
            }
            Text {
                visible: browser.extensionsSupported && !browser.extensions.some(e => e.installed)
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: "Aucune extension pour l'instant. Elles s'installent dans " + browser.extensionsPath
                color: theme.textFaint
                font.pixelSize: 12
            }
        }
    }

    // ------------------------------------------------------------ AI
    Component {
        id: aiPage
        ColumnLayout {
            id: aiColumn
            spacing: 18
            property var models: ({})
            Connections {
                target: pageAi
                function onModelsListed(provider, list, error) {
                    const next = Object.assign({}, aiColumn.models)
                    next[provider] = error ? [] : list
                    aiColumn.models = next
                    if (error) dialog.win.flash(error)
                }
            }
            Heading { title: "Assistant IA"; intro: "L'assistant de page (Ctrl+Maj+A) résume, explique ou répond sur la page ouverte. Les clés de flair et de Flair Code sont reprises automatiquement." }
            Choice { key: "ai/provider"; label: "Fournisseur par défaut"; options: [["claude", "Claude", "sparkle"], ["openai", "OpenAI", "sparkle"], ["gemini", "Gemini", "sparkle"], ["local", "Local (LM Studio, Ollama)", "desktop"]] }
            Repeater {
                model: [["claude", "Claude", "ai/claudeModel", "claude-opus-5-5"], ["openai", "OpenAI", "ai/openaiModel", "gpt-…"], ["gemini", "Gemini", "ai/geminiModel", "gemini-…"]]
                delegate: Card {
                    required property var modelData
                    Text { text: modelData[1]; color: theme.text; font.pixelSize: 13; font.weight: Font.DemiBold }
                    RowLayout {
                        Layout.fillWidth: true
                        Text { Layout.preferredWidth: 70; text: "Clé"; color: theme.textDim; font.pixelSize: 12 }
                        TextField {
                            Layout.fillWidth: true
                            echoMode: TextInput.Password
                            enabled: !settings.keyFromEnvironment(modelData[0])
                            placeholderText: settings.keyFromEnvironment(modelData[0]) ? "Fournie par la variable d'environnement"
                                         : ((settings.revision, settings.apiKey(modelData[0])) ? "•••••• (déjà configurée)" : "Colle ta clé ici")
                            onEditingFinished: if (text.trim()) { settings.set("keys/" + modelData[0], text.trim()); text = "" }
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        Text { Layout.preferredWidth: 70; text: "Modèle"; color: theme.textDim; font.pixelSize: 12 }
                        ComboBox {
                            Layout.fillWidth: true
                            editable: true
                            model: aiColumn.models[modelData[0]] || [dialog.v(modelData[2])]
                            editText: dialog.v(modelData[2])
                            onAccepted: settings.set(modelData[2], editText.trim())
                            // A name typed then left (no Enter) is kept too.
                            onActiveFocusChanged: if (!activeFocus && editText.trim() !== "" && editText.trim() !== dialog.v(modelData[2])) settings.set(modelData[2], editText.trim())
                            onActivated: (i) => settings.set(modelData[2], textAt(i))
                        }
                        Button { text: "Charger"; flat: true; enabled: (settings.revision, pageAi.ready(modelData[0])); onClicked: pageAi.listModels(modelData[0]) }
                    }
                }
            }
            Card {
                Text { text: "Local"; color: theme.text; font.pixelSize: 13; font.weight: Font.DemiBold }
                Text { Layout.fillWidth: true; wrapMode: Text.Wrap; color: theme.textDim; font.pixelSize: 12; text: "Tout serveur compatible OpenAI : LM Studio (http://localhost:1234) ou Ollama (http://localhost:11434). Rien ne sort de ta machine." }
                RowLayout {
                    Layout.fillWidth: true
                    Text { Layout.preferredWidth: 70; text: "Adresse"; color: theme.textDim; font.pixelSize: 12 }
                    TextField { Layout.fillWidth: true; text: dialog.v("ai/localUrl"); onEditingFinished: settings.set("ai/localUrl", text.trim()) }
                }
                RowLayout {
                    Layout.fillWidth: true
                    Text { Layout.preferredWidth: 70; text: "Modèle"; color: theme.textDim; font.pixelSize: 12 }
                    ComboBox {
                        Layout.fillWidth: true
                        editable: true
                        model: aiColumn.models["local"] || [dialog.v("ai/localModel")]
                        editText: dialog.v("ai/localModel")
                        onAccepted: settings.set("ai/localModel", editText.trim())
                        onActiveFocusChanged: if (!activeFocus && editText.trim() !== "" && editText.trim() !== dialog.v("ai/localModel")) settings.set("ai/localModel", editText.trim())
                        onActivated: (i) => settings.set("ai/localModel", textAt(i))
                    }
                    Button { text: "Charger"; flat: true; onClicked: pageAi.listModels("local") }
                }
            }
            Choice { key: "ai/language"; label: "Langue des réponses"; options: [["fr", "Français", "globe"], ["en", "English", "globe"]] }
            NumberSetting { key: "ai/pageChars"; label: "Texte de la page envoyé au plus"; help: "Les pages plus longues sont coupées. Plus c'est long, plus c'est lent (et cher)."; from: 8000; to: 200000; step: 4000; unit: " car." }
        }
    }

    // ------------------------------------------------------------ keys
    Component {
        id: keysPage
        ColumnLayout {
            spacing: 14
            Heading { title: "Raccourcis"; intro: "Toutes les commandes sont aussi dans la palette (Ctrl+Maj+P). Ctrl+1 à 8 : l'onglet de ce rang ; Ctrl+9 : le dernier." }
            Repeater {
                model: dialog.win ? [...new Set(dialog.win.commands.map(c => c.category))] : []
                delegate: ColumnLayout {
                    id: category
                    required property string modelData
                    Layout.fillWidth: true
                    spacing: 4
                    Subheading { text: category.modelData }
                    Repeater {
                        model: dialog.win.commands.filter(c => c.category === category.modelData)
                        delegate: RowLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            spacing: 12
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0
                                Text { text: modelData.name; color: theme.text; font.pixelSize: 13 }
                                Text { text: modelData.description; color: theme.textFaint; font.pixelSize: 11 }
                            }
                            Keycap { visible: !!modelData.shortcut; text: modelData.shortcut || "" }
                        }
                    }
                }
            }
        }
    }

    // ------------------------------------------------------------ dialogs
    FileDialog {
        id: imageDialog
        title: "Image de fond"
        nameFilters: ["Images (*.png *.jpg *.jpeg *.webp *.avif *.gif *.bmp)"]
        onAccepted: { settings.set("newtab/image", selectedFile.toString()); settings.set("newtab/background", "image") }
    }
    FolderDialog {
        id: folderDialog
        title: "Dossier des téléchargements"
        onAccepted: settings.set("downloads/dir", browser.localPath(selectedFolder.toString()))
    }
    FolderDialog {
        id: extensionFolderDialog
        title: "Dossier de l'extension (avec manifest.json)"
        onAccepted: browser.installExtension(selectedFolder.toString())
    }
    FileDialog {
        id: extensionZipDialog
        title: "Extension (.crx ou .zip)"
        nameFilters: ["Extensions (*.zip *.crx)"]
        onAccepted: browser.installExtension(selectedFile.toString())
    }
    Connections {
        target: browser
        function onExtensionMessage(message) { if (dialog.win) dialog.win.flash(message) }
    }

    // Adding or editing a search engine.
    Dialog {
        id: engineEditor
        property var engine: null
        parent: Overlay.overlay
        anchors.centerIn: parent
        modal: true
        width: 520
        title: engine ? "Modifier " + engine.name : "Ajouter un moteur"
        background: Rectangle { color: theme.surface; radius: 14; border.color: theme.line }
        function edit(e) {
            engine = e
            nameField.text = e ? e.name : ""
            keywordField.text = e ? (e.keyword || "") : ""
            urlField.text = e ? e.url : ""
            suggestField.text = e ? (e.suggest || "") : ""
            open()
            nameField.forceActiveFocus()
        }
        onAccepted: {
            if (!urlField.text.includes("%s")) { dialog.win.flash("L'adresse doit contenir %s à la place de la recherche."); return }
            if (engine) engines.updateEngine(engine.key, nameField.text, keywordField.text, urlField.text, suggestField.text)
            else engines.addCustom(nameField.text, keywordField.text, urlField.text, suggestField.text)
        }
        footer: DialogButtonBox {
            background: null
            Button { text: "Annuler"; flat: true; DialogButtonBox.buttonRole: DialogButtonBox.RejectRole }
            // Only with a usable address: the dialog would close and lose what was typed.
            PrimaryButton { text: engineEditor.engine ? "Enregistrer" : "Ajouter"; enabled: urlField.text.includes("%s") && nameField.text.trim() !== ""; DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole }
        }
        ColumnLayout {
            anchors.fill: parent
            spacing: 6
            Text { text: "Nom"; color: theme.textDim; font.pixelSize: 12 }
            TextField { id: nameField; Layout.fillWidth: true; placeholderText: "Mon moteur" }
            Text { text: "Mot-clé"; color: theme.textDim; font.pixelSize: 12 }
            TextField { id: keywordField; Layout.fillWidth: true; placeholderText: "mm  (puis « mm ma recherche »)" }
            Text { text: "Adresse de recherche (%s = ce que tu cherches)"; color: theme.textDim; font.pixelSize: 12 }
            TextField { id: urlField; Layout.fillWidth: true; placeholderText: "https://exemple.com/search?q=%s"; font.family: "monospace" }
            Text { text: "Adresse des suggestions (facultatif, format OpenSearch)"; color: theme.textDim; font.pixelSize: 12 }
            TextField { id: suggestField; Layout.fillWidth: true; placeholderText: "https://exemple.com/suggest?q=%s"; font.family: "monospace" }
        }
    }
}
