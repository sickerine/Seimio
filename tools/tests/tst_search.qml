// SearchScreen: who has the remote follows `row` (-1 the field, 0.. the rows), so an answer may put it back
// to -1 only while the field has it. The text the rows already show, answered again (a space typed after
// it), reset the row with a title's page open over the results: back on them nothing had the remote and
// Back went nowhere. And an Enter still waiting for its answer took the remote after the search was left.
import QtQuick 2.12
import QtTest 1.12
import "../../app/qml"

Item {
    width: 1920; height: 1080
    // Catalog, as far as the screen uses it: `answer` is the network's
    QtObject {
        id: catalog
        signal found(string query, var rows)
        property int asked: 0
        function search(query) { asked++ }
        function answer(query) { found(query, [{ title: "Movies", shelf: true, items: [{ id: "a", name: "a", title: "a", art: "" }, { id: "b", name: "b", title: "b", art: "" }] }]) }
    }
    SearchScreen { id: screen; width: 1920; height: 1080; catalog: catalog; shown: true; focus: true }
    SignalSpy { id: entered; target: screen; signalName: "entered" }

    TestCase {
    name: "SearchScreen"
    when: windowShown
    function type(text) { var n = catalog.asked; screen.query = text; tryVerify(function () { return catalog.asked > n }, 2000) }

    function test_rowsThatHaveTheRemoteKeepIt() {
        type("hun"); catalog.answer("hun");
        verify(screen.any);
        type("hun "); screen.enter();                       // a space after it, asked again; on to the rows meanwhile
        compare(screen.row, 0);
        catalog.answer("hun");
        compare(screen.row, 0, "the same text answered again leaves the row where it is");
        screen.row = -1;                                    // back in the field
        screen.query = "hun  "; screen.enter();             // Enter before that text is even asked
        compare(screen.row, -1);
        catalog.answer("hun");
        compare(screen.row, 0, "and an Enter that waited for the answer goes on to the rows");
    }
    function test_enterIsDroppedWhenTheSearchIsLeft() {
        screen.row = -1; screen.query = "one"; screen.enter();
        entered.clear();
        screen.shown = false;                               // another tab before the answer
        catalog.answer("one");
        compare(entered.count, 0, "the answer takes no remote once the search was left");
        screen.shown = true;
    }
}
}
