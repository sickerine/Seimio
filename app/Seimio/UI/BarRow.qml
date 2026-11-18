// A row of SegmentedBars walked as one: Left and Right move a single cursor across every option of
// every bar, and OK selects the option under it, so crossing a bar on the way to the next never changes
// it. (A tvOS segmented control selects on focus, which is why Apple advises against placing other
// focusable controls next to one.) The bars set `selectOnOk`; `bars` is the walk order, which may leave
// some out (a bar that doesn't apply). Other children (a label) sit in the row unwalked. Up and Down
// pass on.
import QtQuick 2.12

FocusScope {
    id: barRow
    property var bars: []
    property alias spacing: row.spacing
    default property alias content: row.data
    width: row.width; height: row.height

    // the bar the cursor is in; the first bar until one has had focus
    property Item current: null
    function go(step) {
        var i = bars.indexOf(current) + step;
        if (i < 0 || i >= bars.length) return false;
        if (current) current.leave(step);                  // its cursor draws back the way it's going
        current = bars[i]; current.enter(step < 0); current.forceActiveFocus();
        return true;
    }
    onActiveFocusChanged: {
        if (!activeFocus) return;
        for (var i = 0; i < bars.length; i++) if (bars[i].activeFocus) { current = bars[i]; return }   // focused from outside
        current = bars.indexOf(current) >= 0 ? current : bars[0] || null;       // (no bars yet: a list still loading has no filters)
        if (current) current.forceActiveFocus();
    }
    Row { id: row }
    Keys.onLeftPressed: if (!go(-1)) event.accepted = false
    Keys.onRightPressed: if (!go(1)) event.accepted = false
}
