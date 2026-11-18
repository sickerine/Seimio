// HomeScreen: the cursor on Continue Watching stays on its title when the row is taken again in another
// order (the title just watched moves to the front, a title leaves). Held by its place in the row, Back
// from a title's page landed on whatever had taken that place, and what had the focus was another title
// for a moment, which closes a menu open on the card.
import QtQuick 2.12
import QtTest 1.12
import "../../app/qml"

Item {
    width: 1920; height: 1080
    HomeScreen { id: home; width: 1920; height: 1080; focus: true; today: "2026-11-18" }
    property var seen: []                    // every title that had the focus, in order
    Connections { target: home; onFocusItemChanged: if (home.focusItem) seen.push(home.focusItem.id) }

    TestCase {
    name: "HomeScreen"
    when: windowShown
    function row(ids) { return ids.map(function (id) { return { id: id, name: id, title: id, art: "" } }) }

    function test_cursorStaysOnItsTitle() {
        home.continueWatching = row(["a", "b", "c", "d"]);
        keyClick(Qt.Key_Right); keyClick(Qt.Key_Right);
        tryVerify(function () { return home.focusItem && home.focusItem.id === "c" });
        seen = [];
        home.continueWatching = row(["c", "a", "b", "d"]);              // c was watched: it comes first
        compare(home.focusItem.id, "c", "the cursor is still on the title it was on");
        compare(home.column, 0, "where that title is now");
        compare(seen.filter(function (id) { return id !== "c" }).length, 0, "and no other title had the focus on the way");
        home.continueWatching = row(["a", "b", "d"]);                   // c left the row: the title in its place
        compare(home.focusItem.id, "a");
    }
}
}
