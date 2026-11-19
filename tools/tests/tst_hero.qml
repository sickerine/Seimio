// HeroInfo never settles on its item while faded out. Run by tools/check.sh:
//   qmltestrunner -input tools/tests -import app -import tools/preview/imports
import QtQuick 2.12
import QtTest 1.2
import Seimio.UI 1.0
import "../../app/qml"

Item {
    width: 1920; height: 1080
    HeroInfo { id: info }
    readonly property string logo: Qt.resolvedUrl("../../app/icon.png")
    function find(o, test) { if (o && test(o)) return o; for (var i = 0; o && o.children && i < o.children.length; i++) { var r = find(o.children[i], test); if (r) return r } return null }
    // a chip's entrance (a Reveal): each time it starts over, `t` falls
    property int startsOver: 0
    property real lastT: 0
    Connections { id: chipWatch; target: null; onTChanged: { if (target.t < lastT - 0.001) startsOver++; lastT = target.t } }

    TestCase {
        name: "HeroInfo"; when: windowShown
        // A title's chips come in once, with it. They started over each time the panel looked at its
        // title again (its logo turning ready, its fade ending), so they flashed until it was in.
        function test_theChipsComeInOnceATitle() {
            info.item = { name: "A", logo: logo, chips: ["TV", "2024"], description: "" }; wait(1500);
            var chip = find(info, function (o) { return o.play !== undefined && o.delay !== undefined });
            verify(chip, "the first chip's entrance");
            compare(chip.t, 1);
            startsOver = 0; lastT = chip.t; chipWatch.target = chip;
            info.item = { name: "B", logo: logo, chips: ["Film", "2025"], description: "" };
            wait(Theme.settle + 1200);
            chipWatch.target = null;
            compare(info.m.name, "B"); compare(info.fadeIn, 1);
            compare(chip.t, 1, "in whole");
            compare(startsOver, 1, "started over once, as the title changed out of sight");
        }
        // The panel rises a little longer than it fades: it is busy until it has stopped, so a frost
        // frozen over it is not left with the title short of its place.
        function test_itIsBusyUntilItHasStoppedMoving() {
            info.item = { name: "R", logo: logo, chips: [], description: "" };
            tryVerify(function () { return info.m && info.m.name === "R" && info.fadeIn === 1 && info.rise > 0 }, 3000, "in, and still rising");
            verify(info.busy);
            tryVerify(function () { return info.rise === 0 });
            verify(!info.busy);
        }
        // The same title given again as another object (the Anime tab's show once it is made playable)
        // takes its place with nothing moving: its chips say the same, and stay.
        function test_theSameTitleAgainMovesNothing() {
            info.item = { name: "S", logo: logo, chips: ["TV", "2024"], description: "s" }; wait(1500);
            var chip = find(info, function (o) { return o.play !== undefined && o.delay !== undefined });
            startsOver = 0; lastT = chip.t; chipWatch.target = chip;
            var again = { name: "S", logo: logo, chips: ["TV", "2024"], description: "s" };
            info.item = again; wait(600);
            chipWatch.target = null;
            verify(info.m === again, "it is the one on show");
            compare(info.fadeIn, 1); compare(chip.t, 1);
            compare(startsOver, 0, "nothing started over");
        }
        // Hidden (null), then a new object whose logo is already cached: the preload turns Ready inside
        // onItemChanged and used to swap in before the fade-out started, then fade the new title out.
        function test_hiddenThenCachedLogo() {
            info.item = { name: "A", logo: logo, chips: [], description: "" }; wait(1200);
            compare(info.fadeIn, 1, "the logo loaded");
            info.item = null; wait(400);
            var again = { name: "A", logo: logo, chips: [], description: "" };
            info.item = again;
            compare(info.m, again, "a cached logo swaps in at once");
            wait(1200);
            verify(info.m === again);
            compare(info.fadeIn, 1);
        }
        // A goes out for B, whose logo is in; before B comes in it is replaced by C, whose logo is still
        // on its way. The panel stood empty until C's logo arrived: A comes back and stays until then.
        function test_theTitleOnScreenComesBackWhileItsReplacementLoads() {
            var a = { name: "A", logo: logo, chips: [], description: "a" };
            info.item = a; wait(1200);
            info.item = { name: "B", logo: logo, chips: [], description: "b" };      // (the same picture: in at once)
            info.item = { name: "C", logo: "http://192.0.2.1/never.png", chips: [], description: "c" };   // an address that doesn't answer
            wait(60);
            if (info.labState().preload !== Image.Loading) skip("the address that should not answer did");
            wait(Theme.settle + 300);
            compare(info.m, a, "A is still the title on screen");
            compare(info.fadeIn, 1, "and is fully in while C's logo is fetched");
            info.item = a; wait(600);
        }
        // Titles are taken a rest apart (Theme.settle). The swap took longer than the rest, so a title
        // taken was still fading in when the next was: along a show's seasons the logo flickered in and
        // out and never came in whole.
        function test_aTitleIsInBeforeTheNextCanBeTaken() {
            info.item = { name: "A", logo: logo, chips: [], description: "" }; wait(1200);
            var b = { name: "B", logo: logo, chips: [], description: "" };
            info.item = b; wait(Theme.settle + 40);         // (40 ms: a frame or two of the test's own timing)
            compare(info.m, b);
            compare(info.fadeIn, 1, "fully in a rest after it was taken");
        }
        // A title that changes on screen says the app is moving. At rest what moves by itself is on the
        // render thread, which then draws frames without the GUI thread's turn: a title whose data came
        // late, into a resting app, came in with its chips standing still for a frame now and then.
        // Out of sight it says nothing: a page built ahead at rest must not end the rest it is built in.
        function test_aTitleChangingOnScreenEndsTheRest() {
            info.item = { name: "A", logo: logo, chips: ["TV"], description: "" }; wait(1200);
            Remote.resting = true;
            info.item = { name: "Late", logo: logo, chips: ["Film"], description: "" };
            tryVerify(function () { return info.m && info.m.name === "Late" }, 3000);
            verify(!Remote.resting, "it moved on screen");
            wait(1200); info.visible = false; Remote.resting = true;
            info.item = { name: "Unseen", logo: logo, chips: [], description: "" };
            tryVerify(function () { return info.m && info.m.name === "Unseen" }, 3000);
            verify(Remote.resting, "and out of sight it did not");
            info.visible = true; Remote.resting = false;
        }
    }
}
