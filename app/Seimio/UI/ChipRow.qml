// A row of glass chips from an array of strings (empty strings are skipped by the caller). A new array
// of the same length retexts the chips in place instead of creating new ones. With `stagger` (ms) the
// chips arrive one after another when their owner says what they stand for has changed (`arrive()`),
// and a chip made for a longer array arrives as it is made. Never by `model` being written: a `var`
// tells of every write, the same words too, and the chips then started over each time their owner
// looked at its title again, which showed as flashing (tools/tests/tst_hero.qml).
import QtQuick 2.12

Row {
    id: row
    property var model: []
    property int size: 22
    property int stagger: 0
    spacing: 10
    signal arriving()
    // (lab: "chips in" counts as many as the titles that came on show, "info")
    function arrive() { if (stagger > 0) { Remote.tally("chips in"); arriving(); onTheirWay.restart() } }
    // true until the last of them is in: what captures the row (a frozen frost) is stale until then
    readonly property bool moving: onTheirWay.running
    // (the last chip's wait and its fade, and a few frames more: a capture taken as it ends caught it short of whole)
    Timer { id: onTheirWay; interval: 60 + Math.max(0, row.model.length - 1) * row.stagger + 260 + 64 }
    Repeater {
        model: row.model.length
        Reveal {
            id: reveal
            dy: 0
            delay: row.stagger > 0 ? 60 + index * row.stagger : 0
            duration: row.stagger > 0 ? 260 : 0
            Connections { target: row; onArriving: reveal.play() }
            Chip { text: row.model[index] || ""; size: row.size }
        }
    }
}
