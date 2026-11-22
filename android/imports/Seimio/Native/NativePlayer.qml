// Android's NativePlayer: the LG player's properties and calls (native/src/player.h) over mpv (android/mpv.h),
// and its picture, under the rest of the player screen. As on the LG: `loaded` once the file has opened,
// `playing` from its first frames until it is unloaded or played out (paused or not), `seeking` from a seek
// until the picture has landed, times in ms. A load that `waits` stays at its start, loaded, until play().
import QtQuick
import Seimio.Android

Item {
    id: player
    anchors.fill: parent
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
    property var languages: ["en"]
    property var seen: ({})
    property var audioTracks: []         // LG's own list, for files it reads itself; mpv's tracks come through the Tee
    property int preferredAudio: -1
    // The LG's `stateChanged` is Item's own here (`state`, unused): told() emits it for every change below, as the LG's is
    function told() { stateChanged(state) }
    signal event(string json)

    MpvVideo { anchors.fill: parent; visible: player.loaded }

    // (the LG exports a video window first; here the picture is in the scene, so a load can begin at once)
    function exportWindow(w) { windowId = "mpv"; return "" }
    function setEventSlot(n) {}
    function load(uri, payload) {
        loaded = playing = paused = buffering = seeking = false; failure = ""; duration = position = 0; audioTrack = -1; seen = ({});
        told();
        var start = startAt >= 0 ? "start=" + (startAt / 1000) : startFraction > 0 ? "start=" + (startFraction * 100) + "%" : "start=none";
        Mpv.command(["loadfile", uri, "replace", "-1", start + ",pause=" + (waits ? "yes" : "no")]);
        return true;
    }
    function play() { Mpv.set("pause", false); if (loaded && !playing) { playing = true; told() } return true }
    function pause() { Mpv.set("pause", true); return true }
    // the place asked for at once, and `seeking` until the picture is there
    function seek(ms) { position = ms; seeking = true; told(); Mpv.command(["seek", String(ms / 1000), "absolute"]); return true }
    function selectAudio(i) { audioTrack = i; Mpv.set("aid", i + 1); told(); return true }      // (mpv numbers a kind's tracks from 1, in file order)
    function mute(on) { Mpv.set("mute", on); return true }
    function unload() { Mpv.command(["stop"]); loaded = playing = seeking = buffering = false; failure = ""; told(); return true }

    // the time, four times a second (each change is bindings on the screen), and at once when it lands
    property double shownAt: 0
    Connections {
        target: Mpv
        function onFileLoaded() {
            player.loaded = true; player.seen = { sourceInfo: true };
            if (player.preferredAudio >= 0) player.selectAudio(player.preferredAudio);
            player.told();
        }
        function onRestarted() {
            var was = player.seeking;
            player.seeking = false;
            if (player.loaded && !player.playing && !player.waits) player.playing = true;
            var t = Mpv.get("time-pos");
            if (t !== undefined && t !== null) { player.position = t * 1000; player.shownAt = Date.now() }
            player.told();
        }
        function onEnded(reason, error) {
            if (reason !== "error") return;          // (a stop is ours; a file played out stays, held, as `eof-reached`)
            player.failure = error || "Couldn't play"; player.loaded = player.playing = false;
            player.told();
        }
        function onChanged(name, value) {
            if (name === "time-pos") {
                if (value === undefined || value === null || player.seeking || Date.now() - player.shownAt < 250) return;
                player.position = value * 1000; player.shownAt = Date.now();
            } else if (name === "duration") { player.duration = value ? value * 1000 : 0; player.told() }
            else if (name === "pause") { player.paused = !!value; player.told() }
            else if (name === "paused-for-cache") { player.buffering = !!value; player.told() }
            else if (name === "eof-reached") { if (value && player.playing) { player.playing = false; player.told() } }
        }
    }
}
