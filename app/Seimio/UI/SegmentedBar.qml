// A glass bar of segments (tabs, seasons) walked with Left/Right. The highlight stretches like liquid:
// its leading edge moves first and the trailing edge follows. It's white while the bar has focus.
// `model` entries are strings, or { label, icon } for icon-only segments, or { label, trailing } for a
// label with a small icon after it (chevrons on a segment that opens a menu), or { label, faint } for a
// label drawn dim (a kind a search found nothing of: it can still be chosen); a new model of the same
// length relabels the segments in place: the old label goes out and the new one comes in (Swap), and the
// segment goes from one's width to the other's meanwhile, so the bar, and what stands after it in a row,
// glide to their new size and place. (Relabelled at a stroke, "Chart" turning to "Schedule" pushed the
// three bars after it along in one frame.) Other keys, and Left or Right past an end, pass on to the
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
    // The left or right edge of the segment at `place`: a segment's index, or between two for a place on
    // the way from one to the other.
    function edgeAt(place, right) {
        var n = segmentItems.count;
        var a = segmentItems.itemAt(Math.max(0, Math.min(n - 1, Math.floor(place)))), b = segmentItems.itemAt(Math.max(0, Math.min(n - 1, Math.ceil(place))));
        if (!a || !b) return glass.inset;
        var ea = a.x + (right ? a.width : 0), eb = b.x + (right ? b.width : 0);
        return glass.inset + ea + (eb - ea) * (place - Math.floor(place));
    }
    // onto a segment at once, with nothing gliding there (a bar given another filter)
    function put(index) { glass.snap = true; currentIndex = index; glass.snap = false }
    Glass {
        id: glass
        source: bar.source
        preblurred: bar.preblurred
        sx: bar.sx; sy: bar.sy
        width: segments.width + 2 * inset; height: bar.barHeight; radius: height / 2
        readonly property int inset: Math.round(bar.barHeight * 0.13)
        // Where the cursor is, as a place among the segments (a segment's index, or between two on the
        // way), one place for each of its edges: the leading one moves first, so the pill stretches like
        // liquid. The edges are worked out from the segments as they are, so a segment that changes size
        // or comes in under the pill is followed as it is. (The edges were what moved: a bar coming in
        // with its filter, or a choice relabelled, had its pill stretch out to its segment in sight.)
        // `snap`: the next change is a jump (onto the segment it's walked in at, or back onto the
        // selection out of sight).
        property bool snap: false
        property real placeL: bar.cursor
        property real placeR: bar.cursor
        Behavior on placeL { enabled: !glass.snap; NumberAnimation { duration: bar.moveDir > 0 ? 420 : 240; easing.type: Theme.ease } }
        Behavior on placeR { enabled: !glass.snap; NumberAnimation { duration: bar.moveDir > 0 ? 240 : 420; easing.type: Theme.ease } }
        readonly property real edgeL: (segmentItems.count, bar.edgeAt(placeL, false))
        readonly property real edgeR: (segmentItems.count, bar.edgeAt(placeR, true))
        // the selection, placed the same way
        Rectangle {
            id: chosen
            property real placeL: bar.currentIndex
            property real placeR: bar.currentIndex
            Behavior on placeL { enabled: !glass.snap; NumberAnimation { duration: bar.moveDir > 0 ? 420 : 240; easing.type: Theme.ease } }
            Behavior on placeR { enabled: !glass.snap; NumberAnimation { duration: bar.moveDir > 0 ? 240 : 420; easing.type: Theme.ease } }
            readonly property real edgeL: (segmentItems.count, bar.edgeAt(placeL, false))
            readonly property real edgeR: (segmentItems.count, bar.edgeAt(placeR, true))
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
                    readonly property bool current: bar.currentIndex === index
                    readonly property color ink: bar.showFocus && bar.cursor === index ? Theme.inkOnLight : Theme.ink
                    // The label on show: the model's, once it is in. One that replaces another comes in as that
                    // one goes out (the first is simply there).
                    property Swap named: Swap { want: label || null; appearMs: 0 }
                    // Room for the label on show and for the one the model has, whichever is wider: a
                    // longer label's room opens as the old one goes out, and a shorter one's closes once
                    // the old one has gone. (Going straight to the new label's width, a bar that shrank
                    // drew its chevrons across the old label while it was still there to read.) The
                    // model's label is measured by a twin of the Text that shows it, out of sight:
                    // measured apart, in the selection's weight, a segment that was not the selection
                    // was made 1.2 px too wide and shrank to its label in sight.
                    Text { id: sized; visible: false; text: parent.label; font: text.font }
                    readonly property real lettered: Math.max(sized.implicitWidth, text.implicitWidth)
                    // the label and its trailing icon, centred as one block by what's drawn: the label starts
                    // half the padding in and the icon ends half the padding from the end, which is the same
                    // thing at rest and holds each to its own end while the width between them changes
                    readonly property real block: lettered + (trailing ? 8 + tail.inkRight - tail.inkLeft : 0)
                    width: icon !== "" ? bar.barHeight : block + bar.segmentPad
                    Behavior on width { NumberAnimation { duration: Theme.settle; easing.type: Theme.ease } }
                    height: segments.height
                    Text {
                        id: text
                        visible: parent.icon === ""
                        x: bar.segmentPad / 2; anchors.verticalCenter: parent.verticalCenter
                        text: parent.named.shown || ""; color: parent.ink
                        opacity: parent.named.level * (parent.faint && !(bar.showFocus && bar.cursor === index) ? 0.42 : 1)      // holds: `named` (Swap) is what the label comes and goes by; `faint` only dims (under the cursor it is whole: grey on the white pill read as switched off)
                        font.family: Theme.face; font.pixelSize: bar.fontSize; font.weight: parent.current ? Font.DemiBold : Font.Medium
                        Behavior on color { ColorAnimation { duration: 200 } }
                    }
                    Icon { visible: parent.icon !== ""; name: parent.icon; anchors.centerIn: parent; color: parent.ink }
                    Icon {
                        id: tail
                        visible: parent.trailing !== ""
                        name: parent.trailing; color: parent.ink
                        width: Math.round(bar.fontSize * 28 / 26); height: width     // as icons are to a 26 px label in a Button
                        x: parent.width - bar.segmentPad / 2 - inkRight; anchors.verticalCenter: parent.verticalCenter
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
