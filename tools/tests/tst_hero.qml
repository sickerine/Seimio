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

    TestCase {
        name: "HeroInfo"; when: windowShown
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
    }
}
