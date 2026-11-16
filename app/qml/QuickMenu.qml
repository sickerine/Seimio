// Quick actions beside a card (long press OK): a glass panel that springs open from its left edge,
// with a MenuList inside (Up/Down/OK). Back passes on to the app.
import QtQuick 2.12
import Seimio.UI 1.0

FocusScope {
    id: quick
    property bool open: false
    property Item source
    property var actions: [{ label: "Play", icon: "play" }, { label: "Add to library", icon: "plus" }, { label: "Mark watched", icon: "check" }]
    signal triggered(int actionIndex)
    width: 440; height: list.implicitHeight + 32
    opacity: open ? 1 : 0
    scale: open ? 1 : 0.86
    transformOrigin: Item.Left
    visible: opacity > 0.01
    Behavior on opacity { NumberAnimation { duration: 200 } }
    Behavior on scale { NumberAnimation { duration: 380; easing.type: Theme.spring; easing.overshoot: 1.5 } }
    onOpenChanged: if (open) list.currentIndex = 0

    Glass {
        anchors.fill: parent
        source: quick.source
        sx: quick.x; sy: quick.y
        radius: 32
        tint: Qt.rgba(0.08, 0.08, 0.1, 0.25)
        MenuList {
            id: list
            x: 16; y: 16; width: parent.width - 32
            focus: true
            shown: quick.open
            model: quick.actions
            onTriggered: quick.triggered(rowIndex)
        }
    }
}
