// Ambient goes from the GUI thread to the render thread and back without losing its place (the light
// around today would jump at every rest), and previews hold it at its start.
import QtQuick 2.12
import QtTest 1.2
import Seimio.UI 1.0

Item {
    width: 100; height: 100
    ShaderEffect { id: effect; width: 10; height: 10; property real turn: 0 }
    Ambient { id: ambient; effect: effect; uniform: "turn"; period: 2000 }

    TestCase {
        name: "Ambient"; when: windowShown
        function cleanup() { Remote.resting = false; Theme.still = false }
        function test_keepsItsPlaceAcrossThreads() {
            compare(ambient.driven, 1, "on the GUI thread while things move");
            wait(400);
            var moving = effect.turn;
            verify(moving > 0.1 && moving < 0.4, "a fifth of the way round after 400 ms of 2000: " + moving);
            Remote.resting = true;
            compare(ambient.driven, 2, "on the render thread at rest");
            wait(400);
            Remote.resting = false;
            compare(ambient.driven, 1);
            var back = effect.turn % 1;
            verify(back > moving + 0.1 && back < moving + 0.4, "it went on from where it was: " + moving + " then " + back);
        }
        function test_previewsHoldItAtItsStart() {
            wait(100);
            Theme.still = true;
            compare(ambient.driven, 0);
            compare(effect.turn, 0);
        }
    }
}
