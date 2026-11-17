// Mac stand-in for the TV plugin's NativePlayer: hands out a window id and accepts a load, so the player
// screen's loading states can be previewed. Nothing plays.
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
    signal event(string json)
    function exportWindow(w) { windowId = "mac"; return "" }
    function setEventSlot(n) {}
    function load(uri, payload) { return true }
    function play() { return true }
    function pause() { return true }
    function seek(ms) { return true }
    function selectTrack(t, i) { return true }
    function unload() { playing = false; return true }
}
