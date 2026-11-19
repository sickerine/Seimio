// Backdrop: `settling` says when what it shows is changing, which is when a frozen blur of it has to
// follow. Waiting for a picture is not that: nothing on screen has changed until the crossfade starts.
// A frost that followed through the wait captured twenty times a second for nothing.
// And `blurred`, the blur it keeps of itself: it is made once a picture, so it has to be what a blur of
// the backdrop as drawn would be, after a picture has changed too (a blur left at the picture before,
// or the two pictures' blurs the wrong way round, is the frost showing another title's colours).
import QtQuick 2.12
import QtQuick.Window 2.12
import QtTest 1.2
import Seimio.UI 1.0

Item {
    width: 1280; height: 360
    // side by side (a grab is the window's pixels where the item lies): the backdrop under a frost that
    // blurs it as it is drawn, and beside them a frost of the blur the backdrop keeps
    Item {
        width: 640; height: 360
        Backdrop { id: hero; anchors.fill: parent; blurWanted: true }
        Frost { id: drawn; anchors.fill: parent; source: hero; frozen: true }
    }
    Frost { id: kept; x: 640; width: 640; height: 360; made: hero.blurred; madeSize: hero.blurredSize }
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
        // An item's pixels. macOS doesn't draw a window that is covered, and a grab then comes back empty:
        // the window is brought forward and asked again, and with none in two seconds there is nothing to
        // compare, which is a failure (two empty pictures are alike everywhere).
        function shot(item) {
            for (var i = 0; i < 20; i++) {
                var g = grabImage(item);
                if (g.width > 0 && g.height > 0) return g;
                hero.Window.window.raise(); wait(100);
            }
            fail("the window isn't being drawn (covered, or the display off): no picture of it to compare");
        }
        // the two frosts at fifteen places: the furthest apart they are, in levels of 255
        function apart() {
            drawn.refresh(); wait(120);
            var a = shot(kept), b = shot(drawn), worst = 0;
            for (var x = 1; x <= 5; x++) for (var y = 1; y <= 3; y++) {
                var px = Math.round(x * a.width / 6), py = Math.round(y * a.height / 4);
                worst = Math.max(worst, Math.abs(a.red(px, py) - b.red(px, py)), Math.abs(a.green(px, py) - b.green(px, py)), Math.abs(a.blue(px, py) - b.blue(px, py)));
            }
            return worst;
        }
        function test_itsKeptBlurIsABlurOfWhatItShows() {
            Theme.still = true;                                 // the drift held, so both blur the same moment
            hero.target = first;
            tryVerify(function () { return hero.shown === first && !hero.fading }, 5000);
            var g = shot(kept), one = g.pixel(g.width / 2, g.height / 2);
            verify(apart() <= 6, "of the first picture");
            hero.target = second;
            tryVerify(function () { return hero.shown === second && !hero.fading }, 5000);
            verify(apart() <= 6, "and of the one after it, once it has come");
            g = shot(kept);
            verify(!Qt.colorEqual(g.pixel(g.width / 2, g.height / 2), one), "(the two pictures blur to different colours there)");
            Theme.still = false;
        }
        function test_aMoveAlongARowIsFollowedToo() {
            hero.pan = 10;
            verify(hero.settling, "the picture is shifting");
            tryVerify(function () { return !hero.settling }, 2000);
            hero.pan = 0; tryVerify(function () { return !hero.settling }, 2000);
        }
    }
}
