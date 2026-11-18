// SearchField: it has the remote only while it is given it (`focus`); `open` is how it looks. A field that
// opened again over results that had the remote (back up to the first row, back from a title's page) took
// it from them: the TV's keyboard came up over the results and Back went nowhere, since the app still took
// the results to have the remote.
import QtQuick 2.12
import QtTest 1.2
import Seimio.UI 1.0

TestCase {
    name: "SearchField"
    when: windowShown
    width: 1920; height: 200
    property bool typing: false              // the field has the remote, not the results
    FocusScope {
        focus: !typing
        Item { id: card; focus: true }
    }
    QtObject { id: keys; property bool visible: false; function show() { visible = true } }       // the TV's keyboard
    SearchField { id: field; focus: typing; keyboard: keys }
    SignalSpy { id: dismissed; target: field; signalName: "dismissed" }
    // Back with the keyboard up closes the keyboard, and the field takes a keyboard that went without an
    // Enter as that Back. After an Enter, OK brought the keyboard back and the Back that closed it then
    // was still taken for the Enter: the query stayed.
    function test_backAfterTheKeyboardCameBack() {
        typing = true; wait(0);
        keys.visible = true; field.text = "demon";
        keyClick(Qt.Key_Return); keys.visible = false;          // Enter, and the keyboard goes
        compare(dismissed.count, 0, "Enter closing the keyboard is no Back");
        keyClick(Qt.Key_Return);                                // OK with the keyboard away
        verify(keys.visible, "brings it back");
        keys.visible = false;                                   // Back, which only the keyboard sees
        compare(dismissed.count, 1, "the keyboard going without an Enter is Back");
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
