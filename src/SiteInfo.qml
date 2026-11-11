import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import QtQuick.Window
import QtWebEngine

// About the site in the current tab: its connection, the shield (what it
// blocked, on or off here), zoom, remembered permissions, and a shortcut to
// give it its own style or script.
Popup {
    id: info
    property var win: null
    readonly property var tab: win ? win.currentTab : null
    readonly property string url: tab ? tab.url : ""
    readonly property string host: url.replace(/^[a-z\-]+:\/\/(www\.)?/i, "").split(/[\/?#:]/)[0]
    property var permissions: []
    width: 340
    padding: 14
    background: Rectangle { color: theme.surface; radius: 12; border.color: theme.line }

    function refresh() {
        const origin = url.replace(/^([a-z]+:\/\/[^\/?#]+).*$/i, "$1")
        try {
            permissions = tab && !tab.isPrivate ? browser.profile.listPermissionsForOrigin(origin)
                .filter(p => p.state !== WebEnginePermission.State.Ask) : []
        } catch (e) { permissions = [] }
    }
    onOpened: refresh()
    // Opens under the button clicked (the lock on the left, the shield on
    // the right), inside the window. A click on that button while the panel
    // is open closes it: the press outside already did, don't reopen.
    property real closedAt: 0
    property var lastAnchor: null
    onClosed: closedAt = Date.now()
    function toggle(anchor) {
        if (lastAnchor === anchor && Date.now() - closedAt < 300) return
        if (opened) { close(); return }
        lastAnchor = anchor
        const host = parent
        const window = host ? host.Window.window : null
        const p = anchor.mapToItem(host, 0, anchor.height + 8)
        const maxX = window ? window.width - host.mapToItem(null, 0, 0).x - width - 8 : p.x
        // Centred on the button when there is room, never past the edges.
        x = Math.max(-host.mapToItem(null, 0, 0).x + 8, Math.min(p.x + anchor.width / 2 - width / 2, maxX))
        y = p.y
        open()
    }

    contentItem: ColumnLayout {
        spacing: 10
        RowLayout {
            spacing: 10
            Favicon { url: info.url; source: info.tab ? info.tab.icon : ""; size: 22 }
            ColumnLayout {
                spacing: 1
                Text { Layout.maximumWidth: 260; text: info.host || "Page locale"; color: theme.text; font.pixelSize: 14; font.weight: Font.Bold; elide: Text.ElideRight }
                Text {
                    text: info.tab && info.tab.security === "secure" ? "Connexion chiffrée (HTTPS)"
                        : info.tab && info.tab.security === "insecure" ? "Connexion non chiffrée : évite d'y saisir des mots de passe"
                        : info.tab && info.tab.security === "file" ? "Fichier sur cet ordinateur" : "Page interne"
                    color: info.tab && info.tab.security === "insecure" ? theme.warning : theme.textDim
                    font.pixelSize: 11
                    wrapMode: Text.Wrap
                    Layout.maximumWidth: 260
                }
            }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: theme.line }

        // Shield.
        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            Icon { name: "shieldCheck"; size: 17; color: shieldSwitch.checked ? theme.success : theme.textFaint }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1
                Text { text: "Bouclier sur ce site"; color: theme.text; font.pixelSize: 13; font.weight: Font.DemiBold }
                Text {
                    text: !shield.active() ? "Désactivé partout (Réglages → Confidentialité)"
                        : (info.tab ? info.tab.blocked : 0) + " pubs et traceurs bloqués sur cette page"
                    color: theme.textDim; font.pixelSize: 11
                }
            }
            Switch {
                id: shieldSwitch
                Material.accent: theme.highlight
                enabled: shield.active()
                checked: (settings.revision, shield.active() && !shield.isAllowed(info.url))
                onToggled: {
                    shield.setAllowed(info.url, !checked)
                    if (info.tab) info.tab.reload(false)
                }
            }
        }
        ListView {
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(contentHeight, 110)
            visible: count > 0
            clip: true
            model: info.opened && info.tab ? (info.tab.blocked, shield.blockedHostsOn(info.url)) : []
            delegate: Text {
                required property string modelData
                width: ListView.view.width
                text: modelData
                color: theme.textFaint
                font.pixelSize: 11
                font.family: "monospace"
                elide: Text.ElideMiddle
            }
            ScrollBar.vertical: ScrollBar {}
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: theme.line }

        // Zoom.
        RowLayout {
            Layout.fillWidth: true
            spacing: 6
            Icon { name: "zoomIn"; size: 16; color: theme.textDim }
            Text { Layout.fillWidth: true; text: "Zoom de ce site"; color: theme.text; font.pixelSize: 13 }
            IconButton { icon: "minus"; tip: "Réduire (Ctrl+-)"; onClicked: info.win.zoom(-1) }
            Text { text: info.tab ? Math.round(info.tab.zoom * 100) + " %" : ""; color: theme.textDim; font.pixelSize: 12; font.features: { "tnum": 1 } }
            IconButton { icon: "plus"; tip: "Agrandir (Ctrl+=)"; onClicked: info.win.zoom(1) }
        }

        // Permissions remembered for this site.
        ColumnLayout {
            visible: info.permissions.length > 0
            Layout.fillWidth: true
            spacing: 4
            Rectangle { Layout.fillWidth: true; height: 1; color: theme.line }
            Text { text: "Autorisations"; color: theme.textFaint; font.pixelSize: 10; font.weight: Font.DemiBold; font.capitalization: Font.AllUppercase; font.letterSpacing: 0.6 }
            Repeater {
                model: info.permissions
                delegate: RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 8
                    Icon { name: info.win.permissionIcon(modelData.permissionType); size: 15; color: theme.textDim }
                    Text { Layout.fillWidth: true; text: info.win.permissionName(modelData.permissionType); color: theme.text; font.pixelSize: 12 }
                    Text { text: modelData.state === WebEnginePermission.State.Granted ? "autorisé" : "refusé"; color: modelData.state === WebEnginePermission.State.Granted ? theme.success : theme.danger; font.pixelSize: 11 }
                    Button { text: "Oublier"; flat: true; onClicked: { modelData.reset(); info.refresh() } }
                }
            }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: theme.line }
        RowLayout {
            Layout.fillWidth: true
            spacing: 4
            Button {
                text: "Style et script du site…"
                flat: true
                onClicked: { info.close(); info.win.openSettings("style", info.host) }
            }
            Item { Layout.fillWidth: true }
            Button {
                text: "Copier l'adresse"
                flat: true
                onClicked: { browser.copy(info.url); info.close(); info.win.flash("Adresse copiée.") }
            }
        }
    }
}
