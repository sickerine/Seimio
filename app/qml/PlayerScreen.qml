// The player. prepare(item, label) shows the title over its art with what's happening under it: finding
// streams, asking the AI to pick, getting the link (all from `streams`), then starting playback, with the
// chosen stream's chips once there is one. start(url, stream, fraction) loads the link through the Tee
// into LG's media server, which seeks to `fraction` of the way in; once the video plays the app clears
// its scene and window so the video, under the window, shows. Tracks chooses the audio and subtitles
// (the user's choices per group), SubtitleLayer draws the subtitles. The overlay (`zone`) has the
// transport with seeking, Audio, Subtitles and Streams, the episode row, and Skip Intro/Credits. Back
// closes what's open, then stops (App).
import QtQuick 2.12
import Seimio.UI 1.0
import Seimio.Native 1.0
import Seimio.Data 1.0

FocusScope {
    id: page
    property bool active: false
    property var window
    property var streams                 // Seimio.Data Streams, for what the AI pick is doing
    property var tracks                  // Seimio.Data Tracks: which audio and subtitles play, and the choices
    property string group: "other"       // whose track choices apply: "anime" or "other"
    property var trackList: []           // the file's audio and subtitle tracks, as Tracks takes them
    property var addonSubs: []           // subtitles from the OpenSubtitles addon, after the file's own
    property bool pickedSub: false       // a subtitle was picked in the menu for this file
    // lab: ms from load to the first frame
    property double loadedAt: 0
    property int startMs: -1
    Connections { target: media; onStateChanged: if (media.playing && page.startMs < 0 && page.loadedAt) page.startMs = Date.now() - page.loadedAt }
    property var choice: ({})            // what Tracks chose for this file
    property var chapters: []            // { start, end, title } from the file
    property bool useTee: true           // the lab turns these off to compare
    property bool subtitlesShown: true
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
    function subtitleInfo() { return subs.info() + " addon " + addonSubs.length + " delay " + subs.delay + " tee " + tee.stats() + " audioTrack " + media.audioTrack + " prefs " + JSON.stringify(tracks.preferences(group)) + " zone " + zone + " segs " + JSON.stringify(segments)
        + " start " + startMs + " list " + trackList.filter(function (t) { return t.type === "sub" }).map(function (t) { return t.id + ":" + t.lang + (t.default ? "d" : "") + (t.forced ? "f" : "") }).join(",") + " choice " + JSON.stringify(choice) }
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
    function prepare(title, episodeLabel) { item = title; label = episodeLabel; stream = null; pendingUrl = ""; media.unload(); subs.reset(); trackList = []; choice = ({}); chapters = []; skipLookup.cancel(); askSkip.stop(); skipTimes = ({}) }
    // the file, as subtitle delays are kept: the stream's own link, which names the torrent and the file
    readonly property string fileKey: stream && stream.url ? stream.url : ""
    // `at`: where to start, a fraction of the way (a resume) or { ms } (a stream switch keeps the time)
    function start(url, s, at) {
        stream = s; pendingUrl = url;
        media.startAt = at && at.ms !== undefined ? at.ms : -1; media.startFraction = typeof at === "number" ? at : 0;
        if (media.windowId) load(); else { media.setEventSlot(48); media.exportWindow(window) }
    }
    function load() {
        if (!pendingUrl) return;
        loadedAt = Date.now(); startMs = -1;
        subs.reset(); trackList = []; addonSubs = []; otherSubs = []; fileIsOther = false; pickedSub = false; choice = ({}); chapters = []; pendingChapters = []; skipTimes = ({});
        skipLookup.cancel(); askSkip.stop();
        if (/^tt\d+/.test(videoId)) subs.fetchAddon(videoId.indexOf(":") > 0 ? "series" : "movie", videoId);
        media.load(useTee ? tee.open(pendingUrl) : pendingUrl, JSON.stringify({ option: { appId: "com.seimio.tv", windowId: media.windowId } }));
        subs.delay = fileKey ? tracks.delay(fileKey) : 0;
        pendingUrl = "";
    }
    function stop() { media.unload(); stream = null; pendingUrl = ""; skipLookup.cancel(); askSkip.stop() }

    NativePlayer {
        id: media
        onWindowIdChanged: page.load()
        // a file that isn't Matroska: LG's own list of audio tracks is all there is
        onAudioTracksChanged: if (!page.trackList.length && audioTracks.length && page.fileIsOther) page.chooseTracks(page.lgTracks())
        onLoadedChanged: if (loaded && page.choice.audioOff) media.mute(true)
    }
    // the file's tracks, chapters and subtitles, read from the bytes the player loads (Seimio.Native Tee)
    property bool fileIsOther: false
    property var otherSubs: []           // an MP4's text subtitles; its audio comes from LG's player
    property var pendingChapters: []
    property bool sheetReady: false
    Timer { running: media.playing && !page.sheetReady; interval: 3000; onTriggered: page.sheetReady = true }
    // chapters after the skip lookup (a file that keeps them at its end) count too: it runs again
    Timer { id: chaptersIn; interval: 300; onTriggered: { page.chapters = page.chapters.concat(page.pendingChapters); page.pendingChapters = []; if (media.loaded) askSkip.restart() } }
    Tee {
        id: tee
        onTracksRead: {
            page.fileIsOther = !matroska;
            if (!matroska) page.otherSubs = page.fileTracks(tracks);
            if (matroska) page.chooseTracks(page.fileTracks(tracks)); else if (media.audioTracks.length) page.chooseTracks(page.lgTracks());
        }
        // chapters arrive one by one; they're applied together, so the bar and the skip spans build once
        onChapter: { page.pendingChapters.push({ start: startMs, end: endMs, title: title }); chaptersIn.restart() }
    }
    // what LG's player decodes: Dolby Digital (Plus), AAC, MP3, FLAC, PCM, Vorbis; not DTS, TrueHD or Opus
    function audioPlays(codec) { return !/dts|truehd|mlp|opus/i.test(codec) }
    function fileTracks(list) {
        var out = [], audio = 0;
        for (var i = 0; i < list.length; i++) {
            var t = list[i];
            if (t.type === 2) out.push({ id: audio++, type: "audio", lang: t.lang, title: t.title, codec: t.codec, default: t.default, forced: t.forced, playable: audioPlays(t.codec) });
            else if (t.type === 17) out.push({ id: t.number, type: "sub", lang: t.lang, title: t.title, codec: t.codec, default: t.default, forced: t.forced,
                                                 playable: /^(S_TEXT\/(ASS|SSA|UTF8)|S_HDMV\/PGS|S_VOBSUB|tx3g)/.test(t.codec) });
        }
        return out;
    }
    function lgTracks() {
        var out = otherSubs.slice();
        for (var i = 0; i < media.audioTracks.length; i++) out.push({ id: i, type: "audio", lang: media.audioTracks[i].lang, title: "", codec: media.audioTracks[i].codec, playable: audioPlays(media.audioTracks[i].codec) });
        return out;
    }
    function chooseTracks(list) {
        trackList = list.concat(addonSubs); choice = tracks.choose(trackList, group);
        if (choice.audio >= 0) { if (media.loaded) media.selectAudio(choice.audio); else media.preferredAudio = choice.audio }
        if (media.loaded) media.mute(!!choice.audioOff);
        subs.track = subtitlesShown ? choice.sub : -1;
    }

    // ---- the overlay -------------------------------------------------------------------------------------
    // `zone` is what shows and who has the remote: "none" (the video), "bar" (the transport: seeking),
    // "row" (Audio, Subtitles, Streams), "audio" or "subs" (a list), "streams" (the sheet), "episodes"
    // (the row below). Everything exists from the start and moves or fades in, so opening costs nothing.
    property string zone: "none"
    property var episodes: []            // the season's episodes and their cards, for the row below
    property var episodeCards: []
    property string episodeId: ""        // the one playing
    signal playEpisode(var episode)
    signal switchStream(int row)
    onZoneChanged: {
        hide.restart();
        if (zone === "audio" || zone === "subs") buildMenu();
        if (zone === "streams") { var r = stream ? streams.rowOf(stream.url) : -1; streamList.currentIndex = Math.max(0, r); streamList.positionViewAtIndex(Math.max(0, r), ListView.Center) }
    }
    onTrackListChanged: if (zone === "audio" || zone === "subs") buildMenu(true)
    onActiveChanged: if (!active) zone = "none"

    // seeking: each press moves a target at once and the seek happens when the presses stop (or on OK),
    // in steps that grow while a direction is held
    property real seekTarget: -1
    property int seekPresses: 0
    readonly property real shownPosition: seekTarget >= 0 ? seekTarget : media.position
    function nudge(dir) {
        if (seekTarget < 0) seekTarget = media.position;
        seekPresses++;
        var step = seekPresses < 5 ? 10000 : seekPresses < 12 ? 30000 : 60000;
        seekTarget = Math.max(0, Math.min(media.duration - 2000, seekTarget + dir * step));
        commitSeek.restart();
    }
    function seekNow() { commitSeek.stop(); if (seekTarget >= 0) media.seek(seekTarget); seekTarget = -1; seekPresses = 0 }
    Timer { id: commitSeek; interval: 650; onTriggered: page.seekNow() }
    function togglePause() { if (media.paused) media.play(); else media.pause() }

    // the transport hides on its own after a while, unless paused or seeking
    Timer { id: hide; interval: 4000; onTriggered: if (page.zone === "bar" && !media.paused && page.seekTarget < 0) page.zone = "none"; else if (page.zone === "bar") restart() }

    // intro and outro: the file's chapters, the IntroDB, TheIntroDB and AniSkip, reconciled (SkipTimes),
    // asked once the length is known and the chapters are in
    property string videoId: ""
    property var skipTimes: ({})
    SkipTimes { id: skipLookup; onResolved: page.skipTimes = segments }
    Timer {
        id: askSkip; interval: 2500
        onTriggered: if (media.duration > 0) skipLookup.resolve(page.videoId, media.duration, page.chapters)   // no id: chapters only
    }
    Connections { target: media; onLoadedChanged: if (media.loaded) askSkip.restart() }
    readonly property var segments: {
        var out = [];
        if (skipTimes.intro) out.push({ kind: "intro", start: skipTimes.intro.from, end: skipTimes.intro.to });
        if (skipTimes.outro) out.push({ kind: "outro", start: skipTimes.outro.from, end: skipTimes.outro.to });
        return out;
    }
    readonly property var segmentNow: {
        for (var i = 0; i < segments.length; i++) if (media.position >= segments[i].start && media.position < segments[i].end - 1500) return segments[i];
        return null;
    }
    function skip() { if (segmentNow) { media.seek(segmentNow.end); zone = "none" } }

    Keys.onPressed: {
        if (!media.loaded) return;
        var k = event.key, back = Remote.isBack(k), ok = Remote.isOk(k);
        if (back) {
            if (zone === "audio" || zone === "subs" || zone === "streams") zone = "row";
            else if (zone !== "none") { seekNow(); zone = "none" }
            else return;                                        // the app stops the player
        } else if (zone === "none") {
            if (ok && segmentNow) skip();
            else if (ok) { togglePause(); zone = "bar" }
            else if (k === Qt.Key_Left || k === Qt.Key_Right) { zone = "bar"; nudge(k === Qt.Key_Left ? -1 : 1) }
            else zone = "bar";
        } else if (zone === "bar") {
            if (ok) { if (seekTarget >= 0) seekNow(); else togglePause() }
            else if (k === Qt.Key_Left || k === Qt.Key_Right) nudge(k === Qt.Key_Left ? -1 : 1);
            else if (k === Qt.Key_Up) zone = "row";
            else if (k === Qt.Key_Down && episodes.length) zone = "episodes";
            else return;
        } else if (zone === "row") {
            if (k === Qt.Key_Down) zone = "bar"; else return;
        } else if (zone === "subs" && (k === Qt.Key_Left || k === Qt.Key_Right) && menu.currentIndex === menu.model.length - 1) {
            setDelay(subs.delay + (k === Qt.Key_Left ? -100 : 100));
        } else if (zone === "episodes") {
            if (k === Qt.Key_Up) zone = "bar"; else return;
        } else return;
        event.accepted = true;
        hide.restart();
    }

    // ---- audio and subtitles ----------------------------------------------------------------------------
    // A choice here is the default for the group (anime, other) from now on; Off too.
    function codecName(c) {
        var n = { "A_FLAC": "FLAC", "A_AC3": "Dolby Digital", "A_EAC3": "Dolby Digital Plus", "A_DTS": "DTS", "A_TRUEHD": "TrueHD", "A_OPUS": "Opus", "A_VORBIS": "Vorbis",
                  "S_TEXT/ASS": "ASS", "S_TEXT/SSA": "SSA", "S_TEXT/UTF8": "SRT", "S_HDMV/PGS": "PGS", "S_VOBSUB": "VobSub", "tx3g": "Text",
                  "ac3": "Dolby Digital", "eac3": "Dolby Digital Plus", "aac": "AAC", "flac": "FLAC", "mp3": "MP3", "dts": "DTS", "truehd": "TrueHD", "opus": "Opus" }[c];
        return n || (/^A_AAC/.test(c) ? "AAC" : /^A_PCM/.test(c) ? "PCM" : c || "");
    }
    property var menuTracks: []                                  // the tracks the open list shows, in order
    // `keep`: stay on the row (the delay changing), rather than go to the checked one
    function buildMenu(keep) {
        var type = zone === "audio" ? "audio" : "sub", rows = [], list = [];
        var current = type === "audio" ? (choice.audioOff ? -2 : media.audioTrack) : subs.track;
        for (var i = 0; i < trackList.length; i++) {
            var t = trackList[i];
            if (t.type !== type) continue;
            var name = tracks.languageName(tracks.languageOf(t.lang, t.title)), extra = [];
            if (t.title && t.title !== name) extra.push(t.title);
            extra.push(codecName(t.codec));
            if (t.forced) extra.push("Forced");
            if (!t.playable) extra.push("won't play");
            rows.push({ label: name || t.title || ("Track " + (rows.length + 1)), detail: extra.join("   "), checked: t.id === current });
            list.push(t);
        }
        rows.push({ label: "Off", checked: current === (type === "audio" ? -2 : -1) });
        list.push(null);
        if (type === "sub") { rows.push({ label: "Delay", value: (subs.delay > 0 ? "+" : "") + (subs.delay / 1000).toFixed(1) + " s" }); list.push("delay") }
        menuTracks = list; menu.model = rows;
        for (var r = 0; !keep && r < rows.length; r++) if (rows[r].checked) { menu.currentIndex = r; break }
        if (!keep) menu.follow(true);
    }
    function pickFromMenu(row) {
        var t = menuTracks[row];
        if (t === "delay") return;
        if (zone === "audio") {
            if (t && !t.playable) return;
            if (t) { media.selectAudio(t.id); media.mute(false) } else media.mute(true);
            tracks.prefer(group, "audio", t ? t.lang : "off", t ? t.title : "");
            choice = tracks.choose(trackList, group);
        } else {
            if (t && !t.playable) return;
            subs.track = t ? t.id : -1; pickedSub = true;
            tracks.prefer(group, "sub", t ? t.lang : "off", t ? t.title : "");
            choice = tracks.choose(trackList, group);
        }
        buildMenu();
    }
    function setDelay(ms) { subs.delay = ms; if (fileKey) tracks.setDelay(fileKey, ms); buildMenu(true) }

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

    // ---- what's on screen -------------------------------------------------------------------------------
    // shade under the transport and the row below
    Rectangle {
        anchors.fill: parent
        opacity: page.zone !== "none" && media.playing ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Theme.base } }
        gradient: Gradient { GradientStop { position: 0.45; color: "#00000000" } GradientStop { position: 1; color: "#d9000000" } }
    }
    SubtitleLayer {
        id: subs
        anchors.fill: parent
        source: tee
        // above the shade, rising clear of the transport while it's open, and of the row below
        lift: page.zone === "episodes" ? 470 : page.zone === "bar" || page.zone === "row" || page.zone === "audio" || page.zone === "subs" ? 200 : 0
        Behavior on lift { NumberAnimation { duration: Theme.slow; easing.type: Theme.ease } }
        position: media.position
        playing: media.playing && !media.paused && !media.buffering            // the clock stops while the video waits
        // no default flag: one plays only when its language is the one chosen, and the file's own wins a tie
        onAddonListed: {
            var out = [];
            for (var i = 0; i < subtitles.length; i++)
                out.push({ id: subtitles[i].number, type: "sub", lang: subtitles[i].lang, title: subtitles[i].title, codec: "OpenSubtitles", playable: true, external: true });
            page.addonSubs = out;
            if (!page.trackList.length) return;                  // the file's tracks aren't in yet; chooseTracks adds these
            page.trackList = page.trackList.concat(out); page.choice = tracks.choose(page.trackList, page.group);
            if (!page.pickedSub) subs.track = page.subtitlesShown ? page.choice.sub : -1;   // a pick in the menu stays
        }
    }
    function clock(ms) {
        var s = Math.floor(ms / 1000), h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60; s = s % 60;
        return (h ? h + ":" + (m < 10 ? "0" : "") : "") + m + ":" + (s < 10 ? "0" : "") + s;
    }
    Item {
        id: transport
        width: parent.width; height: parent.height
        // the whole transport rises out of the row below when it opens, and steps up when the row is open
        property real lift: page.zone === "episodes" ? -270 : 0
        opacity: media.playing && page.zone !== "none" && page.zone !== "streams" ? 1 : 0
        // hidden, its clock and bar stop asking for frames over the video
        visible: opacity > 0
        transform: Translate { y: transport.lift + (transport.opacity < 1 ? 24 * (1 - transport.opacity) : 0) }
        Behavior on opacity { NumberAnimation { duration: Theme.base; easing.type: Theme.ease } }
        Behavior on lift { NumberAnimation { duration: Theme.slow; easing.type: Theme.ease } }

        TitleArt {
            x: Theme.margin; y: 700; width: 420; height: 140
            logo: page.item && page.item.logo ? page.item.logo : ""; name: page.item ? page.item.name : ""; nameSize: 48
        }
        Chip { x: Theme.margin; y: 858; visible: page.label !== ""; kind: "solid"; icon: "play"; text: page.label }

        // Audio, Subtitles, Streams
        ButtonRow {
            id: buttons
            focus: page.zone === "row"
            anchors.right: parent.right; anchors.rightMargin: Theme.margin; y: 852
            model: [{ label: "Audio" }, { label: "Subtitles" }, { label: "Streams", icon: "list" }]
            onTriggered: page.zone = ["audio", "subs", "streams"][buttonIndex]
        }

        // the progress bar: chapters as gaps, intro and outro as brighter spans, the seek target as a head
        Item {
            id: bar
            x: Theme.margin; y: 950; width: parent.width - 2 * Theme.margin; height: 10
            readonly property bool focused: page.zone === "bar"
            Rectangle { anchors.fill: parent; radius: 5; color: "#40ffffff" }
            Repeater {
                model: page.segments
                Rectangle {
                    x: media.duration ? bar.width * modelData.start / media.duration : 0
                    width: media.duration ? bar.width * (modelData.end - modelData.start) / media.duration : 0
                    height: bar.height; radius: 5; color: "#26ffffff"
                }
            }
            Rectangle { width: media.duration ? bar.width * Math.min(1, media.position / media.duration) : 0; height: bar.height; radius: 5; color: "white" }
            Repeater {
                model: page.chapters
                Rectangle { x: media.duration ? bar.width * modelData.start / media.duration - 2 : 0; visible: modelData.start > 0; width: 4; height: bar.height; color: "#99000000" }
            }
            // the head and the time it points at
            Rectangle {
                id: head
                width: 24; height: 24; radius: 12; color: "white"
                anchors.verticalCenter: parent.verticalCenter
                x: (media.duration ? bar.width * Math.min(1, page.shownPosition / media.duration) : 0) - 12
                scale: bar.focused ? 1 : 0
                Behavior on scale { NumberAnimation { duration: Theme.fast; easing.type: Theme.spring } }
                Behavior on x { enabled: page.seekTarget >= 0; NumberAnimation { duration: 140; easing.type: Theme.ease } }
            }
            Chip {
                kind: "solid"; size: 22
                text: page.clock(page.shownPosition)
                x: Math.max(0, Math.min(bar.width - width, head.x + 12 - width / 2)); y: -58
                opacity: page.seekTarget >= 0 ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: Theme.fast } }
            }
        }
        Text { x: Theme.margin; y: 978; text: page.clock(page.shownPosition); color: Theme.inkSoft; font.family: Theme.face; font.pixelSize: 24; font.weight: Font.Medium }
        Text { anchors.right: parent.right; anchors.rightMargin: Theme.margin; y: 978; text: "-" + page.clock(Math.max(0, media.duration - page.shownPosition)); color: Theme.inkSoft; font.family: Theme.face; font.pixelSize: 24; font.weight: Font.Medium }
    }

    // the episode row: its top peeks out under the transport; Down brings it up
    Item {
        id: episodeRow
        width: parent.width; height: 300
        y: page.zone === "episodes" ? 790 : page.zone === "bar" || page.zone === "row" ? 1040 : 1120
        opacity: media.playing && page.episodes.length && page.zone !== "none" && page.zone !== "streams" ? 1 : 0
        visible: opacity > 0
        Behavior on y { NumberAnimation { duration: Theme.slow; easing.type: Theme.ease } }
        Behavior on opacity { NumberAnimation { duration: Theme.base } }
        Text { x: Theme.margin; y: 0; text: "Episodes"; color: Theme.inkSoft; font.family: Theme.face; font.pixelSize: 26; font.weight: Font.DemiBold }
        CardStrip {
            id: episodeStrip
            y: 46; width: parent.width
            focus: page.zone === "episodes"
            model: page.episodeCards
            cardWidth: 352; cardHeight: 198; spacing: 28
            showTitles: false; nextLabels: false
            onActivated: { page.zone = "none"; if (page.episodes[cardIndex] && page.episodes[cardIndex].id !== page.episodeId) page.playEpisode(page.episodes[cardIndex]) }
        }
        Connections { target: page; onZoneChanged: if (page.zone === "episodes") { for (var i = 0; i < page.episodes.length; i++) if (page.episodes[i].id === page.episodeId) { episodeStrip.jumpTo(i); break } } }
    }

    // Audio and Subtitles: a list above the buttons, at the right
    Rectangle {
        id: menuPanel
        readonly property bool open: page.zone === "audio" || page.zone === "subs"
        width: 760; height: menu.implicitHeight + 32; radius: 32
        anchors.right: parent.right; anchors.rightMargin: Theme.margin; y: 830 - height
        color: "#f0141418"; border.width: 1; border.color: "#26ffffff"
        opacity: open ? 1 : 0; scale: open ? 1 : 0.92; transformOrigin: Item.BottomRight
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: 200 } }
        Behavior on scale { NumberAnimation { duration: 340; easing.type: Theme.spring; easing.overshoot: 1.3 } }
        MenuList {
            id: menu
            x: 16; y: 16; width: parent.width - 32
            maxRows: 8                                          // a file's tracks and the addon's run long
            focus: menuPanel.open
            shown: menuPanel.open
            onTriggered: page.pickFromMenu(rowIndex)
        }
    }

    // Streams: a sheet from the right, on the streams of what's playing; OK switches and keeps the place
    Rectangle {
        id: sheet
        readonly property bool open: page.zone === "streams"
        width: 1020; height: parent.height
        x: open ? parent.width - width : parent.width
        visible: x < parent.width
        color: "#f2101014"
        Behavior on x { NumberAnimation { duration: Theme.slow; easing.type: Theme.ease } }
        Text { x: 56; y: 64; text: "Streams"; color: Theme.ink; font.family: Theme.face; font.pixelSize: 40; font.weight: Font.Bold }
        ListView {
            id: streamList
            x: 32; y: 170; width: parent.width - 64; height: parent.height - 200
            clip: true; spacing: 10
            focus: sheet.open
            // the rows are built a moment after playback starts, while nothing on screen moves, so neither
            // the start nor opening the sheet pays for them
            model: page.sheetReady ? page.streams : null
            highlightMoveDuration: 260
            highlight: Rectangle { radius: 24; color: "#3dffffff" }
            preferredHighlightBegin: 0; preferredHighlightEnd: 400; highlightRangeMode: ListView.ApplyRange
            // the sheet slides away as the new stream loads behind it; the one playing just closes it
            function choose() { page.zone = "none"; if (!(page.stream && page.streams.rowOf(page.stream.url) === currentIndex)) page.switchStream(currentIndex) }
            Keys.onReturnPressed: choose()
            Keys.onEnterPressed: choose()
            delegate: Item {
                id: streamRow
                readonly property var chips: model.chips || []
                width: streamList.width; height: 100
                Text {
                    x: 24; y: 20; width: 96
                    text: model.res || "SD"; color: model.res === "4K" ? Theme.rating : Theme.ink
                    font.family: Theme.face; font.pixelSize: model.res === "4K" ? 34 : 26; font.weight: Font.Bold
                }
                Text {
                    x: 130; y: 16; width: parent.width - 150; elide: Text.ElideRight
                    text: model.shortName; color: Theme.ink; textFormat: Text.PlainText
                    font.family: Theme.face; font.pixelSize: 24; font.weight: Font.DemiBold
                }
                Row {
                    x: 130; y: 56; spacing: 6
                    Chip { visible: !!(page.stream && page.stream.url === model.url); size: 16; kind: "solid"; icon: "play"; text: "Playing" }
                    Chip { visible: model.support === "unsupported"; size: 16; kind: "tint"; tint: "#b42318"; text: "No " + (model.why || "audio") }
                    Chip { visible: !!model.hdr; size: 16; kind: "tint"; tint: model.hdr === "DV" ? "#8b5cf6" : "#e8590c"; text: model.hdr || "" }
                    Repeater { model: streamRow.chips.slice(0, 5); Chip { size: 16; text: modelData.text; icon: modelData.icon; kind: modelData.tag ? "tint" : "glass"; tint: modelData.tag === "bd" ? "#0f766e" : "#7c3aed" } }
                }
            }
        }
    }

    // Skip Intro / Skip Credits, while one plays; OK presses it
    Chip {
        id: skipButton
        anchors.right: parent.right; anchors.rightMargin: Theme.margin; y: 780
        size: 28; kind: "solid"; icon: "play"
        text: page.segmentNow ? (page.segmentNow.kind === "intro" ? "Skip Intro" : "Skip Credits") : ""
        opacity: page.segmentNow && media.playing && (page.zone === "none" || page.zone === "bar") ? 1 : 0
        visible: opacity > 0
        transform: Translate { x: (1 - skipButton.opacity) * 40 }
        Behavior on opacity { NumberAnimation { duration: Theme.base; easing.type: Theme.ease } }
    }
}
