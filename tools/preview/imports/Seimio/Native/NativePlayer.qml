// Mac stand-in for the TV plugin's NativePlayer: hands out a window id and, once loaded, acts as if a
// 23:42 episode plays 10 minutes in, so the player's screens can be previewed. Nothing plays.
import QtQuick 2.12
QtObject {
    property string windowId: ""
    property bool loaded: false
    property bool playing: false
    property bool paused: false
    property bool buffering: false
    property bool seeking: false
    property string failure: ""
    property double duration: 0
    property double position: 0
    property int audioTrack: -1
    property double startFraction: 0
    property double startAt: -1
    property bool waits: false
    signal stateChanged()
    property var languages: ["en"]
    property var seen: ({})
    property var audioTracks: []
    property int preferredAudio: -1
    function selectAudio(i) { audioTrack = i; return true }
    function mute(on) { return true }
    signal event(string json)
    function exportWindow(w) { windowId = "mac"; return "" }
    function setEventSlot(n) {}
    // (as the TV's does: loaded, it plays from where it was told to start, unless it `waits` for play())
    function begin() { playing = true; position = startAt >= 0 ? startAt : startFraction > 0 ? startFraction * duration : 600000 }
    function load(uri, payload) { loaded = true; paused = false; duration = 1422046; position = 0; if (!waits) begin(); stateChanged(); return true }
    function play() { paused = false; if (loaded && !playing) begin(); stateChanged(); return true }
    function pause() { paused = true; stateChanged(); return true }
    // (the place asked for at once, and `seeking` until the picture has landed: `land`, a test's)
    function seek(ms) { position = ms; seeking = true; stateChanged(); return true }
    function land(ms) { position = ms; seeking = false; stateChanged() }
    function unload() { playing = false; loaded = false; seeking = false; buffering = false; failure = ""; position = 0; stateChanged(); return true }
    // what else the TV's player does by itself, for a test to make happen
    function stall(on) { buffering = on; stateChanged() }
    function advance(ms) { position += ms }
    function end() { playing = false; stateChanged() }
    function fail(why) { failure = why; playing = false; loaded = false; stateChanged() }
}
