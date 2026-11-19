// SearchBar: one cursor for the field and the kinds at its left. The row is walked by where it sits: the
// tabs are to the right of the search, so the field is the near end and the kinds are beyond it. Left
// from the start of the text is the kinds, at the near one; crossing a kind doesn't choose it (the
// results under the bar would change on the way to the kind meant), OK does. Right from the last kind is
// the field again, and Right from the end of the text leaves the search for the tabs.
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
    SignalSpy { id: out; target: bar; signalName: "exitRight" }

    TestCase {
    name: "SearchBar"
    when: windowShown
    function init() { root.chosenKind = 0; bar.zone = 0; bar.text = ""; out.clear(); tryVerify(function () { return bar.kindBar.visible }) }      // (the bar is opening as the test starts)
    function test_theKindsAreAtTheFieldsLeft() {
        var field = null;
        for (var i = 0; i < bar.children.length; i++) if (bar.children[i].openWidth !== undefined) field = bar.children[i];
        verify(field, "the field");
        tryCompare(field, "t", 1);                              // (open all the way)
        verify(bar.kindBar.x + bar.kindBar.width < 960, "the kinds end left of the middle");
        verify(field.x > bar.kindBar.x + bar.kindBar.width, "and the field starts after them");
        fuzzyCompare(bar.kindBar.x, 1920 - (field.x + field.width), 2, "the two as one row in the middle of the bar");
    }
    function test_theCursorCrossesWithoutChoosing() {
        root.chosenKind = 2;
        keyClick(Qt.Key_Left);                                  // off the start of the text
        compare(bar.zone, 1);
        verify(bar.kindBar.activeFocus);
        compare(bar.kindBar.cursor, 2, "onto the near kind, the last");
        keyClick(Qt.Key_Left); keyClick(Qt.Key_Left);
        compare(bar.kindBar.cursor, 0);
        compare(root.chosenKind, 2, "the kinds crossed weren't chosen");
        keyClick(Qt.Key_Left);
        compare(bar.kindBar.cursor, 0, "nothing past the first");
        compare(bar.zone, 1);
        keyClick(Qt.Key_Return);
        tryVerify(function () { return root.chosenKind === 0 }, 2000, "OK chooses");       // (a tap is told from a hold a moment after the release)
        compare(bar.kindBar.currentIndex, 0);
    }
    function test_rightGoesBackToTheFieldThenOut() {
        bar.zone = 1; wait(0);
        compare(bar.kindBar.cursor, 0, "given the remote from under it, the cursor is on the chosen kind");
        keyClick(Qt.Key_Right); keyClick(Qt.Key_Right);
        compare(bar.kindBar.cursor, 2); compare(bar.zone, 1);
        keyClick(Qt.Key_Right);
        compare(bar.zone, 0, "right of the last kind is the field");
        compare(out.count, 0);
        keyClick(Qt.Key_Right);
        compare(out.count, 1, "and right of the text is out, to the tabs");
    }
    function test_rightInsideTheTextMovesInIt() {
        bar.text = "ab";                                        // (its cursor is at its end)
        keyClick(Qt.Key_Left);
        compare(bar.zone, 0, "the text's own cursor moved, not the row's");
        keyClick(Qt.Key_Right);
        compare(out.count, 0, "and moved back to its end");
        keyClick(Qt.Key_Right);
        compare(out.count, 1, "past its end is out");
    }
    function test_arrivingFromBelowIsOnTheChosenKind() {
        root.chosenKind = 1;
        bar.zone = 1; wait(0);
        compare(bar.kindBar.cursor, 1);
    }
}
}
