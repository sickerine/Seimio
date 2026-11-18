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
    SearchField { id: field; focus: typing }
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
