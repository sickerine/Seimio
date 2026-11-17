// A glass bar of segments (tabs, seasons) walked with Left/Right. The highlight stretches like liquid:
// its leading edge moves first and the trailing edge follows. It's white while the bar has focus.
// `model` entries are strings, or { label, icon } for icon-only segments, or { label, trailing } for a
// label with a small icon after it (chevrons on a segment that opens a menu); a new model of the same
// length relabels the segments in place. Other keys, and Left or Right past an end, pass on to the
// parent. `source` is what the glass blurs; `sx`/`sy` the bar's position in it (see Glass).
// Moving selects, unless `selectOnOk`: then a cursor walks the segments and OK selects the one under it
// (bars side by side, see BarRow). The cursor is the white highlight; the selection keeps the soft one,
// and the cursor goes back to it when the bar loses focus.
import QtQuick 2.12

FocusScope {
    id: bar
    property var model: []
    property int currentIndex: 0
    property Item source
    property real sx: x
    property real sy: y
    property int fontSize: 26
    property int barHeight: 76
    property int segmentPad: 52
    property real shadow: 0
    property bool preblurred: false      // `source` is already blurred (see Glass)          // opacity of a drop shadow under the bar, 0 for none
    property int moveDir: 1
    property bool showFocus: activeFocus  // draws the focused look; previews set it directly
    property bool selectOnOk: false
    property int cursor: currentIndex     // the segment under focus: the selection, unless walking with selectOnOk
    signal triggered(int index)           // OK with selectOnOk, after selecting
    onCurrentIndexChanged: cursor = currentIndex
    onActiveFocusChanged: if (!activeFocus) cursor = currentIndex
    // a cursor walking in from a neighbouring bar starts at the near end
    function enter(fromEnd) { if (selectOnOk) cursor = fromEnd ? model.length - 1 : 0 }
    width: glass.width
    height: barHeight

    Shadow { opacity: bar.shadow; drop: 8 }
    Glass {
        id: glass
        source: bar.source
        preblurred: bar.preblurred
        sx: bar.sx; sy: bar.sy
        width: segments.width + 2 * inset; height: bar.barHeight; radius: height / 2
        readonly property int inset: Math.round(bar.barHeight * 0.13)
        property Item target: segmentItems.count, segmentItems.itemAt(bar.showFocus ? bar.cursor : bar.currentIndex)
        property real edgeL: target ? inset + target.x : inset
        property real edgeR: target ? inset + target.x + target.width : inset
        Behavior on edgeL { NumberAnimation { duration: bar.moveDir > 0 ? 420 : 240; easing.type: Theme.ease } }
        Behavior on edgeR { NumberAnimation { duration: bar.moveDir > 0 ? 240 : 420; easing.type: Theme.ease } }
        // the selection, while the cursor is elsewhere
        Rectangle {
            readonly property Item at: segmentItems.count, segmentItems.itemAt(bar.currentIndex)
            visible: bar.showFocus && bar.cursor !== bar.currentIndex && !!at
            x: at ? glass.inset + at.x : 0; width: at ? at.width : 0
            y: glass.inset; height: glass.height - 2 * glass.inset; radius: height / 2
            color: "#2effffff"
        }
        Rectangle {
            x: glass.edgeL; width: glass.edgeR - glass.edgeL
            y: glass.inset; height: glass.height - 2 * glass.inset; radius: height / 2
            color: bar.showFocus ? Theme.focusFill : "#2effffff"
            Behavior on color { ColorAnimation { duration: 200 } }
        }
        Row {
            id: segments
            x: glass.inset; height: parent.height
            Repeater {
                id: segmentItems
                model: bar.model.length
                Item {
                    readonly property var m: bar.model[index]
                    readonly property string label: typeof m === "string" ? m : (m && m.label || "")
                    readonly property string icon: typeof m === "string" ? "" : (m && m.icon || "")
                    readonly property string trailing: typeof m === "string" ? "" : (m && m.trailing || "")
                    readonly property bool current: bar.currentIndex === index
                    readonly property color ink: bar.showFocus && bar.cursor === index ? Theme.inkOnLight : Theme.ink
                    // the label and its trailing icon, centred as one block by what's drawn
                    readonly property real block: text.implicitWidth + (trailing ? 8 + tail.inkRight - tail.inkLeft : 0)
                    width: icon !== "" ? bar.barHeight : block + bar.segmentPad
                    height: segments.height
                    Text {
                        id: text
                        visible: parent.icon === ""
                        x: (parent.width - parent.block) / 2; anchors.verticalCenter: parent.verticalCenter
                        text: parent.label; color: parent.ink
                        font.family: Theme.face; font.pixelSize: bar.fontSize; font.weight: parent.current ? Font.DemiBold : Font.Medium
                        Behavior on color { ColorAnimation { duration: 200 } }
                    }
                    Icon { visible: parent.icon !== ""; name: parent.icon; anchors.centerIn: parent; color: parent.ink }
                    Icon {
                        id: tail
                        visible: parent.trailing !== ""
                        name: parent.trailing; color: parent.ink
                        width: Math.round(bar.fontSize * 28 / 26); height: width     // as icons are to a 26 px label in a Button
                        x: text.x + text.implicitWidth + 8 - inkLeft; anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }
        }
    }
    function move(step) {
        moveDir = step;
        if (selectOnOk) cursor += step; else currentIndex += step;
    }
    Keys.onLeftPressed: if (cursor > 0) move(-1); else event.accepted = false
    Keys.onRightPressed: if (cursor < model.length - 1) move(1); else event.accepted = false
    Keys.forwardTo: selectOnOk ? [ok] : []
    OkPress { id: ok; onTapped: { bar.currentIndex = bar.cursor; bar.triggered(bar.cursor) } }
}
