// Tells a tap of OK from a hold (Apple TV's long press). A component that handles keys forwards OK to
// press() and release(). LG's remote doesn't auto-repeat a held key the usual way: it sends release and
// press pairs about 40 ms apart. So a hold is timed (500 ms from the press), and a release followed by
// a press within 90 ms counts as still holding.
import QtQuick 2.12

Item {
    id: ok
    signal tapped()
    signal held()
    property bool holding: false
    property bool fired: false

    function press(event) {
        if (event.isAutoRepeat) return;
        if (releaseTimer.running) { releaseTimer.stop(); return }      // a repeat pair: still holding
        if (!holding) { holding = true; fired = false; holdTimer.restart() }
    }
    function release(event) {
        if (!event.isAutoRepeat && holding) releaseTimer.restart();
    }
    Timer { id: holdTimer; interval: 500; onTriggered: if (ok.holding) { ok.fired = true; ok.held() } }
    Timer {
        id: releaseTimer; interval: 90
        onTriggered: { ok.holding = false; holdTimer.stop(); if (!ok.fired) ok.tapped(); ok.fired = false }
    }
}
