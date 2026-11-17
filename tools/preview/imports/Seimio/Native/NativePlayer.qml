// Mac stand-in for the TV plugin's NativePlayer: hands out a window id and, once loaded, acts as if a
// 23:42 episode plays 10 minutes in, so the player's screens can be previewed. Nothing plays.
import QtQuick 2.12
QtObject {
    property string windowId: ""
    property bool loaded: false
    property bool playing: false
    property bool paused: false
    property bool buffering: false
    property string failure: ""
    property double duration: 0
    property double position: 0
    property int audioTrack: -1
    property double startFraction: 0
    property var languages: ["en"]
    property var seen: ({})
    property var audioTracks: []
    property int preferredAudio: -1
    function selectAudio(i) { audioTrack = i; return true }
    function mute(on) { return true }
    signal event(string json)
    function exportWindow(w) { windowId = "mac"; return "" }
    function setEventSlot(n) {}
    function load(uri, payload) { loaded = true; playing = true; duration = 1422046; position = 600000; return true }
    function play() { paused = false; return true }
    function pause() { paused = true; return true }
    function seek(ms) { position = ms; return true }
    function selectTrack(t, i) { return true }
    function unload() { playing = false; return true }
}
