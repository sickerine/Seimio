// CardGrid: what has the focus follows the cursor, whatever the owner calls its layout. The Anime tab
// shows its chart as "chart"; the grid shared one column across rows only for a layout called "grid", so
// on the chart the focused title stayed the first card's (the info above never changed) and the cursor
// went back to the first column whenever the grid got the remote back (a menu closing).
import QtQuick 2.12
import QtTest 1.12
import Seimio.UI 1.0

Item {
    width: 1920; height: 1080
    FocusScope {
        id: owner
        width: 1920; height: 1080
        focus: true
        CardGrid { id: grid; width: 1920; height: 1080; focus: true }
    }

    TestCase {
    name: "CardGrid"
    when: windowShown
    function rows() {
        var out = [];
        for (var r = 0; r < 2; r++) {
            var items = [];
            for (var c = 0; c < 7; c++) items.push({ id: "r" + r + "c" + c, title: "t", art: "" });
            out.push({ items: items });
        }
        return out;
    }
    function focused() { return grid.focusItem ? grid.focusItem.id : "" }

    function test_focusFollowsTheCursor() {
        grid.show(rows(), "chart");
        grid.row = 0;
        tryVerify(function () { return focused() === "r0c0" });
        wait(300);                                              // its rows reach the row slots a frame apart
        keyClick(Qt.Key_Right); keyClick(Qt.Key_Right);
        tryVerify(function () { return focused() === "r0c2" }, 2000, "the focused title is the card under the cursor");
        owner.focus = false; owner.focus = true;                // something else had the remote for a moment
        keyClick(Qt.Key_Right);
        tryVerify(function () { return focused() === "r0c3" }, 2000, "and the cursor is where it was left");
        keyClick(Qt.Key_Down);
        tryVerify(function () { return focused() === "r1c3" }, 2000, "the row below, in the same column");
    }
}
}
