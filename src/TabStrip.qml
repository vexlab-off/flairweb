import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Tabs across the top, like Flair Code's: pinned tabs as icons first, the
// others share the width. The wheel scrolls through them.
Rectangle {
    id: strip
    property var win: null
    color: theme.sidebar
    implicitHeight: 38

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 6
        anchors.rightMargin: 6
        spacing: 4

        ListView {
            id: list
            // As wide as the tabs need, up to the room left by the + button:
            // the button follows the last tab.
            readonly property real available: Math.max(0, strip.width - 12 - 34)
            Layout.preferredWidth: Math.min(available, pinnedCount * 43 + unpinned * (tabWidth + 3))
            Layout.fillHeight: true
            orientation: ListView.Horizontal
            clip: true
            spacing: 3
            model: strip.win ? strip.win.tabs : []
            boundsBehavior: Flickable.StopAtBounds
            readonly property int unpinned: strip.win ? strip.win.tabs.filter(t => !t.pinned).length : 0
            readonly property int pinnedCount: count - unpinned
            readonly property real tabWidth: Math.max(96, Math.min(230, (available - pinnedCount * 43) / Math.max(1, unpinned) - 3))
            // The current tab always in view: a new one, or one chosen with
            // the keyboard, after a resize too.
            function reveal() {
                if (!strip.win) return
                const i = strip.win.tabs.indexOf(strip.win.currentTab)
                if (i >= 0) positionViewAtIndex(i, ListView.Contain)
            }
            Connections {
                target: strip.win
                function onCurrentTabChanged() { Qt.callLater(list.reveal) }
                function onTabsChanged() { Qt.callLater(list.reveal) }
            }
            onWidthChanged: Qt.callLater(reveal)
            property var dragging: null
            property int dropIndex: -1

            delegate: Item {
                id: cell
                required property var modelData
                required property int index
                readonly property bool active: strip.win.currentTab === modelData
                // Hover of the whole tab, buttons included (a HoverHandler
                // never takes the hover away from them).
                readonly property bool hovered: cellHover.hovered
                width: modelData.pinned ? 40 : list.tabWidth
                height: list.height
                HoverHandler { id: cellHover }
                Rectangle {
                    anchors.fill: parent
                    anchors.topMargin: 5
                    anchors.bottomMargin: 4
                    radius: 8
                    color: cell.active ? theme.surface : (cell.hovered ? theme.alpha(theme.text, 0.05) : "transparent")
                    border.color: cell.active ? theme.alpha(theme.text, theme.isDark ? 0.08 : 0.06) : "transparent"
                    opacity: list.dragging === cell.modelData ? 0.5 : 1
                    Rectangle {
                        visible: cell.active
                        anchors.bottom: parent.bottom
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: Math.min(parent.width - 16, 28); height: 2; radius: 1
                        color: theme.highlight
                    }
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: cell.modelData.pinned ? 0 : 10
                        anchors.rightMargin: cell.modelData.pinned ? 0 : 4
                        spacing: 8
                        Item {
                            Layout.preferredWidth: 16; Layout.preferredHeight: 16
                            Layout.fillWidth: cell.modelData.pinned
                            Favicon {
                                anchors.centerIn: parent
                                url: cell.modelData.url
                                source: cell.modelData.icon
                                loading: cell.modelData.loading
                                size: 16
                                opacity: cell.modelData.sleeping ? 0.45 : 1
                            }
                            Rectangle {
                                visible: cell.modelData.isPrivate
                                anchors.right: parent.right; anchors.bottom: parent.bottom
                                anchors.rightMargin: -4; anchors.bottomMargin: -4
                                width: 11; height: 11; radius: 5.5
                                color: "#9b7bff"
                                Icon { anchors.centerIn: parent; name: "mask"; size: 8; color: "white"; stroke: 2 }
                            }
                        }
                        Text {
                            visible: !cell.modelData.pinned
                            Layout.fillWidth: true
                            text: cell.modelData.title
                            color: cell.active ? theme.text : (cell.modelData.sleeping ? theme.textFaint : theme.textDim)
                            font.pixelSize: 12
                            font.weight: cell.active ? Font.Medium : Font.Normal
                            elide: Text.ElideRight
                        }
                        Rectangle {
                            visible: !cell.modelData.pinned && (cell.modelData.audible || cell.modelData.muted)
                            Layout.preferredWidth: 20; Layout.preferredHeight: 20; radius: 5
                            color: muteHit.containsMouse ? theme.raised : "transparent"
                            Icon { anchors.centerIn: parent; name: cell.modelData.muted ? "mute" : "volume"; size: 12; color: theme.highlight }
                            MouseArea { id: muteHit; anchors.fill: parent; hoverEnabled: true; onClicked: cell.modelData.toggleMute() }
                        }
                        Rectangle {
                            readonly property string mode: (settings.revision, settings.value("tabs/closeButton"))
                            visible: !cell.modelData.pinned && mode !== "never" && (mode === "always" || cell.hovered || cell.active)
                            Layout.preferredWidth: 20; Layout.preferredHeight: 20; radius: 5
                            color: closeHit.containsMouse ? theme.raised : "transparent"
                            Icon { anchors.centerIn: parent; name: "close"; size: 10; color: theme.textDim }
                            ToolTip.visible: closeHit.containsMouse
                            ToolTip.text: "Fermer l'onglet (Ctrl+W)"
                            ToolTip.delay: 700
                            MouseArea {
                                id: closeHit
                                anchors.fill: parent
                                anchors.margins: -2
                                hoverEnabled: true
                                acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                                onClicked: strip.win.closeTab(cell.modelData)
                            }
                        }
                    }
                }
                Rectangle {
                    visible: list.dropIndex === cell.index && list.dragging !== null
                    x: -2; width: 2; height: parent.height - 12; y: 6; radius: 1
                    color: theme.highlight
                }
                ToolTip.visible: cell.hovered && !closeHit.containsMouse && !muteHit.containsMouse && !list.dragging
                ToolTip.text: cell.modelData.title
                ToolTip.delay: 800
                // Under the tab's buttons (z -1): they get their own clicks.
                MouseArea {
                    id: hit
                    anchors.fill: parent
                    z: -1
                    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                    preventStealing: true
                    property real startX: 0
                    onPressed: (mouse) => { startX = mouse.x; if (mouse.button === Qt.LeftButton) strip.win.selectTab(cell.modelData) }
                    onPositionChanged: (mouse) => {
                        if (!(pressedButtons & Qt.LeftButton)) return
                        if (list.dragging === null && Math.abs(mouse.x - startX) > 8) list.dragging = cell.modelData
                        if (list.dragging !== null) {
                            const p = cell.mapToItem(list.contentItem, mouse.x, mouse.y)
                            let over = list.indexAt(p.x, 10)
                            if (over < 0) over = list.indexAt(p.x - list.spacing - 1, 10)
                            list.dropIndex = over < 0 ? list.count : (p.x - list.itemAtIndex(over).x > list.itemAtIndex(over).width / 2 ? over + 1 : over)
                        }
                    }
                    onReleased: {
                        if (list.dragging !== null) {
                            const target = list.dropIndex < list.count ? strip.win.tabs[list.dropIndex] : null
                            strip.win.moveTabBefore(list.dragging, target)
                        }
                        list.dragging = null
                        list.dropIndex = -1
                    }
                    onClicked: (mouse) => {
                        if (mouse.button === Qt.RightButton) { const p = cell.mapToItem(null, mouse.x, mouse.y); strip.win.showTabMenu(cell.modelData, p.x, p.y) }
                        else if (mouse.button === Qt.MiddleButton) strip.win.closeTab(cell.modelData)
                    }
                    onWheel: (wheel) => {
                        const d = wheel.angleDelta.y !== 0 ? wheel.angleDelta.y : wheel.angleDelta.x
                        list.contentX = Math.max(0, Math.min(list.contentWidth - list.width, list.contentX - d))
                    }
                }
            }
            MouseArea {
                anchors.fill: parent
                z: -1
                acceptedButtons: Qt.LeftButton
                onDoubleClicked: strip.win.openTab("", {})
            }
        }
        // New tab, right after the tabs (never scrolled out of sight).
        IconButton {
            Layout.alignment: Qt.AlignVCenter
            icon: "plus"; tip: "Nouvel onglet (Ctrl+T) · clic droit : onglet privé"
            onClicked: strip.win.openTab("", {})
            onRightClicked: strip.win.openTab("", { private: true })
        }
        // The empty rest of the strip: a double click opens a tab.
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            MouseArea { anchors.fill: parent; onDoubleClicked: strip.win.openTab("", {}) }
        }
    }
    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: theme.line }
}
