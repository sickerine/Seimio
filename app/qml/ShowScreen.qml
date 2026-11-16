// A show's page: title, actions (resume with progress, library, watched), seasons and episodes, with
// details of the focused episode. Inputs: `item` (the title) and `show` (its seasons and episodes with
// watch state). The zones are library controls that handle their own keys; this page moves focus
// between them with Up/Down. The episode row shows `shownSeason`, which follows the season bar through
// a short slide, so a season change never flashes the old episodes at the new position.
import QtQuick 2.12
import Seimio.UI 1.0

FocusScope {
    id: page
    property var item: null
    property var show: null
    property bool active: false
    property Item source                // what the glass blurs (the backdrop)
    width: Theme.screenWidth; height: Theme.screenHeight

    readonly property var seasons: show ? show.seasons : []
    property int zone: 0                // 0 actions, 1 seasons, 2 episodes
    property int shownSeason: 0
    readonly property var episodes: seasons.length ? seasons[shownSeason].episodes : []
    readonly property string today: new Date().toISOString().slice(0, 10)
    // card data for the strip, built once per season instead of in every delegate binding
    readonly property var episodeData: episodes.map(function (e) {
        return {
            art: e.thumb, episode: "E" + e.episode,
            progress: e.progress > 0 ? e.progress : -1,
            watched: e.watched && !(e.progress > 0),
            upcoming: e.released > today ? new Date(e.released + "T12:00:00").toLocaleDateString(Qt.locale(), "d MMM") : ""
        };
    })

    // where you are in the show: the episode Stremio has as current, else the first unwatched
    function currentPos() {
        if (!show) return { s: 0, e: 0 };
        for (var s = 0; s < seasons.length; s++)
            for (var e = 0; e < seasons[s].episodes.length; e++)
                if (seasons[s].episodes[e].id === show.current) return { s: s, e: e };
        for (s = 0; s < seasons.length; s++)
            for (e = 0; e < seasons[s].episodes.length; e++)
                if (!seasons[s].episodes[e].watched) return { s: s, e: e };
        return { s: 0, e: 0 };
    }
    readonly property var resumePos: currentPos()
    readonly property var resumeEp: seasons.length ? seasons[resumePos.s].episodes[resumePos.e] : null
    readonly property string resumeLabel: resumeEp
        ? (resumeEp.progress > 0 ? "Resume " : "Play ") + (seasons.length > 1 ? "S" + seasons[resumePos.s].season + " " : "") + "E" + resumeEp.episode
        : "Play"

    function open() {
        zone = 0; actions.currentIndex = 0;
        seasonBar.currentIndex = resumePos.s; shownSeason = resumePos.s;
        strip.jumpTo(resumePos.e);
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
                page.shownSeason = seasonBar.currentIndex;
                strip.jumpTo(page.shownSeason === page.resumePos.s ? page.resumePos.e : 0);
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
            Repeater { model: page.show ? [page.show.year].concat(page.show.genres).filter(function (x) { return x }) : []; Chip { text: modelData; size: 21 } }
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
            model: [
                { label: page.resumeLabel, icon: "play", primary: true, progress: page.resumeEp ? page.resumeEp.progress : -1 },
                { label: "Add to library", icon: "plus", round: true },
                { label: "Mark watched", icon: "check", round: true }
            ]
        }
    }

    Reveal {
        shown: page.active; delay: 260
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
        y: 640; width: page.width; height: 440
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
                Row {
                    y: 48; spacing: 10
                    Repeater {
                        model: epInfo.ep ? [epInfo.ep.runtime, epInfo.ep.released ? new Date(epInfo.ep.released + "T12:00:00").toLocaleDateString(Qt.locale(), "d MMM yyyy") : ""].filter(function (s) { return s }) : []
                        Chip { text: modelData; size: 19 }
                    }
                }
                Text {
                    y: 96; width: 1000; wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight
                    text: epInfo.ep ? epInfo.ep.overview : ""; color: Theme.inkDim
                    font.family: Theme.face; font.pixelSize: 23; lineHeight: 1.2
                }
            }
        }
    }

    Keys.onDownPressed: if (zone < 2) zone++
    Keys.onUpPressed: if (zone > 0) zone--
}
