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
        wait(0);
        compare(kind.current, "subs", "the closing panel still shows the subtitle list");
        zone = "audio";
        wait(0);
        compare(kind.current, "subs", "and doesn't follow while closed");
        open = true;
        wait(0);
        compare(kind.current, "audio", "opening again takes the new value");
        zone = "subs";
        wait(0);
        compare(kind.current, "subs", "and follows while open");
    }

    // the usual case: what it shows and whether it's open come from the same property (the panel is
    // open while the zone is a list), so their bindings update in no set order
    property string zone2: "subs"
    Latch { id: derived; value: zone2; live: zone2 === "subs" || zone2 === "audio" }
    function test_holdsWhenBothFollowOneProperty() {
        compare(derived.current, "subs");
        zone2 = "row";
        wait(0);
        compare(derived.current, "subs", "closing keeps the subtitle list even when the value's binding ran first");
        zone2 = "audio";
        wait(0);
        compare(derived.current, "audio");
    }
}
