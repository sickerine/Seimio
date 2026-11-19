// The search tab's bar, in the tab bar's place: the field, and at its left the kinds of title a search
// finds, one of them chosen (`kind`): the grid under the bar is that kind's. `open` brings both in: the
// field grows out of the tab bar's search icon, which is at the bar's left end, and the kinds come along
// at its left edge.
// The row is laid out by where it is reached from. The tabs are to the right of the search (Left from
// Home is how it is reached), so the field, which is what the remote is given to type in, is the near
// end of the row, and the kinds are beyond it:
//     kinds | field | (the tabs)
// One cursor walks the row, as across a BarRow's bars: Left from the start of the text goes onto the
// kinds, at the near one, and Right from the last kind goes back. Crossing a kind doesn't choose it; OK
// does (`chosen`). Right at the end of the text is `exitRight`, back to the tabs; Up and Down pass on.
// `zone` is which of the two has the remote, and the owner sets it as the remote arrives: 0 from the tab
// bar, to type; 1 from the results. The field with the remote has the TV's keyboard up, and the keyboard
// takes the arrows while it is up: the kinds are reached from the results, or from the field once Enter
// or Back has put the keyboard away.
import QtQuick 2.12
import Seimio.UI 1.0

FocusScope {
    id: bar
    property bool open: false
    property alias text: field.text
    property var kinds: []                   // the kinds on offer, as a SegmentedBar's entries
    property int kind: 0                     // the one chosen
    property int zone: 0                     // 0 the field, 1 the kinds
    property Item source                     // a blur of what is under the bar, which its glass reads (as Glass's `preblurred`)
    property real iconX: 0                   // where the tab bar's search icon sits, in this bar
    readonly property int gap: 22
    readonly property alias kindBar: kindBar
    readonly property bool typing: field.typing             // the TV's keyboard is up for the field
    signal accepted()                        // Enter on the keyboard
    signal chosen(int index)
    signal exitRight()
    height: field.barHeight

    onKindChanged: kindBar.currentIndex = kind
    Component.onCompleted: kindBar.currentIndex = kind

    SegmentedBar {
        id: kindBar
        selectOnOk: true
        focus: bar.zone === 1
        source: bar.source; preblurred: true; sx: x; sy: bar.y
        x: field.x - bar.gap - width
        model: bar.kinds
        visible: field.visible
        opacity: field.opacity
        onTriggered: bar.chosen(index)
    }
    SearchField {
        id: field
        open: bar.open
        focus: bar.zone === 0
        source: bar.source; preblurred: true; sy: bar.y
        iconX: bar.iconX
        openWidth: 720
        // the two as one row in the middle of the bar, the kinds first
        openX: (bar.width - kindBar.width - bar.gap - openWidth) / 2 + kindBar.width + bar.gap
        onAccepted: bar.accepted()
    }
    Keys.onLeftPressed: if (zone === 0) { kindBar.enter(true); zone = 1 }        // (left of the first kind there is nothing)
    Keys.onRightPressed: if (zone === 1) { kindBar.leave(1); zone = 0 } else exitRight()
}
