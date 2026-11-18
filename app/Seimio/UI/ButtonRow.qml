// A row of Buttons walked with Left/Right; OK triggers the focused one, a long OK holds it. Other keys (Up, Down, Back)
// pass on to the parent. `model` entries are { label, icon, trailing, round, primary, progress, fill }; a new model of
// the same length updates the buttons in place.
import QtQuick 2.12

FocusScope {
    id: row
    property var model: []
    property int currentIndex: 0
    property int spacing: 22
    property HeldFocus look: HeldFocus { of: row }      // its button looks focused with the remote, and under a menu that took it
    // the button that takes the row's width beyond what the others need (-1: none, the row is as wide
    // as its buttons); give the row a width to use it
    property int stretch: -1
    readonly property real othersWidth: {
        var w = 0;
        for (var i = 0; i < buttonItems.count; i++) if (i !== stretch && buttonItems.itemAt(i)) w += buttonItems.itemAt(i).implicitWidth + spacing;
        return w;
    }
    signal triggered(int buttonIndex)
    signal held(int buttonIndex)
    // where button i is in the window, for placing a menu beside it
    function buttonRect(i) { var b = buttonItems.itemAt(i), p = b.mapToItem(null, 0, 0); return Qt.rect(p.x, p.y, b.width, b.height) }
    implicitWidth: buttons.width
    implicitHeight: 76

    Row {
        id: buttons
        spacing: row.spacing
        Repeater {
            id: buttonItems
            model: row.model.length
            Button {
                readonly property var b: row.model[index] || {}
                label: b.label || ""
                icon: b.icon || ""
                trailing: b.trailing || ""
                round: !!b.round
                primary: !!b.primary
                progress: b.progress === undefined ? -1 : b.progress
                fill: b.fill === undefined ? -1 : b.fill
                focused: look.shown && row.currentIndex === index
                width: index === row.stretch ? Math.max(implicitWidth, row.width - row.othersWidth) : implicitWidth
            }
        }
    }
    Keys.onLeftPressed: if (currentIndex > 0) currentIndex--
    Keys.onRightPressed: if (currentIndex < model.length - 1) currentIndex++
    OkPress { id: ok; onTapped: row.triggered(row.currentIndex); onHeld: row.held(row.currentIndex) }
    Keys.forwardTo: [ok]
}
