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
    // a filter as its bar, and one standing after it in a row
    property var filter: ({ key: "view", options: ["Chart", "Schedule"], current: 0 })
    Row {
        y: 60; spacing: 22
        FilterBar { id: bar; filter: parent.parent.filter }
        Rectangle { id: next; width: 40; height: 40 }
    }
    // Two choices are a switch, both in sight; more are one choice that drops a list. (Four were a
    // switch too, and a row of them left no room for what else belonged in it.)
    function test_twoChoicesAreASwitchAndMoreAreAList() {
        filter = { key: "view", options: ["Chart", "Schedule"], current: 1 };
        verify(!bar.drops); compare(bar.model.length, 2); compare(bar.currentIndex, 1, "on what is chosen");
        filter = { key: "format", options: ["All formats", "TV", "Movies"], current: 0 };
        verify(bar.drops); compare(bar.model.length, 1); compare(bar.model[0].label, "All formats");
    }
    // A bar that drops a list is as wide as its longest choice, so what stands after it in a row stays
    // where it is when the choice changes. Sized by the choice it showed, "Chart" turning to "Schedule"
    // pushed the bars after it along in one frame.
    function test_aListKeepsItsWidthWhateverIsChosen() {
        filter = { key: "sort", options: ["A–Z", "Popular", "Recently added"], current: 0 };
        wait(50);
        var width = bar.width, at = next.x;
        filter = { key: "sort", options: ["A–Z", "Popular", "Recently added"], current: 2 };
        wait(50);
        compare(bar.model[0].label, "Recently added");
        compare(bar.width, width, "as wide with its longest choice as with its shortest");
        compare(next.x, at, "and what follows has not moved");
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
