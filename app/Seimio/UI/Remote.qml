// What the LG remote's keys mean, and the app's one OK gesture.
pragma Singleton
import QtQuick 2.12

QtObject {
    id: remote
    // LG's remote sends its own code for Back (0x1200003); Escape and Back cover keyboards and the Mac
    function isBack(k) { return k === Qt.Key_Escape || k === Qt.Key_Back || k === 0x1200003 }
    function isOk(k) { return k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Select }
    // nothing pressed and nothing set moving for a second (the app says so): what only moves by itself
    // (Ambient) runs on the render thread meanwhile. Whatever starts moving without a key press (rows
    // that came in, a backdrop crossfading) says so with stir()
    property bool resting: false
    signal stirred()
    function stir() { resting = false; stirred() }
    // lab: how many times each kind of redraw has happened ("grid shown", "info", ...). An action on one
    // title (removed from the library, marked watched) should redraw that title and nothing else: read
    // the counts in the lab report before and after it (LabProbe's state, `redraws`).
    property var tallies: ({})
    function tally(what) { tallies[what] = (tallies[what] || 0) + 1 }

    // OK tap or hold (Apple TV's long press). LG's remote doesn't auto-repeat a held key the usual way:
    // it sends release and press pairs about 40 ms apart. So a hold is timed (500 ms from the press),
    // and a release followed by a press within 90 ms is the same hold. There is one gesture at a time,
    // owned by the OkPress that saw its first press. A hold that moves focus (opening quick actions)
    // keeps its owner: the rest of the hold reaches the new focus only to continue the gesture, so it
    // can't press anything there.
    property QtObject owner: null
    property bool fired: false
    property Timer holdTimer: Timer {
        interval: 500
        onTriggered: { remote.fired = true; if (remote.owner) remote.owner.held() }
    }
    property Timer releaseTimer: Timer {
        interval: 90
        onTriggered: {
            remote.holdTimer.stop();
            var o = remote.owner;
            remote.owner = null;
            if (o && !remote.fired) o.tapped();
        }
    }
    function okPress(who, event) {
        if (event.isAutoRepeat) return;
        if (releaseTimer.running) { releaseTimer.stop(); return }     // a repeat pair: still holding
        if (owner) return;
        owner = who; fired = false; holdTimer.restart();
    }
    function okRelease(event) { if (!event.isAutoRepeat && owner) releaseTimer.restart() }
}
