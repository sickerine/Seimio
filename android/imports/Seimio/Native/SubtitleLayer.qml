// Android's SubtitleLayer: mpv draws the subtitles (libass, in its picture); this picks the track, delays it
// and lifts it clear of the transport, and lists the OpenSubtitles addon's subtitles (AddonList, the LG's
// listing) as tracks numbered from 1000, one of which mpv loads when it is chosen. `track` is mpv's id of a
// file's own subtitle track (the Tee numbers them so), an addon's number, or -1 for none.
import QtQuick
import Seimio.Android

Item {
    id: layer
    property QtObject source
    property int track: -1
    property real position: 0
    property bool playing: false
    property int delay: 0
    property real lift: 0                 // px of the 1080 canvas the subtitles rise by
    signal addonListed(var subtitles)

    AddonList { id: addon; onListed: function (subtitles) { layer.addonListed(subtitles) } }
    function fetchAddon(type, videoId) { addon.fetch(type, videoId) }
    function reset() { addon.stop(); track = -1; added = ({}) }
    function info() { return "mpv sid " + Mpv.get("sid") + " track " + track }

    property var added: ({})              // an addon's number: mpv's id for it, once loaded
    onTrackChanged: {
        if (track < 1000) { Mpv.set("sid", track >= 0 ? track : "no"); return }
        if (added[track] !== undefined) { Mpv.set("sid", added[track]); return }
        var url = addon.url(track);
        if (url) { waitingFor = track; Mpv.command(["sub-add", url, "select"]) }
    }
    // the addon's file is the next external track mpv lists
    property int waitingFor: -1
    Connections {
        target: Mpv
        function onChanged(name, value) {
            if (name !== "track-list" || layer.waitingFor < 0 || !value) return;
            for (var i = value.length - 1; i >= 0; i--)
                if (value[i].type === "sub" && value[i].external) { layer.added[layer.waitingFor] = value[i].id; layer.waitingFor = -1; return }
        }
    }
    onDelayChanged: Mpv.set("sub-delay", delay / 1000)
    onLiftChanged: Mpv.set("sub-pos", Math.round(100 - lift / 10.8))
}
