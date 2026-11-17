// A row of Buttons walked with Left/Right; OK triggers the focused one, a long OK holds it. Other keys (Up, Down, Back)
// pass on to the parent. `model` entries are { label, icon, round, primary, progress }; a new model of
// the same length updates the buttons in place.
import QtQuick 2.12

FocusScope {
    id: row
    property var model: []
    property int currentIndex: 0
    property int spacing: 22
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
                round: !!b.round
                primary: !!b.primary
                progress: b.progress === undefined ? -1 : b.progress
                focused: row.activeFocus && row.currentIndex === index
            }
        }
    }
    Keys.onLeftPressed: if (currentIndex > 0) currentIndex--
    Keys.onRightPressed: if (currentIndex < model.length - 1) currentIndex++
    OkPress { id: ok; onTapped: row.triggered(row.currentIndex); onHeld: row.held(row.currentIndex) }
    Keys.forwardTo: [ok]
}
