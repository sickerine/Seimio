// The player. prepare(item, label) shows the title over its art with what's happening under it: finding
// streams, asking the AI to pick, getting the link (all from `streams`), then starting playback, with the
// chosen stream's chips once there is one. start(url, stream, fraction) loads the link into LG's media
// server (NativePlayer picks the audio track and seeks to `fraction` of the way in); once the video plays
// the app clears its scene and window so the video, under the window, shows. OK pauses and resumes, Left
// and Right seek 10 s, Back stops (App).
import QtQuick 2.12
import Seimio.UI 1.0
import Seimio.Native 1.0

FocusScope {
    id: page
    property bool active: false
    property var window
    property var streams                 // Seimio.Data Streams, for what the AI pick is doing
    property var tracks                  // Seimio.Data Tracks: which audio and subtitles play, and the choices
    property string group: "other"       // whose track choices apply: "anime" or "other"
    property var trackList: []           // the file's audio and subtitle tracks, as Tracks takes them
    property var choice: ({})            // what Tracks chose for this file
    property var chapters: []            // { start, end, title } from the file
    property var item: null
    property string label: ""
    property var stream: null            // the stream being played, once chosen
    property string pendingUrl: ""
    readonly property bool playing: media.playing
    readonly property bool paused: media.paused
    readonly property real position: media.position
    readonly property real duration: media.duration
    readonly property string failure: media.failure
    readonly property var seen: media.seen
    function subtitleInfo() { return subs.info() + " choice " + JSON.stringify(choice) }
    width: Theme.screenWidth; height: Theme.screenHeight
    opacity: active ? 1 : 0
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: 220 } }

    // the chosen stream as chips: resolution, HDR, Blu-ray, audio, size
    readonly property var chips: {
        var s = stream, out = [];
        if (!s) return out;
        if (s.res) out.push({ text: s.res, kind: s.res === "4K" ? "rating" : "glass" });
        if (s.hdr) out.push({ text: s.hdr, kind: "tint", tint: s.hdr === "DV" ? "#8b5cf6" : "#e8590c" });
        if (s.bd) out.push({ text: "BD", kind: "tint", tint: "#0f766e" });
        for (var i = 0; s.audio && i < s.audio.length; i++) out.push({ text: s.audio[i] });
        if (s.size) out.push({ text: s.size });
        return out;
    }
    function prepare(title, episodeLabel) { item = title; label = episodeLabel; stream = null; pendingUrl = ""; media.unload(); subs.reset(); trackList = []; choice = ({}); chapters = [] }
    // the file, as subtitle delays are kept: the stream's own link, which names the torrent and the file
    readonly property string fileKey: stream && stream.url ? stream.url : ""
    function start(url, s, fraction) {
        stream = s; pendingUrl = url; media.startFraction = fraction || 0;
        if (media.windowId) load(); else { media.setEventSlot(48); media.exportWindow(window) }
    }
    function load() {
        if (!pendingUrl) return;
        subs.reset(); trackList = []; choice = ({}); chapters = [];
        media.load(tee.open(pendingUrl), JSON.stringify({ option: { appId: "com.seimio.tv", windowId: media.windowId } }));
        subs.delay = fileKey ? tracks.delay(fileKey) : 0;
        pendingUrl = "";
    }
    function stop() { media.unload(); stream = null; pendingUrl = "" }

    NativePlayer {
        id: media
        onWindowIdChanged: page.load()
        // a file that isn't Matroska: LG's own list of audio tracks is all there is
        onAudioTracksChanged: if (!page.trackList.length && audioTracks.length && page.fileIsOther) page.chooseTracks(page.lgTracks())
        onLoadedChanged: if (loaded && page.choice.audioOff) media.mute(true)
    }
    // the file's tracks, chapters and subtitles, read from the bytes the player loads (Seimio.Native Tee)
    property bool fileIsOther: false
    Tee {
        id: tee
        onTracksRead: {
            page.fileIsOther = !matroska;
            if (matroska) page.chooseTracks(page.fileTracks(tracks)); else if (media.audioTracks.length) page.chooseTracks(page.lgTracks());
        }
        onChapter: { var c = page.chapters.slice(); c.push({ start: startMs, end: endMs, title: title }); page.chapters = c }
    }
    // what LG's player decodes: Dolby Digital (Plus), AAC, MP3, FLAC, PCM, Vorbis; not DTS, TrueHD or Opus
    function audioPlays(codec) { return !/dts|truehd|mlp|opus/i.test(codec) }
    function fileTracks(list) {
        var out = [], audio = 0;
        for (var i = 0; i < list.length; i++) {
            var t = list[i];
            if (t.type === 2) out.push({ id: audio++, type: "audio", lang: t.lang, title: t.title, codec: t.codec, default: t.default, forced: t.forced, playable: audioPlays(t.codec) });
            else if (t.type === 17) out.push({ id: t.number, type: "sub", lang: t.lang, title: t.title, codec: t.codec, default: t.default, forced: t.forced,
                                                 playable: /^S_TEXT\/(ASS|SSA|UTF8)/.test(t.codec) });
        }
        return out;
    }
    function lgTracks() {
        var out = [];
        for (var i = 0; i < media.audioTracks.length; i++) out.push({ id: i, type: "audio", lang: media.audioTracks[i].lang, title: "", codec: media.audioTracks[i].codec, playable: audioPlays(media.audioTracks[i].codec) });
        return out;
    }
    function chooseTracks(list) {
        trackList = list; choice = tracks.choose(list, group);
        if (choice.audio >= 0) { if (media.loaded) media.selectAudio(choice.audio); else media.preferredAudio = choice.audio }
        if (media.loaded) media.mute(!!choice.audioOff);
        subs.track = choice.sub;
    }
    SubtitleLayer {
        id: subs
        anchors.fill: parent
        source: tee
        position: media.position
        playing: media.playing && !media.paused
    }

    Keys.onPressed: {
        if (!media.loaded) return;
        if (Remote.isOk(event.key)) { if (media.paused) media.play(); else media.pause(); poke() }
        else if (event.key === Qt.Key_Left) { media.seek(Math.max(0, media.position - 10000)); poke() }
        else if (event.key === Qt.Key_Right) { media.seek(media.position + 10000); poke() }
        else return;
        event.accepted = true;
    }
    function poke() { controls.shown = true; hide.restart() }
    Timer { id: hide; interval: 3000; onTriggered: if (!media.paused) controls.shown = false }

    // what's happening, while the video isn't up yet
    readonly property string status: media.failure ? "Couldn't play this stream: " + media.failure
        : streams.stage === "fetching" ? "Finding streams"
        : streams.stage === "choosing" ? "Asking the AI to pick"
        : streams.stage === "resolving" ? "Getting the link"
        : media.buffering ? "Buffering"
        : "Starting playback"

    // loading: the title over its art, until the first frame
    Column {
        anchors.centerIn: parent; spacing: 30
        opacity: !media.playing ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 400 } }
        TitleArt {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 640; height: 200; centered: true
            logo: page.item && page.item.logo ? page.item.logo : ""; name: page.item ? page.item.name : ""
        }
        // a light that runs along a hairline while it loads
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 360; height: 4; radius: 2; color: "#26ffffff"; clip: true
            opacity: media.failure ? 0 : 1
            Rectangle {
                width: 120; height: 4; radius: 2
                gradient: Gradient { orientation: Gradient.Horizontal
                    GradientStop { position: 0; color: "#00ffffff" } GradientStop { position: 0.5; color: "white" } GradientStop { position: 1; color: "#00ffffff" } }
                NumberAnimation on x { from: -120; to: 360; duration: 1100; loops: Animation.Infinite; running: page.active && !media.playing && !media.failure; easing.type: Easing.InOutSine }
            }
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: page.status; color: Theme.inkSoft
            font.family: Theme.face; font.pixelSize: 28; font.weight: Font.Medium
        }
        // the stream that's starting, its chips arriving one after another (the row keeps its height,
        // so nothing above moves when they do)
        Item {
            anchors.horizontalCenter: parent.horizontalCenter
            width: chips.width; height: 38
            Row {
                id: chips
                spacing: 8
                Repeater {
                    model: page.chips
                    Reveal {
                        delay: 120 + index * 70; dy: 10
                        Chip { size: 20; kind: modelData.kind || "glass"; tint: modelData.tint || Theme.fill; text: modelData.text }
                    }
                }
            }
        }
    }

    // transport: shown for a moment after a key, and while paused
    Item {
        id: controls
        property bool shown: false
        anchors.fill: parent
        opacity: media.playing && (shown || media.paused) ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.base } }
        Rectangle {
            anchors.fill: parent
            gradient: Gradient { GradientStop { position: 0.55; color: "#00000000" } GradientStop { position: 1; color: "#b3000000" } }
        }
        TitleArt {
            x: Theme.margin; y: 760; width: 420; height: 120
            logo: page.item && page.item.logo ? page.item.logo : ""; name: page.item ? page.item.name : ""; nameSize: 48
        }
        Rectangle {
            id: track
            x: Theme.margin; y: 940; width: parent.width - 2 * Theme.margin; height: 8; radius: 4; color: "#40ffffff"
            Rectangle { width: media.duration ? track.width * Math.min(1, media.position / media.duration) : 0; height: 8; radius: 4; color: "white" }
        }
        function clock(ms) {
            var s = Math.floor(ms / 1000), h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60; s = s % 60;
            return (h ? h + ":" + (m < 10 ? "0" : "") : "") + m + ":" + (s < 10 ? "0" : "") + s;
        }
        Text { x: Theme.margin; y: 966; text: controls.clock(media.position); color: Theme.inkSoft; font.family: Theme.face; font.pixelSize: 24; font.weight: Font.Medium }
        Text { anchors.right: track.right; y: 966; text: "-" + controls.clock(Math.max(0, media.duration - media.position)); color: Theme.inkSoft; font.family: Theme.face; font.pixelSize: 24; font.weight: Font.Medium }
    }
}
