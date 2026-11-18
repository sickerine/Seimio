// A card, a season tab or a button held for its menu keeps its focused look while the menu has the
// remote. The card went back to its resting size under the menu, and the frost's cutout, cut for the
// lifted card, stood wider than it; only Continue Watching's row had a rule of its own for it.
import QtQuick 2.12
import QtTest 1.2
import Seimio.UI 1.0

Item {
    width: 1920; height: 600
    FocusScope {
        id: screen
        width: 1920; height: 400
        focus: true
        CardStrip { id: strip; width: 1920; focus: true; model: [{ title: "a", art: "" }, { title: "b", art: "" }] }
    }
    Item { id: menu; focus: false }

    TestCase {
        name: "HeldFocus"; when: windowShown
        function cleanup() { Remote.menuOver = false; screen.focus = true; menu.focus = false }
        function test_underAMenuTheCardStaysLifted() {
            screen.forceActiveFocus();
            verify(strip.showFocus);
            Remote.menuOver = true;                         // the app says a menu opens, then takes the remote
            menu.forceActiveFocus();
            verify(!strip.activeFocus);
            verify(strip.showFocus, "drawn focused under the menu");
            Remote.menuOver = false;                        // the menu closed, on to something else
            verify(!strip.showFocus, "and as it is once the menu has gone");
        }
        function test_leftForSomethingElseItRests() {
            screen.forceActiveFocus();
            menu.forceActiveFocus();                        // no menu: the remote just went elsewhere
            verify(!strip.showFocus);
        }
    }
}
