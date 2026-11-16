// Mac stand-in for the TV plugin's NativePlayer: hands out a window id and reports a load, so the player
// screen's loading state can be previewed. Nothing plays.
import QtQuick 2.12
QtObject {
    property string windowId: ""
    signal event(string json)
    function exportWindow(w) { windowId = "mac"; return "" }
    function setEventSlot(n) {}
    function load(uri, payload) { return true }
    function play() { return true }
    function pause() { return true }
    function seek(ms) { return true }
    function selectTrack(t, i) { return true }
    function unload() { return true }
}
