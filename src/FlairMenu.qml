import QtQuick
import QtQuick.Controls

// A menu in the suite's style, built from plain objects:
// {text, icon, engine, image, shortcut, run, enabled, checked, danger, color}
// {separator: true} or {header: "Titre"}. Opens at scene coordinates.
Popup {
    id: menu
    property var items: []
    property int current: -1
    parent: Overlay.overlay
    padding: 5
    modal: false
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    property real menuWidth: 0
    implicitWidth: Math.max(210, Math.min(460, menuWidth + leftPadding + rightPadding))

    TextMetrics { id: textMetrics; font.pixelSize: 13 }
    TextMetrics { id: shortcutMetrics; font.pixelSize: 11 }
    // The widest row: icon, text (at most 300 px), shortcut.
    function measure(list) {
        let w = 0
        for (const i of list) {
            if (i.separator) continue
            textMetrics.text = i.header || i.text || ""
            shortcutMetrics.text = i.shortcut || ""
            w = Math.max(w, Math.min(300, textMetrics.advanceWidth) + 46 + (i.shortcut ? shortcutMetrics.advanceWidth + 28 : 0))
        }
        return Math.ceil(w)
    }
    background: Rectangle {
        color: theme.surface
        radius: 10
        border.color: theme.line
    }
    enter: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 90 } }

    function show(list, sx, sy) {
        items = list.filter(i => i && i.visible !== false)
        menuWidth = measure(items)
        current = -1
        const w = Overlay.overlay ? Overlay.overlay.width : 800
        const h = Overlay.overlay ? Overlay.overlay.height : 600
        open()
        const mw = implicitWidth
        const mh = column.implicitHeight + topPadding + bottomPadding
        x = Math.max(6, Math.min(sx, w - mw - 6))
        y = sy + mh > h - 6 ? Math.max(6, sy - mh) : sy
    }
    // Opens under an item, aligned to its left (or right) edge.
    function showBelow(item, list, alignRight) {
        const p = item.mapToItem(null, 0, item.height + 4)
        show(list, alignRight ? p.x + item.width - implicitWidth : p.x, p.y)
    }
    function trigger(i) {
        const item = items[i]
        if (!item || item.separator || item.header || item.enabled === false) return
        close()
        if (item.run) Qt.callLater(item.run)
    }
    function step(d) {
        let i = current
        for (let n = 0; n < items.length; ++n) {
            i = (i + d + items.length) % items.length
            const it = items[i]
            if (!it.separator && !it.header && it.enabled !== false) { current = i; return }
        }
    }

    contentItem: Item {
        implicitWidth: column.implicitWidth
        implicitHeight: column.implicitHeight
        focus: true
        Keys.onDownPressed: menu.step(1)
        Keys.onUpPressed: menu.step(-1)
        Keys.onReturnPressed: menu.trigger(menu.current)
        Keys.onEnterPressed: menu.trigger(menu.current)
        Column {
            id: column
            width: parent.width
            Repeater {
                model: menu.items
                delegate: Loader {
                    required property var modelData
                    required property int index
                    width: column.width
                    sourceComponent: modelData.separator ? separator : modelData.header ? header : row
                    property var entry: modelData
                    property int entryIndex: index
                }
            }
        }
    }

    Component {
        id: separator
        Item {
            implicitWidth: 10
            implicitHeight: 9
            Rectangle { anchors.centerIn: parent; width: parent.width - 8; height: 1; color: theme.line }
        }
    }
    Component {
        id: header
        Text {
            text: parent ? parent.entry.header : ""
            leftPadding: 10
            topPadding: 6
            bottomPadding: 3
            color: theme.textFaint
            font.pixelSize: 10
            font.weight: Font.DemiBold
            font.letterSpacing: 0.6
            font.capitalization: Font.AllUppercase
        }
    }
    Component {
        id: row
        Rectangle {
            id: rowItem
            readonly property var entry: parent ? parent.entry : ({})
            readonly property int entryIndex: parent ? parent.entryIndex : -1
            readonly property bool enabledItem: entry.enabled !== false
            implicitWidth: rowContent.implicitWidth + 20
            implicitHeight: 30
            radius: 6
            color: (menu.current === entryIndex || hover.containsMouse) && enabledItem ? theme.alpha(theme.highlight, 0.14) : "transparent"
            Row {
                id: rowContent
                anchors.verticalCenter: parent.verticalCenter
                x: 10
                spacing: 10
                Item {
                    width: 16; height: 16
                    anchors.verticalCenter: parent.verticalCenter
                    Icon {
                        anchors.centerIn: parent
                        visible: !!rowItem.entry.icon && !rowItem.entry.image
                        name: rowItem.entry.checked === true ? "check" : (rowItem.entry.icon || "file")
                        size: 15
                        color: rowItem.entry.danger ? theme.danger : (rowItem.entry.color ? rowItem.entry.color : (rowItem.entry.checked === true ? theme.highlight : theme.textDim))
                        opacity: rowItem.enabledItem ? 1 : 0.4
                    }
                    Icon {
                        anchors.centerIn: parent
                        visible: !rowItem.entry.icon && !rowItem.entry.engine && rowItem.entry.checked === true
                        name: "check"; size: 15; color: theme.highlight
                    }
                    // A search engine: its logo (the chosen one reads in the accent).
                    EngineBadge {
                        anchors.centerIn: parent
                        visible: !!rowItem.entry.engine
                        engine: rowItem.entry.engine || ({})
                        size: 16
                    }
                    Image {
                        anchors.fill: parent
                        visible: !!rowItem.entry.image
                        source: rowItem.entry.image || ""
                        sourceSize: Qt.size(32, 32)
                        fillMode: Image.PreserveAspectFit
                        smooth: true
                    }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: rowItem.entry.text || ""
                    color: rowItem.entry.danger ? theme.danger : (rowItem.entry.engine && rowItem.entry.checked === true ? theme.highlight : theme.text)
                    font.weight: rowItem.entry.engine && rowItem.entry.checked === true ? Font.DemiBold : Font.Normal
                    opacity: rowItem.enabledItem ? 1 : 0.4
                    font.pixelSize: 13
                    elide: Text.ElideRight
                    width: Math.min(implicitWidth, rowItem.width - 46 - (rowItem.entry.shortcut ? shortcutText.implicitWidth + 28 : 0))
                }
            }
            Text {
                id: shortcutText
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                visible: !!rowItem.entry.shortcut
                text: rowItem.entry.shortcut || ""
                color: theme.textFaint
                font.pixelSize: 11
            }
            MouseArea {
                id: hover
                anchors.fill: parent
                hoverEnabled: true
                onEntered: menu.current = rowItem.entryIndex
                onClicked: menu.trigger(rowItem.entryIndex)
            }
        }
    }
}
