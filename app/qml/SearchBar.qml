// The search tab's bar, in the tab bar's place: the field, and beside it the kinds of title a search
// finds, one of them chosen (`kind`): the grid under the bar is that kind's. `open` brings both in: the
// field grows out of the tab bar's search icon and the kinds come along at its right edge.
// One cursor walks the row, as across a BarRow's bars: Right from the end of the text goes onto the
// kinds and Left from the first kind goes back. Crossing a kind doesn't choose it; OK does (`chosen`).
// `zone` is which of the two has the remote, and the owner sets it as the remote arrives: 0 from the tab
// bar, to type; 1 from the results. The field with the remote has the TV's keyboard up, and the keyboard
// takes the arrows while it is up: the kinds are reached from the results, or from the field once Enter
// has put the keyboard away. Left at the start of the text is `exitLeft`; Up and Down pass on.
import QtQuick 2.12
import Seimio.UI 1.0

FocusScope {
    id: bar
    property bool open: false
    property alias text: field.text
    property var kinds: []                   // the kinds on offer, as a SegmentedBar's entries
    property int kind: 0                     // the one chosen
    property int zone: 0                     // 0 the field, 1 the kinds
    property Item source                     // what the glass blurs
    property real iconX: 0                   // where the tab bar's search icon sits, in this bar
    readonly property int gap: 22
    readonly property alias kindBar: kindBar
    signal accepted()                        // Enter on the keyboard
    signal dismissed()                       // Back on the keyboard
    signal chosen(int index)
    signal exitLeft()
    height: field.barHeight

    onKindChanged: kindBar.currentIndex = kind
    Component.onCompleted: kindBar.currentIndex = kind

    SearchField {
        id: field
        open: bar.open
        focus: bar.zone === 0
        source: bar.source; sy: bar.y
        iconX: bar.iconX
        openWidth: 720
        openX: (bar.width - openWidth - bar.gap - kindBar.width) / 2
        onAccepted: bar.accepted()
        onDismissed: bar.dismissed()
    }
    SegmentedBar {
        id: kindBar
        selectOnOk: true
        focus: bar.zone === 1
        source: bar.source; sx: x; sy: bar.y
        x: field.x + field.width + bar.gap
        model: bar.kinds
        visible: field.visible
        opacity: field.opacity
        onTriggered: bar.chosen(index)
    }
    Keys.onRightPressed: if (zone === 0) { kindBar.enter(false); zone = 1 }      // (past the last kind there is nothing)
    Keys.onLeftPressed: if (zone === 1) { kindBar.leave(-1); zone = 0 } else exitLeft()
}
