// A glass bar of segments (tabs, seasons) walked with Left/Right. The highlight stretches like liquid:
// its leading edge moves first and the trailing edge follows. It's white while the bar has focus.
// `model` entries are strings, or { label, icon } for icon-only segments, or { label, trailing } for a
// label with a small icon after it (chevrons on a segment that opens a menu), or { label, faint } for a
// label drawn dim (a kind a search found nothing of: it can still be chosen); a new model of the same
// length relabels the segments in place. { label, trailing, room } is a choice that opens a list: `room`
// is every label it may come to show, and the segment is as wide as the longest, so the bar keeps its
// width and what stands after it keeps its place when the choice changes (a select box's way: sized by
// its label, "Chart" turning to "Schedule" pushed the three bars after it along in one frame). Its label
// starts where the longest would and its chevrons stay at the end. Other keys, and Left or Right past an end, pass on to the
// parent. `source` is what the glass blurs; `sx`/`sy` the bar's position in it (see Glass).
// Moving selects, unless `selectOnOk`: then a cursor walks the segments and OK selects the one under it
// (bars side by side, see BarRow). The selection is a soft pill that stays on its segment; the cursor is
// a white pill of its own, there while the bar has focus. Walked in from a neighbouring bar it grows onto
// the near segment from that side, and walked out it draws back towards the side it leaves by (enter,
// leave), so a walk across bars reads as one movement: it never slides over from the selection. Focused
// from anywhere else it is on the selection.
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
    property bool showFocus: look.shown   // draws the focused look (with the remote, or under a menu that took it); previews set it directly
    property HeldFocus look: HeldFocus { of: bar }
    property bool selectOnOk: false
    property int cursor: currentIndex     // the segment under focus: the selection, unless walking with selectOnOk
    signal triggered(int index)           // OK with selectOnOk, after selecting
    onCurrentIndexChanged: cursor = currentIndex
    property bool arriving: false         // enter() ran: the focus that follows is a walk in
    onActiveFocusChanged: {
        if (!activeFocus) return;
        if (!arriving) { glass.snap = true; cursor = currentIndex; glass.snap = false; grow.stop(); pill.grown = 1 }
        arriving = false;
    }
    // a cursor walking in from a neighbouring bar starts at the near end (`fromEnd`: the last segment)
    function enter(fromEnd) {
        if (!selectOnOk) return;
        arriving = true; moveDir = fromEnd ? -1 : 1;
        glass.snap = true; cursor = fromEnd ? model.length - 1 : 0; glass.snap = false;
        pill.fromRight = fromEnd; grow.stop(); pill.grown = 0; grow.to = 1; grow.duration = 260; grow.restart();
    }
    // walking out to a neighbouring bar (`step`: -1 to the left, 1 to the right)
    function leave(step) { pill.fromRight = step > 0; grow.stop(); grow.to = 0; grow.duration = 180; grow.restart() }
    // where the two pills are, for tests
    readonly property rect cursorRect: Qt.rect(pill.x, pill.y, pill.width, pill.height)
    readonly property rect selectionRect: Qt.rect(chosen.x, chosen.y, chosen.width, chosen.height)
    width: glass.width
    height: barHeight

    Shadow { opacity: bar.shadow; drop: 8 }
    FontMetrics { id: lettering; font.family: Theme.face; font.pixelSize: bar.fontSize; font.weight: Font.DemiBold }      // (a segment's `room`)
    Glass {
        id: glass
        source: bar.source
        preblurred: bar.preblurred
        sx: bar.sx; sy: bar.sy
        width: segments.width + 2 * inset; height: bar.barHeight; radius: height / 2
        readonly property int inset: Math.round(bar.barHeight * 0.13)
        // the cursor's segment and its edges, which stretch like liquid as it moves; `snap`: the next
        // change is a jump (onto the segment it's walked in at, or back onto the selection out of sight)
        property bool snap: false
        property Item target: segmentItems.count, segmentItems.itemAt(bar.cursor)
        property real edgeL: target ? inset + target.x : inset
        property real edgeR: target ? inset + target.x + target.width : inset
        Behavior on edgeL { enabled: !glass.snap; NumberAnimation { duration: bar.moveDir > 0 ? 420 : 240; easing.type: Theme.ease } }
        Behavior on edgeR { enabled: !glass.snap; NumberAnimation { duration: bar.moveDir > 0 ? 240 : 420; easing.type: Theme.ease } }
        // the selection
        Rectangle {
            id: chosen
            readonly property Item at: segmentItems.count, segmentItems.itemAt(bar.currentIndex)
            property real edgeL: at ? glass.inset + at.x : glass.inset
            property real edgeR: at ? glass.inset + at.x + at.width : glass.inset
            Behavior on edgeL { NumberAnimation { duration: bar.moveDir > 0 ? 420 : 240; easing.type: Theme.ease } }
            Behavior on edgeR { NumberAnimation { duration: bar.moveDir > 0 ? 240 : 420; easing.type: Theme.ease } }
            x: edgeL; width: edgeR - edgeL
            y: glass.inset; height: glass.height - 2 * glass.inset; radius: height / 2
            color: "#2effffff"
        }
        // the cursor
        Rectangle {
            id: pill
            property bool fromRight: false       // the side it was walked in from, or is walked out by
            property real grown: 1               // how much of its segment it covers, measured from that side
            NumberAnimation { id: grow; target: pill; property: "grown"; easing.type: Theme.ease }
            readonly property real span: glass.edgeR - glass.edgeL
            x: fromRight ? glass.edgeR - span * grown : glass.edgeL
            width: span * grown
            y: glass.inset; height: glass.height - 2 * glass.inset; radius: height / 2
            color: Theme.focusFill
            opacity: bar.showFocus ? 1 : 0      // holds: the cursor pill: nothing in it
            Behavior on opacity { NumberAnimation { duration: 200 } }
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
                    readonly property bool faint: typeof m !== "string" && !!(m && m.faint)
                    readonly property var room: typeof m === "string" ? [] : (m && m.room || [])
                    // its label's width, or the longest it may come to have
                    readonly property real lettered: { var w = text.implicitWidth; for (var i = 0; i < room.length; i++) w = Math.max(w, lettering.advanceWidth(room[i])); return w }
                    readonly property bool current: bar.currentIndex === index
                    readonly property color ink: bar.showFocus && bar.cursor === index ? Theme.inkOnLight : Theme.ink
                    // the label and its trailing icon, centred as one block by what's drawn
                    readonly property real block: lettered + (trailing ? 8 + tail.inkRight - tail.inkLeft : 0)
                    width: icon !== "" ? bar.barHeight : block + bar.segmentPad
                    height: segments.height
                    Text {
                        id: text
                        visible: parent.icon === ""
                        x: (parent.width - parent.block) / 2; anchors.verticalCenter: parent.verticalCenter
                        text: parent.label; color: parent.ink
                        opacity: parent.faint && !(bar.showFocus && bar.cursor === index) ? 0.42 : 1      // holds: only dims; the label is the same (under the cursor it is whole: grey on the white pill read as switched off)
                        font.family: Theme.face; font.pixelSize: bar.fontSize; font.weight: parent.current ? Font.DemiBold : Font.Medium
                        Behavior on color { ColorAnimation { duration: 200 } }
                        Behavior on opacity { NumberAnimation { duration: 200 } }
                    }
                    Icon { visible: parent.icon !== ""; name: parent.icon; anchors.centerIn: parent; color: parent.ink }
                    Icon {
                        id: tail
                        visible: parent.trailing !== ""
                        name: parent.trailing; color: parent.ink
                        width: Math.round(bar.fontSize * 28 / 26); height: width     // as icons are to a 26 px label in a Button
                        x: text.x + parent.lettered + 8 - inkLeft; anchors.verticalCenter: parent.verticalCenter
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
    // `holds`: a long OK on a segment is `held` (a season's menu); OK is the bar's then, though a tap does nothing without selectOnOk
    property bool holds: false
    signal held(int index)
    Keys.forwardTo: selectOnOk || holds ? [ok] : []
    OkPress {
        id: ok
        onTapped: if (bar.selectOnOk) { bar.currentIndex = bar.cursor; bar.triggered(bar.cursor) }
        onHeld: if (bar.holds) bar.held(bar.cursor)
    }
}
