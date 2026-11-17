// A show's page: title, actions (resume with progress, library, watched), seasons and episodes, with
// details of the focused episode. load(item, show) builds the page for a title and its seasons and
// episodes with watch state, at its resume position; App calls it ahead of time while Home sits on a
// show, so open(item, show) usually only resets focus. The page keeps its title until the next load,
// so it still shows it while it fades out. The zones are library controls
// that handle their own keys; this page moves focus between them with Up/Down. The episode row shows
// `shownSeason`, which follows the season bar through a short slide, so a season change never flashes
// the old episodes at the new position.
import QtQuick 2.12
import Seimio.UI 1.0

FocusScope {
    id: page
    property var item: null             // set by load()
    property var show: null
    property bool active: false
    property Item source                // what the glass blurs (the backdrop)
    width: Theme.screenWidth; height: Theme.screenHeight

    readonly property var seasons: show ? show.seasons : []
    // OK on Play or on an episode plays it (the AI pick); a long OK asks how, from a menu beside `rect`
    signal play(var episode)
    signal playHeld(var episode, rect rect)
    // { id, label, progress } of an episode, for playing it
    function target(sh, season, ep) {
        return { id: ep.id, label: (sh.seasons.length > 1 ? "S" + sh.seasons[season].season + " " : "") + "E" + ep.episode, progress: ep.progress || 0 };
    }
    function resumeTarget(sh) { var p = posIn(sh); return sh && sh.seasons && sh.seasons.length ? target(sh, p.s, sh.seasons[p.s].episodes[p.e]) : null }
    property int zone: 0                // 0 actions, 1 seasons, 2 episodes
    // one season: no season bar, and the episodes move up into its place
    readonly property bool oneSeason: seasons.length < 2
    // the season the episode row shows and its card data, set together by showSeason(), so the row is
    // built once per change instead of once per binding that moves
    property int shownSeason: 0
    property var episodes: []
    property var episodeData: []
    property string today: new Date().toISOString().slice(0, 10)   // App passes its own, so previews can fix the day
    onTodayChanged: if (show) showSeason(shownSeason, strip.currentIndex)   // what has aired changes at midnight
    function showSeason(s, e) {
        shownSeason = s;
        episodes = seasons.length ? seasons[s].episodes : [];
        episodeData = episodes.map(function (ep) {
            return {
                art: ep.thumb, fallback: item ? item.backdrop : "", episode: "E" + ep.episode,
                progress: ep.progress > 0 ? ep.progress : -1,
                watched: ep.watched && !(ep.progress > 0),
                upcoming: ep.released > today ? new Date(ep.released + "T12:00:00").toLocaleDateString(Qt.locale(), "d MMM") : ""
            };
        });
        strip.jumpTo(e);
    }

    // where you are in the show: the episode Stremio has as current, else the first unwatched
    function posIn(sh) {
        var seasons = sh && sh.seasons ? sh.seasons : [];
        for (var s = 0; s < seasons.length; s++)
            for (var e = 0; e < seasons[s].episodes.length; e++)
                if (seasons[s].episodes[e].id === sh.current) return { s: s, e: e };
        for (s = 0; s < seasons.length; s++)
            for (e = 0; e < seasons[s].episodes.length; e++)
                if (!seasons[s].episodes[e].watched) return { s: s, e: e };
        return { s: 0, e: 0 };
    }
    readonly property var resumePos: posIn(show)
    // (bindings update in no set order when the show changes, so resumePos can still be the last show's)
    readonly property var resumeSeason: seasons[resumePos.s] || null
    readonly property var resumeEp: resumeSeason ? resumeSeason.episodes[resumePos.e] || null : null
    readonly property string resumeLabel: resumeEp
        ? (resumeEp.progress > 0 ? "Resume " : "Play ") + (seasons.length > 1 ? "S" + resumeSeason.season + " " : "") + "E" + resumeEp.episode
        : "Play"

    function load(title, seasonsAndEpisodes) {
        if (title === item && seasonsAndEpisodes === show) return;
        item = title; show = seasonsAndEpisodes;
        seasonBar.currentIndex = resumePos.s;
        showSeason(resumePos.s, resumePos.e);
    }
    function open(title, seasonsAndEpisodes) {
        load(title, seasonsAndEpisodes);
        zone = 0; actions.currentIndex = 0;
        seasonBar.currentIndex = resumePos.s;
        if (shownSeason !== resumePos.s) showSeason(resumePos.s, resumePos.e); else strip.jumpTo(resumePos.e);
    }

    // season change: slide the old episodes out, swap, slide the new ones in from the side moved toward
    property real rowShift: 0
    property real rowFade: 1
    Connections { target: seasonBar; onCurrentIndexChanged: if (page.active && seasonBar.currentIndex !== page.shownSeason) seasonSwap.restart() }
    SequentialAnimation {
        id: seasonSwap
        ParallelAnimation {
            NumberAnimation { target: page; property: "rowFade"; to: 0; duration: 140; easing.type: Easing.InQuad }
            NumberAnimation { target: page; property: "rowShift"; to: -60 * seasonBar.moveDir; duration: 140; easing.type: Easing.InQuad }
        }
        ScriptAction {
            script: {
                page.showSeason(seasonBar.currentIndex, seasonBar.currentIndex === page.resumePos.s ? page.resumePos.e : 0);
                page.rowShift = 60 * seasonBar.moveDir;
            }
        }
        ParallelAnimation {
            NumberAnimation { target: page; property: "rowFade"; to: 1; duration: 300; easing.type: Theme.ease }
            NumberAnimation { target: page; property: "rowShift"; to: 0; duration: 380; easing.type: Theme.ease }
        }
    }

    // sections arrive one after another each time the page opens (each Reveal replays when `active` turns on)
    opacity: active ? 1 : 0
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: page.active ? 200 : 260 } }

    Reveal {
        shown: page.active
        delay: 120
        x: Theme.margin; y: 96
        TitleArt { width: 560; height: 150; nameSize: 64; logo: page.item && page.item.logo ? page.item.logo : ""; name: page.item ? page.item.name : "" }
        Row {
            y: 172; spacing: 10
            ChipRow { model: page.show ? [page.show.year].concat(page.show.genres).filter(function (x) { return x }) : []; size: 21 }
            Chip { visible: !!(page.show && page.show.rating); kind: "rating"; icon: "star"; text: page.show ? page.show.rating : ""; size: 21 }
            Chip { visible: page.seasons.length > 0; text: page.seasons.length + (page.seasons.length === 1 ? " season" : " seasons"); size: 21 }
        }
        Text {
            y: 230; width: 860; wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight
            text: page.show && page.show.description ? page.show.description : (page.item ? page.item.description : "")
            color: Theme.inkSoft; font.family: Theme.face; font.pixelSize: 25; lineHeight: 1.2
        }
    }

    Reveal {
        id: actionsReveal
        shown: page.active; delay: 190
        x: Theme.margin; y: 418
        ButtonRow {
            id: actions
            focus: page.zone === 0
            onTriggered: if (buttonIndex === 0 && page.resumeEp) page.play(page.resumeTarget(page.show))
            onHeld: if (buttonIndex === 0 && page.resumeEp) page.playHeld(page.resumeTarget(page.show), buttonRect(0))
            model: [
                { label: page.resumeLabel, icon: "play", primary: true, progress: page.resumeEp ? page.resumeEp.progress : -1 },
                { label: "Add to library", icon: "plus", round: true },
                { label: "Mark watched", icon: "check", round: true }
            ]
        }
    }

    Reveal {
        shown: page.active; delay: 260
        visible: !page.oneSeason
        x: Theme.margin; y: 548
        SegmentedBar {
            id: seasonBar
            focus: page.zone === 1
            source: page.source
            sx: Theme.margin; sy: 548
            barHeight: 64; fontSize: 24; segmentPad: 44
            model: page.seasons.map(function (s) { return "Season " + s.season })
        }
    }

    Reveal {
        shown: page.active; delay: 330; dy: 30
        y: page.oneSeason ? 548 : 640; width: page.width; height: 440
        Item {
            width: page.width; height: 440
            opacity: page.rowFade
            transform: Translate { x: page.rowShift }
            CardStrip {
                id: strip
                width: page.width
                focus: page.zone === 2
                model: page.episodeData
                cardWidth: 384; cardHeight: 216; spacing: 32
                showTitles: false; nextLabels: false
                onActivated: if (page.episodes[cardIndex]) page.play(page.target(page.show, page.shownSeason, page.episodes[cardIndex]))
                onHeld: {
                    if (!page.episodes[cardIndex]) return;
                    var p = strip.mapToItem(null, strip.inset, 0);
                    page.playHeld(page.target(page.show, page.shownSeason, page.episodes[cardIndex]), Qt.rect(p.x, p.y, strip.cardWidth, strip.cardHeight));
                }
            }
            // the focused episode (or the resume episode while focus is above the row)
            Item {
                id: epInfo
                x: Theme.margin; y: 246; width: 1100; height: 180
                readonly property var ep: page.episodes.length ? page.episodes[Math.min(strip.currentIndex, page.episodes.length - 1)] : null
                Text {
                    width: 1100; elide: Text.ElideRight
                    text: epInfo.ep ? epInfo.ep.episode + "   " + (epInfo.ep.title || "Episode " + epInfo.ep.episode) : ""
                    color: Theme.ink; font.family: Theme.face; font.pixelSize: 30; font.weight: Font.DemiBold
                }
                ChipRow {
                    y: 48; size: 19
                    model: epInfo.ep ? [epInfo.ep.runtime, epInfo.ep.released ? new Date(epInfo.ep.released + "T12:00:00").toLocaleDateString(Qt.locale(), "d MMM yyyy") : ""].filter(function (s) { return s }) : []
                }
                Text {
                    y: 96; width: 1000; wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight
                    text: epInfo.ep ? epInfo.ep.overview : ""; color: Theme.inkDim
                    font.family: Theme.face; font.pixelSize: 23; lineHeight: 1.2
                }
            }
        }
    }

    Keys.onDownPressed: if (zone < 2) zone = oneSeason ? 2 : zone + 1
    Keys.onUpPressed: if (zone > 0) zone = oneSeason ? 0 : zone - 1
}
