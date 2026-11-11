import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Vertical tabs: pinned sites as a grid of icons on top, then the open tabs,
// which can be dragged to reorder. In compact mode only the icons remain.
Rectangle {
    id: side
    property var win: null
    readonly property bool compact: (settings.revision, settings.value("tabs/compact"))
    // The width while the edge is being dragged; saved on release.
    property real dragWidth: -1
    readonly property var pinned: win ? win.tabs.filter(t => t.pinned) : []
    readonly property var others: win ? win.tabs.filter(t => !t.pinned) : []
    color: theme.sidebar

    ColumnLayout {
        anchors.fill: parent
        anchors.topMargin: 8
        anchors.bottomMargin: 8
        spacing: 6

        // Pinned.
        Flow {
            visible: side.pinned.length > 0
            Layout.fillWidth: true
            Layout.leftMargin: 8
            Layout.rightMargin: 8
            spacing: 6
            Repeater {
                model: side.pinned
                delegate: Rectangle {
                    id: pin
                    required property var modelData
                    readonly property bool active: side.win.currentTab === modelData
                    width: side.compact ? side.width - 16 : Math.floor((side.width - 16 - 6 * 3) / 4)
                    height: 38
                    radius: 9
                    color: active ? theme.surface : (pinHover.containsMouse ? theme.alpha(theme.text, 0.05) : theme.alpha(theme.text, 0.03))
                    border.color: active ? theme.alpha(theme.highlight, 0.6) : "transparent"
                    Favicon {
                        anchors.centerIn: parent
                        url: pin.modelData.url
                        source: pin.modelData.icon
                        loading: pin.modelData.loading
                        size: 18
                        opacity: pin.modelData.sleeping ? 0.5 : 1
                    }
                    Rectangle {
                        visible: pin.modelData.audible || pin.modelData.muted
                        anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: 2
                        width: 14; height: 14; radius: 7
                        color: theme.surface
                        Icon { anchors.centerIn: parent; name: pin.modelData.muted ? "mute" : "volume"; size: 10; color: theme.highlight }
                    }
                    ToolTip.visible: pinHover.containsMouse
                    ToolTip.text: pin.modelData.title
                    ToolTip.delay: 500
                    MouseArea {
                        id: pinHover
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                        onClicked: (mouse) => {
                            if (mouse.button === Qt.RightButton) { const p = pin.mapToItem(null, mouse.x, mouse.y); side.win.showTabMenu(pin.modelData, p.x, p.y) }
                            else if (mouse.button === Qt.MiddleButton) side.win.closeTab(pin.modelData)
                            else side.win.selectTab(pin.modelData)
                        }
                    }
                }
            }
        }
        Rectangle { visible: side.pinned.length > 0; Layout.fillWidth: true; Layout.leftMargin: 12; Layout.rightMargin: 12; height: 1; color: theme.line }

        // New tab.
        Rectangle {
            Layout.fillWidth: true
            Layout.leftMargin: 8
            Layout.rightMargin: 8
            Layout.preferredHeight: 32
            radius: 8
            color: newHover.containsMouse ? theme.alpha(theme.text, 0.05) : "transparent"
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: side.compact ? 0 : 10
                spacing: 10
                // Centred in the compact column (a stretched Icon draws at its left edge).
                Item {
                    Layout.fillWidth: side.compact
                    Layout.preferredWidth: 15
                    Layout.preferredHeight: 15
                    Icon { anchors.centerIn: parent; name: "plus"; size: 15; color: theme.textDim }
                }
                Text { visible: !side.compact; Layout.fillWidth: true; text: "Nouvel onglet"; color: theme.textDim; font.pixelSize: 13 }
                Keycap { visible: !side.compact && newHover.containsMouse; text: "Ctrl+T"; Layout.rightMargin: 8 }
            }
            ToolTip.visible: side.compact && newHover.containsMouse
            ToolTip.text: "Nouvel onglet (Ctrl+T)"
            MouseArea { id: newHover; anchors.fill: parent; hoverEnabled: true; onClicked: side.win.openTab("", {}) }
        }

        // Tabs.
        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 2
            model: side.others
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            property int dropIndex: -1
            property var dragging: null
            // The current tab always in view (a new one, Ctrl+Tab, a resize).
            function reveal() {
                const i = side.others.indexOf(side.win ? side.win.currentTab : null)
                if (i >= 0) positionViewAtIndex(i, ListView.Contain)
            }
            Connections {
                target: side.win
                function onCurrentTabChanged() { Qt.callLater(list.reveal) }
            }
            onCountChanged: Qt.callLater(reveal)
            onHeightChanged: Qt.callLater(reveal)

            delegate: Item {
                id: row
                required property var modelData
                required property int index
                readonly property bool active: side.win.currentTab === modelData
                readonly property bool hovered: rowHoverHandler.hovered
                width: ListView.view.width
                height: 34
                HoverHandler { id: rowHoverHandler }
                Rectangle {
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    radius: 8
                    color: row.active ? theme.surface : (row.hovered ? theme.alpha(theme.text, 0.05) : "transparent")
                    border.color: row.active ? theme.alpha(theme.text, theme.isDark ? 0.08 : 0.06) : "transparent"
                    opacity: list.dragging === row.modelData ? 0.5 : 1
                    Rectangle {
                        visible: row.active
                        x: -6; width: 3; height: 16; radius: 1.5
                        anchors.verticalCenter: parent.verticalCenter
                        color: theme.highlight
                    }
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: side.compact ? 0 : 9
                        anchors.rightMargin: side.compact ? 0 : 5
                        spacing: 9
                        Item {
                            Layout.preferredWidth: 16
                            Layout.preferredHeight: 16
                            Layout.alignment: Qt.AlignVCenter
                            Layout.fillWidth: side.compact
                            Favicon {
                                anchors.centerIn: parent
                                url: row.modelData.url
                                source: row.modelData.icon
                                loading: row.modelData.loading
                                size: 16
                                opacity: row.modelData.sleeping ? 0.45 : 1
                            }
                            Rectangle {
                                visible: row.modelData.isPrivate
                                anchors.right: parent.right; anchors.bottom: parent.bottom
                                anchors.rightMargin: -4; anchors.bottomMargin: -4
                                width: 11; height: 11; radius: 5.5
                                color: "#9b7bff"
                                Icon { anchors.centerIn: parent; name: "mask"; size: 8; color: "white"; stroke: 2 }
                            }
                        }
                        Text {
                            visible: !side.compact
                            Layout.fillWidth: true
                            text: row.modelData.title
                            color: row.active ? theme.text : (row.modelData.sleeping ? theme.textFaint : theme.textDim)
                            font.pixelSize: 13
                            font.weight: row.active ? Font.Medium : Font.Normal
                            elide: Text.ElideRight
                        }
                        Rectangle {
                            visible: !side.compact && (row.modelData.audible || row.modelData.muted)
                            Layout.preferredWidth: 22; Layout.preferredHeight: 22; radius: 6
                            color: muteHover.containsMouse ? theme.raised : "transparent"
                            Icon { anchors.centerIn: parent; name: row.modelData.muted ? "mute" : "volume"; size: 13; color: theme.highlight }
                            MouseArea { id: muteHover; anchors.fill: parent; hoverEnabled: true; onClicked: row.modelData.toggleMute() }
                        }
                        Rectangle {
                            readonly property string mode: (settings.revision, settings.value("tabs/closeButton"))
                            visible: !side.compact && mode !== "never" && (mode === "always" || row.hovered || row.active)
                            Layout.preferredWidth: 22; Layout.preferredHeight: 22; radius: 6
                            color: closeHover.containsMouse ? theme.raised : "transparent"
                            Icon { anchors.centerIn: parent; name: "close"; size: 11; color: theme.textDim }
                            ToolTip.visible: closeHover.containsMouse
                            ToolTip.text: "Fermer l'onglet (Ctrl+W)"
                            ToolTip.delay: 700
                            MouseArea {
                                id: closeHover
                                anchors.fill: parent
                                anchors.margins: -2
                                hoverEnabled: true
                                acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                                onClicked: side.win.closeTab(row.modelData)
                            }
                        }
                    }
                }
                // Insertion line while dragging.
                Rectangle {
                    visible: list.dropIndex === row.index && list.dragging !== null
                    x: 10; width: parent.width - 20; height: 2; radius: 1
                    y: -2
                    color: theme.highlight
                }
                ToolTip.visible: row.hovered && side.compact && !list.dragging
                ToolTip.text: row.modelData.title + "\n" + row.modelData.url
                ToolTip.delay: 700
                // Under the row's buttons (z -1): they get their own clicks.
                MouseArea {
                    id: rowHover
                    anchors.fill: parent
                    z: -1
                    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                    preventStealing: true
                    property real startY: 0
                    onPressed: (mouse) => { startY = mouse.y; if (mouse.button === Qt.LeftButton) side.win.selectTab(row.modelData) }
                    onPositionChanged: (mouse) => {
                        if (!(pressedButtons & Qt.LeftButton)) return
                        if (list.dragging === null && Math.abs(mouse.y - startY) > 6) list.dragging = row.modelData
                        if (list.dragging !== null) {
                            const p = row.mapToItem(list.contentItem, mouse.x, mouse.y)
                            list.dropIndex = Math.max(0, Math.min(list.count, Math.round(p.y / 36)))
                        }
                    }
                    onReleased: {
                        if (list.dragging !== null) {
                            const target = list.dropIndex < list.count ? side.others[list.dropIndex] : null
                            side.win.moveTabBefore(list.dragging, target)
                        }
                        list.dragging = null
                        list.dropIndex = -1
                    }
                    onClicked: (mouse) => {
                        if (mouse.button === Qt.RightButton) { const p = row.mapToItem(null, mouse.x, mouse.y); side.win.showTabMenu(row.modelData, p.x, p.y) }
                        else if (mouse.button === Qt.MiddleButton) side.win.closeTab(row.modelData)
                    }
                }
            }
            // Insertion line at the end.
            footer: Item {
                width: list.width
                height: 40
                Rectangle {
                    visible: list.dropIndex === list.count && list.dragging !== null
                    x: 10; width: parent.width - 20; height: 2; radius: 1
                    color: theme.highlight
                }
                MouseArea {
                    anchors.fill: parent
                    onDoubleClicked: side.win.openTab("", {})
                }
            }
        }

        // Bottom: tabs count and the private tab.
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 8
            Layout.rightMargin: 8
            spacing: 4
            visible: !side.compact
            IconButton { icon: "mask"; tip: "Onglet privé (Ctrl+Maj+N)"; onClicked: side.win.openTab("", { private: true }) }
            IconButton { icon: "undo"; tip: "Rouvrir l'onglet fermé (Ctrl+Maj+T)"; enabledButton: side.win && side.win.closedTabs.length > 0; onClicked: side.win.reopenClosed() }
            Item { Layout.fillWidth: true }
            Text {
                text: side.win ? side.win.tabs.length + " onglet" + (side.win.tabs.length > 1 ? "s" : "") : ""
                color: theme.textFaint
                font.pixelSize: 11
            }
        }
        IconButton {
            visible: side.compact
            Layout.alignment: Qt.AlignHCenter
            icon: "mask"; tip: "Onglet privé (Ctrl+Maj+N)"
            onClicked: side.win.openTab("", { private: true })
        }
    }
    Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: theme.line }

    // Resize the sidebar by dragging its edge.
    MouseArea {
        visible: !side.compact
        anchors.right: parent.right
        width: 6
        height: parent.height
        cursorShape: Qt.SizeHorCursor
        property real startX: 0
        property real startWidth: 0
        onPressed: (mouse) => { startX = mapToItem(null, mouse.x, 0).x; startWidth = side.width }
        onPositionChanged: (mouse) => {
            if (!pressed) return
            const dx = mapToItem(null, mouse.x, 0).x - startX
            side.dragWidth = Math.round(Math.max(170, Math.min(440, startWidth + dx)))
        }
        onReleased: {
            if (side.dragWidth > 0) settings.set("tabs/sideWidth", side.dragWidth)
            side.dragWidth = -1
        }
    }
}
