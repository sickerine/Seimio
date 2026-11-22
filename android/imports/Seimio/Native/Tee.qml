// Android's Tee: on the LG the Tee reads the file's tracks and chapters from the bytes passing to LG's player;
// here mpv reads the file and says them, and the Tee hands them on in the LG's terms, so PlayerScreen and
// Tracks read them as they do there: Matroska's track types (1 video, 2 audio, 17 subtitles) and codec ids.
// A subtitle's number is mpv's id for it (SubtitleLayer's `track`).
import QtQuick
import Seimio.Android

QtObject {
    id: tee
    property int port: 0
    signal tracksRead(var tracks, bool matroska)
    signal chapter(double startMs, double endMs, string title)
    function open(url) { return url }
    // the lab's line: how mpv decodes and keeps up
    function stats() {
        return ["hwdec-current", "video-codec", "width", "height", "container-fps", "estimated-vf-fps", "frame-drop-count", "decoder-frame-drop-count", "avsync", "audio-codec-name", "cache-buffering-state"]
            .map(function (p) { return p + "=" + Mpv.get(p) }).join(" ")
    }

    // mpv's codec names as Matroska's ids, for the rules that read them (Tracks: text before image subtitles).
    // WebVTT is text that mpv draws, as SRT is.
    readonly property var subtitleCodecs: ({ ass: "S_TEXT/ASS", ssa: "S_TEXT/SSA", subrip: "S_TEXT/UTF8", webvtt: "S_TEXT/UTF8", text: "S_TEXT/UTF8",
                                             hdmv_pgs_subtitle: "S_HDMV/PGS", dvd_subtitle: "S_VOBSUB", mov_text: "tx3g" })
    function codecOf(t) { return t.type === "sub" ? subtitleCodecs[t.codec] || "S_TEXT/UTF8" : (t.type === "audio" ? "A_" : "V_") + String(t.codec || "").toUpperCase() }

    property Connections mpv: Connections {
        target: Mpv
        function onFileLoaded() {
            var list = Mpv.get("track-list") || [], out = [];
            for (var i = 0; i < list.length; i++) {
                var t = list[i];
                if (t.external) continue;
                out.push({ number: t.id, type: t.type === "video" ? 1 : t.type === "audio" ? 2 : 17, codec: tee.codecOf(t), lang: t.lang || "",
                           title: t.title || "", default: !!t["default"], forced: !!t.forced, channels: t["demux-channel-count"] || 0 });
            }
            tee.tracksRead(out, true);
            var chapters = Mpv.get("chapter-list") || [];
            for (var c = 0; c < chapters.length; c++) tee.chapter(chapters[c].time * 1000, -1, chapters[c].title || "");
        }
    }
}
