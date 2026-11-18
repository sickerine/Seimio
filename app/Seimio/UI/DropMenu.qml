// A menu that drops from a control (a bar's segment with chevrons: a genre, a season): a panel with a
// MenuList, growing from the corner it hangs by. The owner places that corner (x, y), says which it is
// (`up`: the panel sits above its control; `fromRight`: it hangs from its right edge), sets the row to start
// on (`currentIndex`) and then `open`. OK on a row emits `triggered(rowIndex)`; the owner closes it. Its
// rows are held while it closes: a choice that moves the check mark doesn't move it in a list on its way out.
import QtQuick 2.12

Rectangle {
    id: drop
    property bool open: false
    property bool up: false
    property bool fromRight: false
    property var model: []
    property alias currentIndex: list.currentIndex
    property alias maxRows: list.maxRows
    signal triggered(int rowIndex)
    width: 420; height: list.implicitHeight + 32; radius: 32
    color: "#f0141418"; border.width: 1; border.color: "#26ffffff"
    opacity: open ? 1 : 0; scale: open ? 1 : 0.92      // holds: `rows` latches the list
    transformOrigin: up ? (fromRight ? Item.BottomRight : Item.BottomLeft) : (fromRight ? Item.TopRight : Item.TopLeft)
    visible: opacity > 0.01
    Behavior on opacity { NumberAnimation { duration: 200 } }
    Behavior on scale { NumberAnimation { duration: 340; easing.type: Theme.spring; easing.overshoot: 1.3 } }
    onOpenChanged: if (open) { list.follow(true); list.forceActiveFocus() }
    Latch { id: rows; value: drop.model; live: drop.open }
    MenuList {
        id: list
        model: rows.current || []
        x: 16; y: 16; width: parent.width - 32
        focus: drop.open
        shown: drop.open
        onTriggered: drop.triggered(rowIndex)
    }
}
