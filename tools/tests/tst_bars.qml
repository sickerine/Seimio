// BarRow: one cursor walked across bars side by side. Walked into a bar from its right it is on that
// bar's last segment at once, growing in from the right: it used to start on the bar's selection (its
// first segment here) and slide right to where it landed, against the way the remote was going.
// And FilterBar, a filter as its bar.
import QtQuick 2.12
import QtTest 1.2
import Seimio.UI 1.0

// (the root is an Item that shows: TestCase is not visible itself, and under something invisible a Row
// lays out nothing again and a Behavior does not animate, so what moves in the app would not move here)
Item {
    id: root
    width: 1400; height: 140
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
        y: 70; spacing: 22
        FilterBar { id: bar; filter: root.filter }
        Rectangle { id: next; width: 40; height: 40 }
    }
    // a bar whose filter is still on its way
    property var late: null
    FilterBar { id: lateBar; x: 700; y: 70; filter: root.late }
    Component { id: seasons; SegmentedBar { x: 700; model: ["Season 1", "Season 2", "Season 3"] } }

    TestCase {
        name: "Bars"
        when: windowShown
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
        // Three choices or fewer are all in sight; more are one choice that drops a list. (Four were in
        // sight too, and a row of them left no room for what else belonged in it.)
        function test_threeChoicesAreInSightAndMoreAreAList() {
            root.filter = { key: "kind", options: ["All", "Movies", "Series"], current: 2 };
            verify(!bar.drops); compare(bar.model.length, 3); compare(bar.currentIndex, 2, "on what is chosen");
            root.filter = { key: "format", options: ["All formats", "TV", "Movies", "ONA & OVA"], current: 0 };
            verify(bar.drops); compare(bar.model.length, 1); compare(bar.model[0].label, "All formats");
            root.filter = { key: "kind", options: ["All", "Movies", "Series"], current: 1 };
            compare(bar.currentIndex, 1, "and on what is chosen again, a list turned back into segments");
        }
        // A bar that drops a list is as wide as its choice, and goes to another choice's width in a glide:
        // what stands after it in a row slides to its new place. Relabelled at a stroke, "Chart" turning to
        // "Schedule" pushed the bars after it along in one frame.
        function test_aListGlidesToItsNewChoicesWidth() {
            var names = ["A–Z", "Popular", "Top rated", "Recently added"];
            root.filter = { key: "sort", options: names, current: 0 };
            wait(400);
            var narrow = bar.width, at = next.x, widths = [], places = [];
            root.filter = { key: "sort", options: names, current: 3 };
            for (var i = 0; i < 40; i++) { wait(16); if (widths[widths.length - 1] !== bar.width) { widths.push(bar.width); places.push(next.x) } }
            var wide = bar.width;
            verify(wide > narrow + 40, "wider for its longer choice: " + narrow + " to " + wide);
            verify(widths.length >= 5, "in a glide: " + widths.length + " sizes on the way");
            var last = narrow;
            for (i = 0; i < widths.length; i++) { verify(widths[i] - last < (wide - narrow) * 0.6, "no size taken at a stroke"); last = widths[i] }
            fuzzyCompare(next.x - at, wide - narrow, 0.5, "and what follows moved with it");
            verify(places.length >= 5, "sliding");
            // Back to the shorter choice: the bar keeps the longer label's room while that label is still
            // on show, and closes after. (Closing at once, the chevrons crossed the label going out.)
            wait(400);
            root.filter = { key: "sort", options: names, current: 0 };
            var held = 0;
            for (i = 0; i < 40; i++) {
                wait(16);
                if (label(bar) === "Recently added") { held++; fuzzyCompare(bar.width, wide, 0.5, "its room while it shows") }
            }
            verify(held > 0, "the longer label was seen going out");
            fuzzyCompare(bar.width, narrow, 0.5, "then the shorter one's width");
        }
        // the label a bar's first segment shows
        function label(bar) {
            function find(o) { if (o.text !== undefined && o.font !== undefined && o.visible && o.text !== "") return o; for (var i = 0; i < o.children.length; i++) { var f = find(o.children[i]); if (f) return f } return null }
            var text = find(bar);
            return text ? text.text : "";
        }
        // A bar is at its width from its first frame. (Its segments were sized by a measure in the
        // selection's weight and then by their own label's: every one but the selection was made 1.2 px
        // too wide and shrank, and the bar with them.)
        function test_aBarIsAtItsWidthFromItsFirstFrame() {
            var made = seasons.createObject(root), widths = [];
            for (var i = 0; i < 20; i++) { widths.push(made.width); wait(16) }
            for (i = 0; i < widths.length; i++) compare(widths[i], widths[widths.length - 1], "frame " + i + " of " + widths.join(" "));
            made.destroy();
        }
        // The selection is on its segment, at its size, from the moment a bar has its segments: it used to
        // grow out to it in sight, from nothing, each time a bar was given a filter (a list coming in).
        function test_theSelectionIsAtItsSizeAsABarGetsItsSegments() {
            wait(100);
            root.late = { key: "sort", options: ["Popular", "Top rated", "Airing soon", "A–Z", "Newest"], current: 0 };
            var widths = [];
            for (var i = 0; i < 16; i++) { wait(16); widths.push(Math.round(lateBar.selectionRect.width)) }
            verify(widths[widths.length - 1] > 40, "there: " + widths[widths.length - 1]);
            for (i = 0; i < widths.length; i++) compare(widths[i], widths[widths.length - 1], "its size from the first frame (" + widths.join(" ") + ")");
        }
    }
}
