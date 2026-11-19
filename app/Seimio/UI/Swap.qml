// Swap: one thing on show at a time, and the one way it becomes another. Its owner says what it wants on
// show (`want`) and whether that one's content is loaded (`ready`); Swap says what is on show (`shown`)
// and how far in it is (`level`), and the owner draws that. The rules, which every screen that swaps what
// it shows gets by using this (tools/tests/tst_swap.qml has a test for each):
//  - What is on show stays, fully in, until what is wanted is ready. Nothing empties while a picture is
//    fetched, and a name never shows where its logo is about to.
//  - Then the one on show goes out (`outMs`), `shown` becomes the other at the moment nothing is seen
//    (`switched`), and that one comes in (`inMs`). With `cross` the new one comes in over the old
//    instead (`coming`, `level` its way in), and `shown` becomes it at the end.
//  - Wanting what is on show again, at any point, brings it back in from where it is. A want that shows
//    the same thing (`same`) takes its place with nothing moving.
//  - A want that changes on the way replaces the one before it. If the one on show was going out for a
//    want that is replaced by one not ready yet, it comes back and stays until that one is.
//  - Wanting nothing takes what is on show out at once; it is still `shown`, out of sight (`level` 0),
//    so wanting it again brings it straight back. With `cross`, nothing wanted keeps what is shown.
//  - A crossfade that has started finishes; the newest want is taken up after it. One whose content
//    can't be had (`failed`) is let go, and what is shown stays until something else is wanted.
//  - A fade starts from where `level` is and takes that much of its time: going out half way in, coming
//    back half way out. One coming in where nothing was on show can take another time (`appearMs`), and
//    with no time to go out or come in (`outMs`, `inMs` 0) one takes the other's place in the same frame.
//  - `settled` once what is wanted is on show and fully in (or nothing is wanted and it is out); `cut`
//    when one coming in is replaced before it was in, which is a flicker and is counted.
// Decisions are taken once the owner's bindings have all run (as Fade and Latch do), never half way
// through an assignment: a picture that is in memory turns ready inside the assignment that asks for
// it, and a handler that read a bound flag there read the one from before.
// Compose's AnimatedContent and DeferredTransitionState, Motion's AnimatePresence "wait" and React's
// transitions are where the rules come from (docs/state-and-query-research.md). Qt's own state machine
// (QtQml.StateMachine) isn't under this: it takes a transition only on a signal sent after a state is
// entered, so a condition already true on the way in, a logo in memory, needs the same glue by hand.
import QtQuick 2.12

QtObject {
    id: swap
    // ---- what the owner says
    property var want: null
    property bool ready: true               // `want`'s content is loaded (or can't be had, and shows as it is)
    property bool failed: false             // crossing: `want`'s content can't be had
    property bool cross: false
    property int outMs: Math.round(Theme.settle * 0.32)
    property int inMs: Theme.settle - outMs
    property int appearMs: inMs             // how long one takes to come in where nothing was on show
    property int easing: Theme.ease
    property var same: null                 // function (a, b): the two show the same thing. None: they are the same object

    // ---- what it shows
    property var shown: null
    property var coming: null               // crossing: the one coming in over `shown`
    property real level: 0                  // how far in `shown` is; crossing, how far in `coming` is
    property string phase: "rest"           // "rest" | "waiting" (for `ready`) | "leaving" | "entering"
    readonly property bool busy: phase !== "rest" || (cross ? want !== null && !alike(want, shown) && want !== gaveUp
                                                            : want === null ? level > 0 : !alike(want, shown) || level < 1)
    signal switched()
    signal settled()
    signal cut()

    function alike(a, b) { return a === b || (!!a && !!b && !!same && same(a, b)) }
    onWantChanged: {
        if (!cross && phase === "entering" && want !== null && !alike(want, shown)) cut();
        Qt.callLater(swap.step);
    }
    onReadyChanged: Qt.callLater(swap.step)
    onFailedChanged: Qt.callLater(swap.step)
    Component.onCompleted: step()

    property bool gone: true                // out for nothing being wanted (or nothing shown yet), not on the way to another
    property var gaveUp: null               // crossing: the want whose content couldn't be had

    function step() {
        if (cross) { stepCross(); return }
        var w = want;
        if (w === null) {                               // nothing wanted: out at once
            gone = true;
            if (level > 0) { if (phase !== "leaving") leave() } else rest();
            return;
        }
        if (shown !== null && alike(w, shown)) {        // what is on show is wanted (again): in place, and back in
            shown = w; gone = false;
            if (level < 1) { if (phase !== "entering") enter() } else rest();
            return;
        }
        if (!ready) {
            // not loaded yet: the one on show stays, and comes back if it was going out for another
            if (!gone && shown !== null && level < 1) { if (phase !== "entering") enter() }
            else if (phase !== "leaving") phase = "waiting";
            return;
        }
        if (level > 0 && shown !== null && outMs > 0) { if (phase !== "leaving") leave(); return }      // the one on show goes out first
        var appearing = gone || shown === null;
        fadeOut.stop();
        if (!appearing && outMs <= 0) level = inMs > 0 ? 0 : 1;     // with no going out, the old one is gone at once (and with no coming in either, the new one is there)
        shown = w; gone = false;                        // the moment nothing is seen: the other is on show from here
        switched();
        if (level < 1) enter(appearing ? appearMs : inMs); else rest();
    }
    function leave() { phase = "leaving"; fadeIn.stop(); fadeOut.duration = Math.max(1, Math.round(outMs * level)); fadeOut.restart() }
    function enter(ms) { phase = "entering"; fadeOut.stop(); fadeIn.duration = Math.max(1, Math.round((ms === undefined ? inMs : ms) * (1 - level))); fadeIn.restart() }
    function rest() {
        var was = phase;
        phase = "rest";
        if (was !== "rest" && !busy) settled();
    }
    property NumberAnimation fadeOut: NumberAnimation {
        target: swap; property: "level"; to: 0; easing.type: Easing.InQuad
        onFinished: { swap.phase = "waiting"; swap.step() }
    }
    property NumberAnimation fadeIn: NumberAnimation {
        target: swap; property: "level"; to: 1; easing.type: swap.easing
        onFinished: { if (swap.cross) swap.crossed(); else { swap.phase = "waiting"; swap.step() } }
    }

    // ---- crossing: `coming` fades in over `shown`
    function stepCross() {
        if (phase === "entering") return;               // finishes first; then the newest want
        var w = want;
        if (w !== gaveUp) gaveUp = null;
        if (w === null || alike(w, shown) || w === gaveUp) { if (w !== null && w !== gaveUp) shown = w; coming = null; rest(); return }
        coming = w;                                     // (its owner starts loading it here, and `ready` and `failed` are of this one from now)
        if (failed) { gaveUp = w; coming = null; rest(); return }
        if (!ready) { phase = "waiting"; return }
        phase = "entering"; level = 0;
        fadeIn.duration = inMs; fadeIn.restart();
    }
    function crossed() {
        shown = coming; coming = null; level = 0;
        switched();
        phase = "waiting";
        stepCross();
    }
}
