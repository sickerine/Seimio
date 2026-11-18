// SearchBar: one cursor for the field and the kinds beside it. Crossing a kind doesn't choose it (the
// results under the bar would change on the way to the kind meant); OK does. Left from the first kind is
// the field again, and from the field it leaves the search.
// (The bar is beside the TestCase, not in it: a TestCase isn't visible, and a key isn't forwarded to
// something that isn't, which is how a bar's OK reaches it.)
import QtQuick 2.12
import QtTest 1.2
import "../../app/qml"

Item {
    id: root
    width: 1920; height: 200
    property int chosenKind: 0
    SearchBar {
        id: bar
        width: 1920; focus: true; open: true
        kinds: ["Anime", "Series", "Movies"]
        kind: root.chosenKind
        onChosen: root.chosenKind = index
    }
    SignalSpy { id: left; target: bar; signalName: "exitLeft" }

    TestCase {
    name: "SearchBar"
    when: windowShown
    function init() { root.chosenKind = 0; bar.zone = 0; bar.text = ""; left.clear(); tryVerify(function () { return bar.kindBar.visible }) }      // (the bar is opening as the test starts)
    function test_theCursorCrossesWithoutChoosing() {
        keyClick(Qt.Key_Right);                                 // off the end of the text
        compare(bar.zone, 1);
        verify(bar.kindBar.activeFocus);
        compare(bar.kindBar.cursor, 0, "onto the first kind");
        keyClick(Qt.Key_Right); keyClick(Qt.Key_Right);
        compare(bar.kindBar.cursor, 2);
        compare(root.chosenKind, 0, "the kinds crossed weren't chosen");
        keyClick(Qt.Key_Right);
        compare(bar.kindBar.cursor, 2, "nothing past the last");
        keyClick(Qt.Key_Return);
        tryVerify(function () { return root.chosenKind === 2 }, 2000, "OK chooses");       // (a tap is told from a hold a moment after the release)
        compare(bar.kindBar.currentIndex, 2);
    }
    function test_leftGoesBackToTheFieldThenOut() {
        bar.zone = 1; wait(0);
        compare(bar.kindBar.cursor, 0, "given the remote from under it, the cursor is on the chosen kind");
        keyClick(Qt.Key_Left);
        compare(bar.zone, 0, "left of the first kind is the field");
        compare(left.count, 0);
        keyClick(Qt.Key_Left);
        compare(left.count, 1, "and left of the text is out");
    }
    function test_arrivingFromBelowIsOnTheChosenKind() {
        root.chosenKind = 1;
        bar.zone = 1; wait(0);
        compare(bar.kindBar.cursor, 1);
    }
}
}
