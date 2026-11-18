// Fade: what leaves keeps showing what it showed until it has gone. A chip whose words were bound to the
// state that hid it ("Loading Summer 2026") emptied the moment its fade began.
import QtQuick 2.12
import QtTest 1.2
import Seimio.UI 1.0

TestCase {
    name: "Fade"
    when: windowShown
    width: 400; height: 100
    property string notice: ""
    Fade { id: fade; value: notice; duration: 120; Text { text: parent.current || "" } }
    function test_holdsItsWordsUntilGone() {
        verify(fade.gone, "nothing to show: not there");
        notice = "Loading Summer 2026";
        tryCompare(fade, "t", 1);
        compare(fade.current, "Loading Summer 2026");
        notice = "";                                        // the season is in: the chip leaves
        wait(40);
        verify(!fade.gone && fade.t < 1, "on its way out");
        compare(fade.current, "Loading Summer 2026", "still saying what it said");
        tryVerify(function () { return fade.gone });
        notice = "Couldn't load Winter 2027";
        tryCompare(fade, "current", "Couldn't load Winter 2027");
    }
}
