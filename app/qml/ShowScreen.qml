// A show's page: title, actions (resume with progress, library, watched), seasons and episodes, with
// details of the focused episode. load(item, show) builds the page for a title and its seasons and
// episodes with watch state, resting where you are in the show (Episodes.resting, also what Play
// plays); App calls it ahead of time while Home sits on a show, so open(item, show, episodeId) usually
// only places focus. The page rests on the episodes, never on Play: on `episodeId` when given (the
// calendar's release), else where you are; rest(episodeId) does the same on a page already open (back
// from the player, on the episode last played). Play stays a shortcut one row up.
// The page keeps its title until the next load, so it still shows it while it fades out. The zones are library controls
// that handle their own keys; this page moves focus between them with Up/Down. The episode row shows
// `shownSeason`, which follows the season bar through a short slide, so a season change never flashes
// the old episodes at the new position.
import QtQuick 2.12
import Seimio.UI 1.0
import "Episodes.js" as Episodes

FocusScope {
    id: page
    property var item: null             // set by load()
    property var show: null
    property bool active: false
    property Item source                // what the glass blurs (the backdrop)
    width: Theme.screenWidth; height: Theme.screenHeight

    readonly property var seasons: show ? show.seasons : []
    // OK on Play or on an episode plays it (the AI pick); a long OK on Play or on any card of the row (an
    // episode, a film, a related show) opens its menu beside `rect` (`playHeld`, with its `target`)
    signal play(var episode)
    // OK on a related show (an anime franchise's Related tab) opens its page: { id, title }
    signal openShow(var show)
    signal playHeld(var episode, rect rect)
    property var extras: []             // the buttons after Play (App's: the library's), and which was pressed
    signal action(int index)
    // { id, label, progress, type } of an episode, for playing it; a film among the Specials plays as a film.
    // For its menu as well (App.menuEntries): `plays`, OK on it plays it (a related show's opens its page);
    // `watched`; `ahead`, it airs later (an undated special doesn't: it can have been watched, where
    // Episodes.aired wants a date); and `name` and `poster`, which a film or a related show (`type` "movie",
    // "show") is in the library by, being a title.
    function target(sh, season, ep) {
        return { id: ep.id, label: episodeLabel(sh, season, ep), progress: ep.progress || 0, type: ep.type || "series",
                 plays: ep.type !== "show", watched: !!ep.watched, ahead: ep.released > today, name: ep.title || "", poster: ep.poster || "" };
    }
    // A season's tab, for its menu: all of it watched or not. `titles`: the titles of Stremio's its cards
    // are (an anime's season is one or more of Kitsu's entries, a film is one), each marked whole; a plain
    // series has none and goes by the season's number (`id`, `season`). `watched`: everything out in it
    // is. Related shows are no season of this title.
    function seasonCard(s) {
        var se = seasons[s], titles = [], known = {}, out = 0, done = 0;
        if (!se || se.kind === "related") return null;
        se.episodes.forEach(function (ep) {
            if (ep.released > today) return;      // still to come: no part of what "all" marks
            out++; if (ep.watched) done++;
            var entry = show.entries && ep.entry !== undefined ? show.entries[ep.entry] : null;
            if (entry && !known[entry.id]) { known[entry.id] = true; titles.push({ id: entry.id, type: entry.kind === "film" ? "movie" : "series", name: entry.title, poster: entry.poster || "" }) }
        });
        return { id: item.id, type: "season", plays: false, watched: out > 0 && done === out, titles: titles, season: se.season };
    }
    function episodeLabel(sh, season, ep) {
        var n = sh.seasons[season].season;
        if (n === 0) return ep.type === "movie" ? ep.title : "Special " + ep.episode;
        return (sh.seasons.length > 1 ? "S" + n + " " : "") + Episodes.chip(ep.episode);
    }
    function resumeTarget(sh) {
        var p = Episodes.resting(sh);
        return sh && sh.seasons && sh.seasons.length && sh.seasons[p.s].episodes.length ? target(sh, p.s, sh.seasons[p.s].episodes[p.e]) : null;
    }
    property int zone: 0                // 0 actions, 1 seasons, 2 episodes
    // one season: no season bar, and the episodes move up into its place
    readonly property bool oneSeason: seasons.length < 2
    readonly property int seasonCount: seasons.filter(function (s) { return s.season > 0 }).length

    // ---- the entry the page wears ----------------------------------------------------------------------
    // An anime franchise's page takes on the entry you're on (Franchise: a season part, a film, a special):
    // the focused episode's, or the one remembered in the season shown. Its logo, facts and description fill
    // the header (HeroInfo: logo loaded first, a fade through the change) and its backdrop the screen's
    // (App reads `backdrop`). It changes once the selection rests on another entry (Theme.settle, as
    // Home's selection commits). A show without entries (not an anime) wears its own.
    // (The entries' logos aren't loaded ahead: seven of them from fanart.tv, which serves 25 KB/s a
    // connection, kept the page's backdrop waiting behind them. The header keeps the entry it shows
    // until the next one's logo is in.)
    // on a tile, the season it leads to (its first card) is what the page previews
    readonly property var focusedEp: strip.onTile ? ((seasons[shownSeason + (strip.onTile === "next" ? 1 : -1)] || { episodes: [] }).episodes[0] || null)
                                     : episodes.length ? episodes[Math.max(0, Math.min(strip.currentIndex, episodes.length - 1))] : null
    readonly property int wantedEntry: focusedEp && focusedEp.entry !== undefined ? focusedEp.entry : -1
    property int entryIndex: -1
    onWantedEntryChanged: if (!active || entryIndex < 0) entryIndex = wantedEntry; else entrySettle.restart()
    Timer { id: entrySettle; interval: Theme.settle; onTriggered: page.entryIndex = page.wantedEntry }
    readonly property var entry: show && show.entries && entryIndex >= 0 ? show.entries[entryIndex] || null : null
    readonly property string backdrop: entry ? entry.backdrop || "" : ""
    // what a card shows when its own picture can't be had (an episode still to come has no still): its
    // entry's backdrop (an anime's season, film or special has its own), else the title's
    function backdropOf(ep) {
        var e = ep && show && show.entries && ep.entry !== undefined ? show.entries[ep.entry] : null;
        return e && e.backdrop || (item && item.backdrop) || "";
    }
    function headerState() { return header.labState() }      // lab
    function relationLabel(r) { return ({ PREQUEL: "Prequel", SEQUEL: "Sequel", SPIN_OFF: "Spin-off", ALTERNATIVE: "Alternative", SIDE_STORY: "Side story", PARENT: "Main story" })[r] || "Related" }
    readonly property var look: {
        if (entry) {
            var count = entry.episodes || 0, at = entryIndex;              // a related show brings its own count
            if (!count) seasons.forEach(function (s) { s.episodes.forEach(function (e) { if (e.entry === at) count++ }) });
            return { name: entry.title, logo: entry.logo || "", description: entry.description, rating: entry.rating,
                     chips: [entry.year, entry.kind === "film" ? entry.runtime : count + (count === 1 ? " episode" : " episodes")]
                            .concat((entry.genres || []).slice(0, 2)).filter(function (x) { return x }) };
        }
        if (!item) return null;
        return { name: item.name, logo: item.logo || "", description: show && show.description ? show.description : item.description,
                 rating: show ? show.rating : "",
                 chips: (show ? [show.year].concat(show.genres) : []).concat(seasonCount > 0 ? [seasonCount + (seasonCount === 1 ? " season" : " seasons")] : [])
                        .filter(function (x) { return x }) };
    }
    // the season the episode row shows and its card data, set together by showSeason(), so the row is
    // built once per change instead of once per binding that moves
    property int shownSeason: 0
    property var episodes: []
    property var row: ({})               // the episode row's page (PagedStrip), set whole by showSeason()
    property string today: new Date().toISOString().slice(0, 10)   // App passes its own, so previews can fix the day
    onTodayChanged: if (show) showSeason(shownSeason, strip.currentIndex)   // what has aired changes at midnight (where it rests comes with the show, taken again then: Catalog.today)
    // Movies and Related are rows of posters (a film or a show is a title, not an episode); the header
    // carries the focused one's facts, so the episode details under the row step aside. Set with the row's
    // data, so a season change swaps the shape while the row is faded out.
    property bool posterRow: false
    function showSeason(s, e) {
        shownSeason = s;
        episodes = seasons.length ? seasons[s].episodes : [];
        posterRow = seasons.length > 0 && (seasons[s].kind === "films" || seasons[s].kind === "related");
        var cards = episodes.map(function (ep) {
            return {
                // (without a still of its own: its entry's backdrop, else the title's)
                art: posterRow && ep.poster ? ep.poster : ep.thumb, fallback: page.backdropOf(ep),
                episode: ep.type === "show" ? relationLabel(ep.relation) : ep.type === "movie" ? (ep.released ? ep.released.slice(0, 4) : "Film") : Episodes.chip(ep.episode),
                progress: ep.progress > 0 ? ep.progress : -1,
                watched: ep.watched && !(ep.progress > 0),
                upcoming: ep.released > today ? new Date(ep.released + "T12:00:00").toLocaleDateString(Qt.locale(), "d MMM") : ""
            };
        });
        row = { cards: cards, prev: tileOf(s - 1), next: tileOf(s + 1) };
        strip.show(row, e);
    }

    // where you are in the show ({ s, e }), set with the show by load(), so it is never the last show's
    property var resumePos: ({ s: 0, e: 0 })
    readonly property var resumeSeason: seasons[resumePos.s] || null
    readonly property var resumeEp: resumeSeason ? resumeSeason.episodes[resumePos.e] || null : null
    readonly property string resumeLabel: resumeEp
        ? (resumeEp.progress > 0 ? "Resume " : "Play ") + episodeLabel(show, resumePos.s, resumeEp)
        : "Play"

    // `episodeId`: the episode it rests on, when that isn't where you are in the show. The row is built
    // once, for the place it lands on (built for where you are and then again for the episode, a page
    // opened from a calendar release was a 126 ms frame).
    function load(title, seasonsAndEpisodes, episodeId) {
        if (title === item && seasonsAndEpisodes === show) return false;
        Remote.tally("page loaded");
        resumePos = Episodes.resting(seasonsAndEpisodes);
        item = title; show = seasonsAndEpisodes;
        entryIndex = -1;                                  // the new show's entry, at once (not after a settle)
        episodes = [];                                    // another title: place() builds its row, whatever season it lands on
        land(episodeId ? Episodes.find(show, episodeId) : null);
        return true;
    }
    // Lands on the episode at `at` ({ s, e }), or where you are. Play names that episode from then on,
    // unless it is still to come (a calendar release): then Play stays on where you are.
    function land(at) {
        if (at && !(seasons[at.s].episodes[at.e].released > today)) resumePos = at;
        place(at || resumePos);
    }
    function open(title, seasonsAndEpisodes, episodeId) {
        actions.currentIndex = 0;
        if (load(title, seasonsAndEpisodes, episodeId)) zone = 2;
        else { resumePos = Episodes.resting(show); rest(episodeId) }     // built ahead: where you are, unless it opens on an episode
    }
    // The same title with new data (its watch state changed: an episode marked from its menu, another
    // device). The row is built again where it is, on the card that had the focus, and Play names what it
    // named, or once that one is done the next episode that isn't. (Loaded as a page opened on the focused
    // card, Play was renamed to that card.)
    function refresh(title, seasonsAndEpisodes) {
        var tile = strip.onTile, focusedId = !tile && focusedEp ? focusedEp.id : "", named = resumeEp, was = { s: shownSeason, e: Math.max(0, strip.currentIndex) };
        Remote.tally("page refreshed");
        item = title; show = seasonsAndEpisodes; episodes = [];
        var resume = named ? Episodes.find(show, named.id) : null;
        if (resume) {
            // on past what is done by now (a whole season marked watched: the next season's first)
            var next = seasons[resume.s].episodes[resume.e];
            while (next && Episodes.finished(next)) next = Episodes.after(show, next.id, today);
            if (next) resume = Episodes.find(show, next.id);
        }
        resumePos = resume || Episodes.resting(show);
        place(focusedId && Episodes.find(show, focusedId) || (was.s < seasons.length ? was : resumePos));
        // on a season's tile it stays on that tile: OK there turns the season, on a card it plays
        if (tile && shownSeason === was.s) strip.jumpTo(tile === "prev" ? -1 : episodes.length);
    }
    // Play plays what the page rests on: an episode it was opened on (a calendar release, the entry of a
    // franchise that was picked, the one last played) is where you are from then on
    function rest(episodeId) {
        zone = 2;
        land(episodeId ? Episodes.find(show, episodeId) : null);
    }
    // shows season p.s with episode p.e focused: the row first, so the season bar's change below finds
    // it already shown and doesn't start a slide
    function place(p) {
        strip.settle();
        if (shownSeason !== p.s || episodes !== (seasons.length ? seasons[p.s].episodes : [])) showSeason(p.s, p.e); else strip.jumpTo(p.e);
        seasonBar.currentIndex = p.s;
    }

    // The episode row is a PagedStrip (as a calendar day's): the seasons either side (Movies, Specials and
    // Related among them) are its tiles. Turning past a tile, OK on it, or a move on the season bar slides
    // the row over to that season, landing where you are in it from the bar, on its first or last card from
    // a tile. A tile shows its season's first art, name and count; focusing one previews it.
    function tileOf(s) {
        if (s < 0 || s >= seasons.length) return null;
        var se = seasons[s], first = se.episodes[0] || {}, n = se.episodes.length, name = seasonName(s);
        var noun = se.kind === "films" ? " film" : se.kind === "related" ? " show" : se.kind === "specials" ? " special" : " episode";
        return { key: s, kind: se.kind || "", art: posterRow ? (first.poster || first.thumb || "") : (first.thumb || first.poster || ""), fallback: backdropOf(first),
                 upcoming: name, episode: n + noun + (n === 1 ? "" : "s") };
    }
    function seasonName(s) { var se = seasons[s]; return se ? se.label || "Season " + se.season : "" }
    function landing(s) { return s === resumePos.s ? resumePos.e : 0 }
    Connections {
        target: seasonBar
        // against where the row is headed: back on the season shown while its cards are still on their way
        // out, the turn goes back too (it used to finish on the season left behind)
        onCurrentIndexChanged: if (page.active && seasonBar.currentIndex !== (strip.turningNow && !strip.entering ? strip.turnKey : page.shownSeason))
            strip.turnTo(seasonBar.currentIndex > page.shownSeason ? 1 : -1, seasonBar.currentIndex, page.landing(seasonBar.currentIndex))
    }

    // sections arrive one after another each time the page opens (each Reveal replays when `active` turns on)
    opacity: active ? 1 : 0      // holds: `item` and `show` stay until the next load()
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: page.active ? 200 : 260 } }

    Reveal {
        shown: page.active
        delay: 120
        x: Theme.margin; y: 96
        HeroInfo {
            id: header
            item: page.look
            logoSize: Qt.size(560, 150); nameSize: 64; chipsY: 172; chipSize: 21
            textY: 230; textWidth: 860; textSize: 25; textLines: 2
        }
    }

    Reveal {
        id: actionsReveal
        shown: page.active; delay: 190
        x: Theme.margin; y: 418
        ButtonRow {
            id: actions
            focus: page.zone === 0
            onTriggered: if (buttonIndex > 0) page.action(buttonIndex - 1); else if (page.resumeEp) page.play(page.target(page.show, page.resumePos.s, page.resumeEp))     // what its label names
            onHeld: if (buttonIndex === 0 && page.resumeEp) page.playHeld(page.target(page.show, page.resumePos.s, page.resumeEp), buttonRect(0))
            model: [
                { label: page.resumeLabel, icon: "play", primary: true, progress: page.resumeEp ? page.resumeEp.progress : -1 }
            ].concat(page.extras)
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
            model: page.seasons.map(function (s) { return s.label || "Season " + s.season })
            // a long OK on a season: its menu (all of it watched or not), beside the season's segment
            holds: true
            onHeld: {
                var card = page.seasonCard(index), r = cursorRect, p = mapToItem(null, r.x, r.y);
                if (card) page.playHeld(card, Qt.rect(p.x, p.y, r.width, r.height));
            }
        }
    }

    Reveal {
        shown: page.active; delay: 330; dy: 30
        y: page.oneSeason ? 548 : 640; width: page.width; height: 440
        Item {
            width: page.width; height: 440
            PagedStrip {
                id: strip
                width: page.width
                focus: page.zone === 2
                cardWidth: page.posterRow ? Theme.posterCard.width : Theme.stillCard.width; cardHeight: page.posterRow ? Theme.posterCard.height : Theme.stillCard.height; spacing: 32
                narrowest: Theme.posterCard.width
                showTitles: false; nextLabels: false
                onTurn: { page.showSeason(key, land); seasonBar.currentIndex = key }
                onActivated: {
                    var ep = page.episodes[cardIndex];
                    if (ep && ep.type === "show") page.openShow({ id: ep.id, name: ep.title, title: ep.title, description: ep.overview });
                    else if (ep) page.play(page.target(page.show, page.shownSeason, ep));
                }
                onHeld: {
                    if (!page.episodes[cardIndex]) return;
                    var p = strip.mapToItem(null, Theme.margin, 0);
                    page.playHeld(page.target(page.show, page.shownSeason, page.episodes[cardIndex]), Qt.rect(p.x, p.y, strip.cardWidth, strip.cardHeight));
                }
            }
            // the focused episode (or the resume episode while focus is above the row)
            Item {
                id: epInfo
                visible: !page.posterRow
                x: Theme.margin; y: 246; width: 1100; height: 180
                readonly property var ep: !strip.onTile && page.episodes.length ? page.episodes[Math.max(0, Math.min(strip.currentIndex, page.episodes.length - 1))] : null
                Text {
                    width: 1100; elide: Text.ElideRight
                    // an episode's number and title; a film's or a related show's title
                    text: !epInfo.ep ? "" : epInfo.ep.type && epInfo.ep.type !== "series" ? epInfo.ep.title : epInfo.ep.episode + "   " + (epInfo.ep.title || "Episode " + epInfo.ep.episode)
                    color: Theme.ink; font.family: Theme.face; font.pixelSize: 30; font.weight: Font.DemiBold
                }
                ChipRow {
                    y: 48; size: 19
                    model: epInfo.ep ? [epInfo.ep.runtime, epInfo.ep.released ? new Date(epInfo.ep.released + "T12:00:00").toLocaleDateString(Qt.locale(), "d MMM yyyy") : ""].filter(function (s) { return s }) : []
                }
                Text {
                    y: 96; width: 1000; wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight
                    text: epInfo.ep ? epInfo.ep.overview || "" : ""; color: Theme.inkDim
                    font.family: Theme.face; font.pixelSize: 23; lineHeight: 1.2
                }
            }
        }
    }

    Keys.onDownPressed: if (zone < 2) zone = oneSeason ? 2 : zone + 1
    Keys.onUpPressed: if (zone > 0) zone = oneSeason ? 0 : zone - 1
}
