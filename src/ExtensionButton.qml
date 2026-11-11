import QtQuick
import QtQuick.Controls

// An extension's button in the toolbar: its icon, its badge, its popup.
Item {
    id: button
    property var win: null
    property var info: ({})
    readonly property var hub: win && win.appRoot ? win.appRoot.extensions : null
    readonly property var tab: win ? win.currentTab : null
    readonly property int revision: hub ? hub.revision : 0
    readonly property string iconUrl: (revision, hub ? (hub.actionValue(info.id, "icon", tab ? tab.tabId : null) || info.icon) : info.icon)
    readonly property string badge: (revision, tab ? tab.blocked : 0, hub ? hub.badgeText(info.id, tab) : "")
    readonly property bool enabledAction: (revision, hub ? hub.actionValue(info.id, "enabled", tab ? tab.tabId : null) !== false : true)
    implicitWidth: 30
    implicitHeight: 30
    opacity: enabledAction ? 1 : 0.45

    Rectangle {
        anchors.fill: parent
        radius: 8
        color: hit.pressed ? theme.raised : hit.containsMouse ? theme.alpha(theme.text, 0.07) : "transparent"
    }
    Image {
        anchors.centerIn: parent
        width: 18; height: 18
        sourceSize: Qt.size(36, 36)
        source: button.iconUrl
        smooth: true
        mipmap: true
        fillMode: Image.PreserveAspectFit
        visible: status === Image.Ready
    }
    Icon { anchors.centerIn: parent; name: "puzzle"; size: 15; color: theme.textDim; visible: button.iconUrl === "" }
    Rectangle {
        visible: button.badge !== ""
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: -1
        anchors.bottomMargin: 1
        height: 13
        width: Math.max(13, badgeText.implicitWidth + 6)
        radius: 6.5
        color: (button.revision, button.hub ? button.hub.actionValue(button.info.id, "color", button.tab ? button.tab.tabId : null) : theme.danger)
        Text {
            id: badgeText
            anchors.centerIn: parent
            text: button.badge.length > 4 ? button.badge.slice(0, 4) : button.badge
            color: (button.revision, button.hub ? button.hub.actionValue(button.info.id, "textColor", button.tab ? button.tab.tabId : null) : "white")
            font.pixelSize: 9
            font.weight: Font.Bold
        }
    }
    ToolTip.visible: hit.containsMouse
    ToolTip.delay: 600
    ToolTip.text: (revision, hub ? hub.handlers["action.getTitle"](info.id, [{ tabId: tab ? tab.tabId : undefined }]) : info.name)
    MouseArea {
        id: hit
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: (mouse) => {
            if (mouse.button === Qt.RightButton) { button.win.showExtensionMenu(button.info, button); return }
            if (button.enabledAction && button.hub) button.hub.actionClicked(button.info.id, button.win, button)
        }
    }
}
