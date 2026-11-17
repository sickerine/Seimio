// Latch: what fades out keeps showing what it showed. `current` follows `value` while `live`, holds the
// last live value once `live` turns false (a panel closing), and takes `value` again when live.
import QtQuick 2.12
import QtTest 1.2
import Seimio.UI 1.0

TestCase {
    name: "Latch"
    property string zone: "subs"
    property bool open: true
    Latch { id: kind; value: zone; live: open }
    function test_holdsWhileClosing() {
        compare(kind.current, "subs");
        open = false; zone = "row";                        // the panel closes: Back sets both at once
        compare(kind.current, "subs", "the closing panel still shows the subtitle list");
        zone = "audio";
        compare(kind.current, "subs", "and doesn't follow while closed");
        open = true;
        compare(kind.current, "audio", "opening again takes the new value");
        zone = "subs";
        compare(kind.current, "subs", "and follows while open");
    }
}
