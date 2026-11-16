// HeroInfo never settles on its item while faded out. Run by tools/check.sh:
//   qmltestrunner -input tools/tests -import app -import tools/preview/imports
import QtQuick 2.12
import QtTest 1.2
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
    }
}
