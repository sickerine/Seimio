// BarRow: one cursor walked across bars side by side. Walked into a bar from its right it is on that
// bar's last segment at once, growing in from the right: it used to start on the bar's selection (its
// first segment here) and slide right to where it landed, against the way the remote was going.
import QtQuick 2.12
import QtTest 1.2
import Seimio.UI 1.0

TestCase {
    name: "Bars"
    when: windowShown
    width: 1400; height: 120
    BarRow {
        id: row
        bars: [formats, sorts]
        spacing: 22
        SegmentedBar { id: formats; selectOnOk: true; model: ["All", "TV", "Movies", "ONA & OVA"] }
        SegmentedBar { id: sorts; selectOnOk: true; model: ["Popular", "Top rated"] }
    }
    function test_walkedInFromTheRight() {
        row.forceActiveFocus();
        row.go(1);                                          // onto Popular
        verify(sorts.activeFocus);
        wait(400);
        row.go(-1);                                         // left, into the formats
        compare(formats.cursor, 3, "on ONA & OVA");
        var selection = formats.selectionRect, leftmost = formats.width;
        for (var i = 0; i < 12; i++) { wait(30); leftmost = Math.min(leftmost, formats.cursorRect.x) }
        verify(leftmost > selection.x + selection.width, "the cursor never passes through the selection on its way (leftmost " + leftmost + ")");
        fuzzyCompare(formats.cursorRect.x + formats.cursorRect.width, formats.width - selection.x, 2, "and ends on the last segment");
        compare(Math.round(formats.selectionRect.x), Math.round(selection.x), "the selection stays on All");
    }
}
