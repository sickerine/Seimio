// SearchField: it has the remote only while it is given it (`focus`); `open` is how it looks. A field that
// opened again over results that had the remote (back up to the first row, back from a title's page) took
// it from them: the TV's keyboard came up over the results and Back went nowhere, since the app still took
// the results to have the remote.
import QtQuick 2.12
import QtTest 1.2
import Seimio.UI 1.0

TestCase {
    id: test
    name: "SearchField"
    when: windowShown
    width: 1920; height: 200
    property bool typing: false              // the field has the remote, not the results
    FocusScope {
        focus: !typing
        Item { id: card; focus: true }
    }
    QtObject { id: keys; property bool visible: false; function show() { visible = true } function hide() { visible = false } function commit() {} }       // the TV's keyboard
    SearchField { id: field; focus: test.typing; keyboard: keys }       // (`typing` alone is the field's own, in here)
    // what the field's owner sees as it is told of an Enter
    property var told: []
    Connections { target: field; onAccepted: told = told.concat([(keys.visible ? "keyboard up" : "keyboard away") + ", '" + field.text + "'"]) }
    // Enter on the keyboard makes the search of what is typed and puts the keyboard away. The field does
    // both itself, the keyboard first: left to the text, Qt put the keyboard away and only then said
    // `accepted`, so on the TV the keyboard going was taken for Back and the bar was cleared the moment
    // before its search was made ("all it does is clear the query").
    function test_enterSearchesWhatIsTyped() {
        typing = true; wait(0);
        keys.visible = true; field.text = "dark"; told = [];
        keyClick(Qt.Key_Return);
        compare(told.join(" | "), "keyboard away, 'dark'", "the keyboard away first, then the search, of what was typed");
        compare(field.text, "dark");
    }
    // Back with the keyboard up is the keyboard's: it goes, and what is typed stays. (The field took a
    // keyboard that went for Back and had the bar cleared.) OK then brings the keyboard back.
    function test_theKeyboardGoingKeepsWhatIsTyped() {
        typing = true; wait(0);
        keys.visible = true; field.text = "demon"; told = [];
        keys.visible = false;                                   // Back, which only the keyboard sees
        compare(field.text, "demon");
        compare(told.length, 0, "and no search is told of");
        keyClick(Qt.Key_Return);                                // OK with the keyboard away
        verify(keys.visible, "brings it back");
        compare(told.length, 0);
    }
    function cleanup() { typing = false; wait(0) }
    function test_opensWithoutTakingTheRemote() {
        verify(card.activeFocus);
        field.open = true; wait(0);
        verify(card.activeFocus, "results that have the remote keep it when the field opens again");
        typing = true; wait(0);
        verify(field.activeFocus, "given the remote, its text takes it (which brings the keyboard up)");
        typing = false; wait(0);
        verify(card.activeFocus, "and gives it back");
    }
}
