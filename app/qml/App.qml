// The app window. State lives here and nowhere else:
//   layer        which screen has the remote: home | tabs | show | title | menu | streams | player
//   playMenu     the Play options are open over the page (a long OK on Play or an episode)
//   focusItem    the title the remote is on (from Home), changes instantly
//   displayItem  the one title the backdrop, info and the title pages render; it changes only through
//                commit(). Moving focus commits once it settles, so key presses stay light; opening
//                anything commits first, so nothing opens on a stale title.
// Screens and controls handle their own keys (Qt focus scopes); a key nobody handles reaches the root
// here, which handles Back and moving between the tab bar and Home.
import QtQuick 2.12
import Eos.Window 0.1
import Seimio.UI 1.0
import Seimio.Native 1.0
import Seimio.Data 1.0
import "Episodes.js" as Episodes

WebOSWindow {
    id: app
    appId: "com.seimio.tv"
    // native apps only get Back and the rest when the window asks for them
    keyMask: WebOSWindow.KeyMaskBack | WebOSWindow.KeyMaskInfo | WebOSWindow.KeyMaskOk | WebOSWindow.KeyMaskLeft | WebOSWindow.KeyMaskRight | WebOSWindow.KeyMaskUp | WebOSWindow.KeyMaskDown | WebOSWindow.KeyMaskDefault
    visible: true
    width: Theme.screenWidth; height: Theme.screenHeight
    color: watching ? "transparent" : "black"

    property string layer: "home"
    // today's date ("YYYY-MM-DD"), checked every minute so the calendar moves on at midnight; previews
    // set it to a fixed day
    property string today: Qt.formatDate(new Date(), "yyyy-MM-dd")
    Timer { interval: 60000; running: true; repeat: true; onTriggered: { var t = Qt.formatDate(new Date(), "yyyy-MM-dd"); if (t !== app.today) app.today = t } }
    readonly property bool onHome: layer === "home" || layer === "tabs" || layer === "menu"
    // the Anime tab has its own screen; Home's rows, selection and scroll belong to whichever is up
    readonly property bool animeTab: tabs.currentIndex === 1
    readonly property bool scrolled: animeTab ? anime.scrolled : home.scrolled
    readonly property var focusItem: animeTab ? anime.focusItem : home.focusItem
    property var displayItem: null
    function commit() { settle.stop(); if (displayItem !== focusItem) displayItem = focusItem }
    onFocusItemChanged: { if (!displayItem) commit(); else settle.restart(); probe.captures(); if (home.row === 1) probe.act(home.dayOpen ? "day move" : "calendar move") }
    Timer { id: settle; interval: 280; onTriggered: app.commit() }
    // opening or closing a calendar day changes the whole screen, so it commits at once
    Connections { target: home; onDayOpenChanged: { app.commit(); probe.act(home.dayOpen ? "day open" : "day close") } }
    // the show page for the selected Continue Watching or Anime title is built once Home has been still for a
    // moment (after the backdrop and info have changed), so opening it costs nothing. Not from the
    // calendar: resting on its days would build a page each time (~25 ms) for an open that's rarer there
    onDisplayItemChanged: prepareShow.restart()
    Timer {
        id: prepareShow; interval: 1200
        onTriggered: {
            if (!app.displayItem || !app.onHome) return;
            // an Anime chart show is made playable ahead too (ARM, then Kitsu), so OK opens it at once
            if (app.animeTab && app.displayItem.id.indexOf("anilist:") === 0) { app.loadAnime(app.displayItem); return }
            // and its page is built
            if ((app.animeTab || home.row === 0) && app.episodeCount(app.displayItem.id) > 1) showPage.load(app.displayItem, app.showData(app.displayItem.id));
        }
    }

    function open() {
        commit();
        // the title page is for a movie, or a show whose whole run is one season with one episode; any
        // other show gets the show page, even when one of its seasons has a single episode
        // a calendar release opens on its own episode (`video`); anything else where you are in the show
        if (displayItem && app.episodeCount(displayItem.id) > 1) { showPage.open(displayItem, showData(displayItem.id), displayItem.video || ""); layer = "show" }
        else { titlePage.open(displayItem); layer = "title" }
    }
    // Playing. Play (and OK on an episode) plays the AI pick: the player opens at once and says what it's
    // doing while `streams` fetches, asks the decision model and resolves the link; if the pick fails, the
    // stream list opens on what was fetched. A long OK offers both ways (Play AI Pick, Play from Stream).
    // `episode` is { id, label, progress } from a show's page; without one it's the movie, or the show's
    // next episode.
    property var playTarget: null
    property string pageLayer: "title"          // where the stream list goes back to
    property string playerBack: "title"         // where the player goes back to
    function target(episode) {
        if (episode) return { type: "series", id: episode.id, label: episode.label, progress: episode.progress };
        var t = showPage.resumeTarget(showData(displayItem.id));
        return t ? { type: "series", id: t.id, label: app.episodeCount(displayItem.id) > 1 ? t.label : "", progress: t.progress }
                 : { type: "movie", id: displayItem.id, label: "", progress: displayItem.progress || 0 };
    }
    function playAi(episode) {
        commit(); playMenu = false;
        playTarget = target(episode);
        if (layer !== "player") playerBack = layer === "menu" ? "home" : layer;     // an episode from the player goes back where it came from
        // the episode row under the player shows the show page's season: load the show if it isn't there
        if (playTarget.type === "series" && showPage.item !== displayItem && app.episodeCount(displayItem.id) > 1) showPage.load(displayItem, showData(displayItem.id));
        // switching episodes inside the player keeps the release: Stremio's binge group (see Streams.play)
        var binge = layer === "player" && player.stream ? player.stream.bingeGroup || "" : "";
        player.prepare(displayItem, playTarget.label); layer = "player";
        streams.play(playTarget.type, playTarget.id, displayItem.name + (playTarget.label ? " " + playTarget.label : ""), binge);
    }
    // an episode's thumbnail from the show page's season, or the title's backdrop
    function episodeArt(id) {
        var eps = showPage.item === displayItem ? showPage.episodes : [];
        for (var i = 0; i < eps.length; i++) if (eps[i].id === id && eps[i].thumb) return eps[i].thumb;
        return displayItem ? displayItem.backdrop : "";
    }
    function openStreams(episode) {
        commit(); playMenu = false;
        // the fetch starts before the page is up, so its list waits for the new streams instead of
        // building the last ones first
        playTarget = target(episode); pageLayer = layer === "menu" ? "home" : layer;
        streamPage.open(displayItem, playTarget); layer = "streams";
    }
    Connections {
        target: streams
        onPlayable: {
            if (app.layer === "streams") { app.playerBack = "streams"; player.prepare(app.displayItem, streamPage.label); app.layer = "player" }
            if (app.layer !== "player") return;
            // resume where it was left, unless it was nearly done
            // a stream switch keeps the time exactly (`resumeMs`: files of one episode differ in length)
            var t = app.playTarget, p = t ? t.progress || 0 : 0;
            player.start(url, stream, t && t.resumeMs !== undefined ? { ms: t.resumeMs } : p > 0 && p < 95 ? p / 100 : 0);
        }
        onFailed: {
            if (app.layer !== "player") return;
            app.pageLayer = app.playerBack; app.layer = "streams";
            // with nothing listed the list says why itself
            streamPage.show(app.displayItem, app.playTarget.label, streams.total ? reason + ". Choose a stream to play." : "");
        }
    }
    // the Play options (a long OK on Play or an episode), over the page that has them
    property bool playMenu: false
    property var menuEpisode: null
    property rect menuAnchor: Qt.rect(0, 0, 0, 0)
    function openPlayMenu(episode, r) { commit(); menuEpisode = episode; menuAnchor = r; playMenu = true }
    // a handoff (a switch inside the player) is still watching: the scene behind stays away, or the
    // title's backdrop showed through as the still dissolved into the new video
    readonly property bool watching: layer === "player" && (player.playing || !!player.handoff)
    // lab: { "playList": [{ "title", "url" }], "playSeconds": 20 } plays each in turn from 8 s after launch
    // and logs how each went (playLog, in the lab reports)
    property var playLog: []
    property int playIndex: -1
    Timer {
        running: !!probe.variant.playList; repeat: true
        interval: app.playIndex < 0 ? 8000 : (probe.variant.playSeconds || 20) * 1000
        onTriggered: {
            var list = probe.variant.playList;
            if (app.playIndex >= 0) {
                var s = player.seen, log = app.playLog;
                log.push({ title: list[app.playIndex].title, playing: player.playing, position: player.position, duration: player.duration,
                           failure: player.failure, video: (s.videoInfo || "").slice(0, 220), audio: (s.audioInfo || "").slice(0, 160),
                           error: (s.error || "").slice(0, 200) });
                app.playLog = log; player.stop();
            }
            if (++app.playIndex >= list.length) { stop(); app.layer = "home"; return }
            player.prepare({ name: list[app.playIndex].title }, ""); player.start(list[app.playIndex].url, null, 0); app.layer = "player";
        }
    }
    function openMenu() { commit(); playMenu = false; layer = "menu"; probe.captures() }
    onLayerChanged: { probe.act(layer); probe.captures() }

    // effects that are needed later are drawn invisibly for a moment at startup, so their shaders
    // compile before anyone opens them
    property bool warming: true
    Timer { running: catalog.continueWatching.length > 0; interval: 600; onTriggered: app.warming = false }

    // the data, held natively (Seimio.Data); a show's seasons come over to QML once and are kept, so the
    // show page sees the same object again and needn't rebuild
    Catalog { id: catalog; base: Qt.resolvedUrl("../art/"); onLoaded: app.shows = ({}) }
    property var shows: ({})
    function showData(id) { if (!shows[id]) shows[id] = catalog.show(id); return shows[id] }
    // episodes in a show: the library's, or one loaded since (the Anime tab's)
    function episodeCount(id) {
        var sh = showData(id), n = 0;
        for (var s = 0; sh && sh.seasons && s < sh.seasons.length; s++) n += sh.seasons[s].episodes.length;
        return n;
    }
    // an Anime chart show: made playable once (fetched ahead while the selection rests on it, or on OK),
    // and opened when it's ready if OK asked for it (`animeOpening`)
    property string animeOpening: ""
    property var animeLoading: ({})
    function loadAnime(item) {
        if (anime.resolved[item.id] || animeLoading[item.id]) return;
        animeLoading[item.id] = true;
        catalog.loadAnime(item);
    }
    function openAnime(item) {
        if (anime.resolved[item.id]) { open(); return }
        animeOpening = item.id; loadAnime(item);
    }
    Connections {
        target: catalog
        onAnimeReady: {
            delete app.animeLoading[sourceId];
            if (!anime.resolved[sourceId]) { app.shows[item.id] = show; anime.resolve(sourceId, item) }
            // it opens only if OK's show is still the one selected on the Anime tab
            if (sourceId !== app.animeOpening) return;
            app.animeOpening = "";
            if (app.layer === "home" && app.animeTab && anime.focusItem === anime.resolved[sourceId]) app.open();
        }
        onAnimeFailed: {
            delete app.animeLoading[sourceId];
            if (sourceId === app.animeOpening) { app.animeOpening = ""; anime.say(reason) }
        }
    }
    WindowTools { id: tools }
    // keys out of git: app/qml/Secrets.qml (gitignored)
    Loader { id: secrets; source: "Secrets.qml" }
    Tracks { id: trackChoice }
    Streams {
        id: streams
        addon: "https://torrentio.strem.fun/torbox=" + (secrets.item ? secrets.item.torbox : "") + "/"
        torbox: secrets.item ? secrets.item.torbox : ""
        // the lab's tours run without the AI pick (LabProbe "noAi")
        openrouter: probe.variant.noAi || !secrets.item ? "" : secrets.item.openrouter
    }
    LabProbe {
        id: probe; window: app
        stateOf: function () {
            function id(x) { return x ? x.id || x.name || "?" : null }
            return { layer: app.layer, row: home.row, dayOpen: home.dayOpen, scrolled: home.scrolled,
                     focusItem: id(app.focusItem), displayItem: id(app.displayItem),
                     info: { item: id(info.item), m: id(info.m), pending: id(info.pending), fadeIn: info.fadeIn, away: info.away,
                             visible: info.visible, opacity: info.opacity, y: info.y, busy: info.busy },
                     playLog: app.playLog, subs: player.active ? player.subtitleInfo() : "",
                     playMenu: app.playMenu, stage: streams.stage, picks: streams.picksStatus,
                     player: { playing: player.playing, paused: player.paused, failure: player.failure, position: player.position, duration: player.duration, seen: player.seen } };
        }
        onAutopop: if (app.layer === "menu") app.layer = "home"; else app.openMenu()
        onOpenMenu: app.openMenu()
        onOpenStreams: app.openStreams(null)
        onVariantChanged: {
            if (variant.clearTrackChoices) trackChoice.clearPreferences(typeof variant.clearTrackChoices === "string" ? variant.clearTrackChoices : "");
            // lab: { "playId": { "type": "series", "id": "tt…:2:3" } } plays that video's ranked pick
            if (variant.playId) { app.playTarget = variant.playId; player.prepare({ name: variant.playId.id }, ""); app.layer = "player"; streams.play(variant.playId.type, variant.playId.id, variant.playId.id) }
        }
    }

    FocusScope {
        id: root
        anchors.fill: parent
        focus: true

        // ---- the scene: everything glass and frost can blur ----
        Item {
            id: scene
            anchors.fill: parent
            opacity: app.watching ? 0 : 1
            // gone, not just transparent, under the video: its backdrop's slow zoom and the calendar's light
            // stop, so nothing redraws over the film
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 500 } }

            Backdrop {
                id: hero
                width: parent.width; height: parent.height
                target: app.displayItem ? app.displayItem.backdrop : ""
                // parallax: the backdrop drifts a little against moves along a row
                pan: app.onHome && (home.row === 0 || home.dayOpen) ? Math.min(8, home.row === 0 ? home.column : home.dayColumn) * 5 : 0
                Behavior on pan { NumberAnimation { id: panning; duration: 700; easing.type: Theme.ease } }
                onCrossfadeStarted: probe.act("hero crossfade")
            }
            // the backdrop frosts on Home below the first row, where the info has stepped aside and the art
            // is only a background
            Frost {
                id: backdropFrost
                anchors.fill: parent
                source: hero
                frozen: true; sourceBusy: hero.busy || panning.running; sourceMoving: hero.fading
                opacity: (app.onHome && app.scrolled && !home.dayOpen) || app.layer === "streams" || app.layer === "player" ? 1 : (app.warming ? 0.003 : 0)
                Behavior on opacity { NumberAnimation { duration: 520; easing.type: Easing.InOutQuad } }
            }
            Scrim {
                anchors.fill: parent
                readonly property bool page: app.layer === "show" || app.layer === "title" || app.layer === "streams" || home.dayOpen
                side: page ? 0.95 : 0.85
                sideMid: page ? 0.35 : 0.15
                footMid: page ? 0.7 : 0.55
            }
            HeroInfo {
                id: info
                x: Theme.margin
                // hidden on the calendar, so it doesn't swap to every day there (logo loads, text layout)
                item: app.scrolled && app.onHome && !home.dayOpen ? null : app.displayItem
                // on the title page it moves down to sit just above the actions
                y: app.layer === "title" ? titlePage.actionsY - 40 - contentHeight : home.dayOpen ? 260 : (app.scrolled ? 90 : 150)
                // it only glides while on screen; hidden, it takes its new place at once and fades in there
                Behavior on y { enabled: info.visible; NumberAnimation { duration: 460; easing.type: Theme.ease } }
                // below Home's first row, and on the show page, the info steps aside
                property real away: (app.scrolled && app.onHome && !home.dayOpen) || app.layer === "show" || app.layer === "streams" || app.layer === "player" ? 1 : 0
                Behavior on away { NumberAnimation { duration: 380; easing.type: Theme.ease } }
                opacity: 1 - away
                visible: away < 1
            }
            ShowScreen {
                id: showPage
                today: app.today
                focus: app.layer === "show" && !app.playMenu
                onPlay: app.playAi(episode)
                onPlayHeld: app.openPlayMenu(episode, rect)
                active: app.layer === "show"
                source: hero
                onZoneChanged: probe.act("show " + ["actions", "seasons", "episodes"][zone])
            }
            TitleScreen {
                id: titlePage
                focus: app.layer === "title" && !app.playMenu
                onPlay: app.playAi(null)
                onPlayHeld: app.openPlayMenu(null, rect)
                active: app.layer === "title"
            }
            HomeScreen {
                id: home
                width: parent.width; height: parent.height
                focus: app.layer === "home" && !app.animeTab
                shown: app.onHome && !app.animeTab
                holdFocus: app.layer === "menu"
                continueWatching: catalog.continueWatching
                catalog: catalog
                glassSource: backdropFrost
                today: app.today
                onActivated: app.open()
                onHeld: app.openMenu()
                onExitTop: app.layer = "tabs"
                onColumnChanged: probe.act("row move")
                onRowChanged: probe.act("row change")
            }
            AnimeScreen {
                id: anime
                width: parent.width; height: parent.height
                focus: app.layer === "home" && app.animeTab
                shown: app.onHome && app.animeTab
                catalog: catalog
                glassSource: backdropFrost
                shownItem: app.displayItem
                onExitTop: app.layer = "tabs"
                onRowChanged: probe.act("anime row")
                // a show from the chart opens once it's made playable (Catalog.loadAnime)
                onActivated: if (item.id.indexOf("anilist:") === 0) app.openAnime(item); else app.open()
            }
        }

        // quick actions frost and dim everything except the focused card; the scene is captured once
        // when the menu opens, and again only while the backdrop or info is still changing
        Frost {
            anchors.fill: parent
            source: scene
            darken: 0.55
            frozen: true; sourceBusy: hero.busy || info.busy
            // around the held card, or the held Play button or episode
            hole: app.playMenu ? Qt.rect(app.menuAnchor.x - 14, app.menuAnchor.y - 14, app.menuAnchor.width + 28, app.menuAnchor.height + 28) : home.focusRect
            opacity: app.layer === "menu" || app.playMenu ? 1 : (app.warming ? 0.003 : 0)
            Behavior on opacity { NumberAnimation { duration: 320; easing.type: Easing.InOutQuad } }
        }
        SegmentedBar {
            id: tabs
            focus: app.layer === "tabs"
            source: scene
            model: ["Home", "Anime", "Movies", "Series", "Library", { icon: "search" }]
            // the tab bar belongs to the top of Home; pages and the calendar move it away
            readonly property bool shown: app.onHome && !app.scrolled
            shadow: shown ? 0.8 : 0
            x: (parent.width - width) / 2; y: shown ? 44 : -100
            opacity: app.layer === "menu" ? 0.3 : 1
            Behavior on y { NumberAnimation { duration: Theme.slow; easing.type: Theme.ease } }
            Behavior on opacity { NumberAnimation { duration: 300 } }
            onCurrentIndexChanged: probe.act("tabs")
        }
        StreamScreen {
            id: streamPage
            focus: app.layer === "streams"
            active: app.layer === "streams"
            source: backdropFrost
            streams: streams
        }
        PlayerScreen {
            id: player
            window: app
            streams: streams
            tracks: trackChoice
            useTee: !probe.variant.noTee
            subtitlesShown: !probe.variant.noSubs
            // the season's episodes, when the show page holds this show
            readonly property bool sameShow: showPage.item === app.displayItem && !!app.playTarget && app.playTarget.type === "series"
            episodes: sameShow ? showPage.episodes : []
            episodeCards: sameShow ? showPage.episodeData : []
            episodeId: app.playTarget ? app.playTarget.id : ""
            stillArt: app.playTarget ? app.episodeArt(app.playTarget.id) : ""
            videoId: app.playTarget ? app.playTarget.id : ""
            // inside the player, an episode change hands off: the picture fades into the episode's still
            // the episode after this one (Up next, and fetched ahead), into the next season
            nextEpisode: sameShow ? Episodes.after(showPage.show, app.playTarget.id, app.today) : null
            onPlayEpisode: {
                player.beginHandoff(episode.thumb, "E" + episode.episode, episode.title || "");
                // the row below the player follows into another season
                var at = Episodes.find(showPage.show, episode.id);
                if (at) showPage.place(at);
                app.playAi(showPage.target(showPage.show, at ? at.s : showPage.shownSeason, episode));
            }
            // once an episode plays, the next one's streams are fetched ahead (as stremio-core does)
            onPlayingChanged: if (playing && nextEpisode) streams.prefetch("series", nextEpisode.id)
            onZoneChanged: probe.captures()            // lab: screen captures follow the overlay too
            onMenuLevelChanged: probe.captures()
            onFavoriteMenuChanged: probe.captures()
            onUpNextModeChanged: probe.captures()
            // another stream of the same video, from where it is now
            onSwitchStream: { app.playTarget.resumeMs = player.position; streams.playRow(row) }
            // anime by its Kitsu id; everything else keeps its own track choices
            group: streams.anime ? "anime" : "other"
            focus: app.layer === "player"
            active: app.layer === "player"
        }
        QuickMenu {
            id: menu
            focus: app.layer === "menu"
            open: app.layer === "menu"
            source: scene
            x: Theme.margin + home.focusCardWidth * 1.1 + 44
            y: home.focusRect.y + 10
            // Play plays the AI pick; the library and watched actions aren't wired yet
            onTriggered: if (actionIndex === 0) app.playAi(null); else app.layer = "home"
        }
        QuickMenu {
            id: playOptions
            focus: app.playMenu
            open: app.playMenu
            source: scene
            actions: [{ label: "Play AI Pick", icon: "play" }, { label: "Play from Stream", icon: "list" }]
            x: app.menuAnchor.x + app.menuAnchor.width + 44
            y: Math.min(app.menuAnchor.y, Theme.screenHeight - height - 60)
            onTriggered: if (actionIndex === 0) app.playAi(app.menuEpisode); else app.openStreams(app.menuEpisode)
        }

        Keys.onPressed: {
            if (Remote.isBack(event.key) && app.playMenu) { event.accepted = true; app.playMenu = false }
            else if (Remote.isBack(event.key) && app.layer === "player") {
                event.accepted = true; streams.cancel(); player.stop();
                // the show page comes back on the episode last played (it may have changed in the player)
                if (app.playerBack === "show" && app.playTarget && app.playTarget.type === "series") showPage.rest(app.playTarget.id);
                app.layer = app.playerBack;
            }
            else if (Remote.isBack(event.key) && app.layer === "streams") { event.accepted = true; streams.cancel(); app.layer = app.pageLayer }
            else if (Remote.isBack(event.key) && app.layer !== "home") { event.accepted = true; app.layer = "home" }
            else if (event.key === Qt.Key_Down && app.layer === "tabs") { event.accepted = true; app.layer = "home" }
        }
    }

    Component.onCompleted: {
        // Back reaches the app only with this window property; without it webOS opens the exit menu
        tools.setWindowProperty(app, "_WEBOS_ACCESS_POLICY_KEYS_BACK", "true");
        requestActivate();
    }
}
