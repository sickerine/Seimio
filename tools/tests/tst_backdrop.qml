// Backdrop: `settling` says when what it shows is changing, which is when a frozen blur of it has to
// follow. Waiting for a picture is not that: nothing on screen has changed until the crossfade starts.
// A frost that followed through the wait captured twenty times a second for nothing.
import QtQuick 2.12
import QtTest 1.2
import Seimio.UI 1.0

Item {
    width: 640; height: 360
    Backdrop { id: hero; anchors.fill: parent }
    readonly property string first: Qt.resolvedUrl("../../app/icon.png")
    readonly property string second: Qt.resolvedUrl("../preview/baseline/home.png")

    TestCase {
        name: "Backdrop"; when: windowShown
        function test_itSettlesWhileItChangesNotWhileItWaits() {
            hero.target = first;
            tryVerify(function () { return hero.shown === first && !hero.fading }, 5000, "the first picture is on");
            verify(!hero.busy); verify(!hero.settling);
            hero.target = "http://192.0.2.1/never.png";         // an address that doesn't answer
            wait(250);
            if (hero.shown !== first || hero.fading) skip("the address that should not answer did");
            verify(hero.busy, "it wants another picture");
            verify(!hero.settling, "and waits for it with nothing on screen changed: nothing to follow");
            hero.target = second;                               // one that comes: the crossfade
            tryVerify(function () { return hero.fading }, 5000);
            verify(hero.settling, "a crossfade is followed");
            tryVerify(function () { return hero.shown === second && !hero.fading }, 5000);
            verify(!hero.settling, "and it is over with it");
        }
        function test_aMoveAlongARowIsFollowedToo() {
            hero.pan = 10;
            verify(hero.settling, "the picture is shifting");
            tryVerify(function () { return !hero.settling }, 2000);
            hero.pan = 0; tryVerify(function () { return !hero.settling }, 2000);
        }
    }
}
