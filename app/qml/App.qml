// The app window. State lives here and nowhere else:
//   layer        which screen has the remote: home | tabs | show | title | menu | streams | player
//   trail        the screens under it, each with its title in hand: Back returns to the last (go, back)
//   playMenu     the Play options are open over the page (a long OK on Play or an episode)
//   focusItem    the title the remote is on (from Home), changes instantly
//   displayItem  Home's selection, which its backdrop and info render; it changes only through commit().
//                Moving focus commits once it settles, so key presses stay light; opening anything commits
//                first, so nothing opens on a stale title.
//   held         the title in hand, { item, show, video }: what the open page, the stream list and the
//                player are about, and the episode it was picked for (a calendar release, a franchise's
//                entry). An anime is held as its whole franchise wherever it was picked.
//   playTarget   the video playing or asked for. Where it is in the held show (`playingAt`) is derived,
//                and with it the player's row, what's next and the look the player wears: nothing asks
//                whether it is a series or compares one screen's title with another's.
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
    readonly property bool onHome: layer === "home" || layer === "tabs" || layer === "menu" || layer === "profile"
    // signed out, the app is its sign-in screen; signed in, Home
    readonly property bool signedOut: account.ready && !account.signedIn
    onSignedOutChanged: { if (signedOut) { trail = []; held = null; profileOpen = false; layer = "signin" } else if (layer === "signin") layer = "home" }
    property bool profileOpen: false                       // the account's menu, under its picture
    onProfileOpenChanged: probe.captures()
    // the Anime tab has its own screen; Home's rows, selection and scroll belong to whichever is up
    // 0 Home, 1 Anime, 2 Movies, 3 Series, 4 Library, 5 search. The number is the app's; where a tab
    // sits on the bar is the bar's (the search is drawn first, at the left end: `tabs.placeOf`).
    property int tab: 0
    onTabChanged: tabs.currentIndex = tabs.placeOf(tab)
    property alias searchText: searchBar.text
    readonly property bool animeTab: tab === 1
    // Movies, Series and the Library are one screen (BrowseScreen), each a list of Account's; `browsed` is
    // the last one up, which the screen goes on showing while it fades
    readonly property string browsing: ["", "", "movie", "series", "library"][tab] || ""
    readonly property bool browseTab: browsing !== ""
    property string browsed: ""
    onBrowsingChanged: if (browsing) browsed = browsing
    readonly property bool searchTab: tab === 5              // the tab bar turns into the search bar; its results below
    onSearchTabChanged: { if (searchTab) searchBar.zone = 0; probe.captures() }    // reached from the tab bar: to type
    // the kinds of title a search finds, as its bar names them and as Catalog does
    readonly property var searchKinds: [["Anime", "anime"], ["Series", "series"], ["Movies", "movie"]]
    readonly property bool bare: onHome && (browsing === "library" || (searchTab && !search.any))     // a tab with no title above its grid: no info, the backdrop frosted
    readonly property bool scrolled: animeTab ? anime.scrolled : browseTab ? browse.scrolled : searchTab ? search.scrolled : home.scrolled
    readonly property var focusItem: animeTab ? anime.focusItem : browseTab ? browse.focusItem : searchTab ? search.focusItem : home.focusItem
    property var displayItem: null
    // A search's film or series is a name, a year and pictures (`thin`): the rest of what the info shows
    // is its page's. So it is shown as its page's item, once that is in (one version of a title's info,
    // not a name that grows a description), or as it is if that can't be had (Catalog.unfetchable). Until
    // then the info stays on the title before it.
    function commit() {
        settle.stop();
        var it = focusItem;
        if (it && it.thin) {
            var f = catalog.franchise(it.id);
            if (f) it = f.item; else if (!catalog.unfetchable(it.id)) return;
        }
        if (displayItem !== it) displayItem = it;
    }
    // the cursor has rested on a title: it shows, a search's film or series once it has been fetched
    function rest() {
        var it = focusItem;
        if (it && it.thin && !catalog.franchise(it.id) && !catalog.unfetchable(it.id)) catalog.loadFranchise(it); else commit();
    }
    // lab: how long the info took to follow the cursor, the last time it did (a search's film or series
    // waits for its page's item)
    property double focusedAt: 0
    property int shownLag: 0
    onFocusItemChanged: {
        focusedAt = Date.now();
        if (!displayItem) rest(); else settle.restart();
        if (layer === "menu" && menuCard && (!focusItem || focusItem.id !== menuCard.id)) layer = "home";      // the card under Home's menu is another title now
        probe.captures(); if (home.row === 1) probe.act(home.dayOpen ? "day move" : "calendar move");
    }
    Timer { id: settle; interval: Theme.settle; onTriggered: app.rest() }
    // opening or closing a calendar day changes the whole screen, so it commits at once
    Connections { target: home; onDayOpenChanged: { app.commit(); probe.act(home.dayOpen ? "day open" : "day close") } }
    // the show page for the selected Continue Watching or Anime title is built once Home has been still for a
    // moment (after the backdrop and info have changed), so opening it costs nothing. Not from the
    // calendar: resting on its days would build a page each time (~25 ms) for an open that's rarer there
    onDisplayItemChanged: { shownLag = Date.now() - focusedAt; prepareShow.restart() }
    Timer {
        id: prepareShow; interval: 1200
        onTriggered: {
            if (!app.displayItem || !app.onHome || !(app.animeTab || app.browseTab || app.searchTab || home.row === 0)) return;
            // a title that has to be fetched is fetched ahead (its page is built when it's in), so OK opens it at once
            if (app.fetched(app.displayItem)) { catalog.loadFranchise(app.displayItem); return }
            if (app.episodeCount(app.displayItem.id) > 1) app.buildAhead(app.displayItem.id, app.displayItem, app.showData(app.displayItem.id));
        }
    }
    // Building a page is 60-90 ms of JavaScript on the TV, and a franchise arrives whenever the network
    // answers: one built while the remote was moving along the tab bar was a 90 ms frame. So a page built
    // ahead waits until nothing has moved for a second (`still`: any key press, whoever takes it, and a
    // backdrop crossfade start it over), and is built only if its title is still the selection. The latest
    // one asked for is the one that waits.
    //
    // The quiet takes three things, one at a time and a few frames apart, so no two make one long stall:
    // the Anime tab (once), the selection's page, and last the JavaScript engine's garbage (the other two
    // leave some). A collection stops the GUI thread for 22 to 35 ms on the TV, and left to the engine it
    // came in the middle of a move; collected at rest, the engine has room for the next moves. At rest
    // what moves by itself is on the render thread (Ambient), so none of this costs a frame.
    property var ahead: null                               // { source, item, show }
    property bool littered: false                          // something has moved since the last collection
    function moved() { littered = true; quiet.stop(); still.restart() }
    Connections { target: Remote; onStirred: app.moved() }
    function buildAhead(source, item, show) { ahead = { source: source, item: item, show: show }; if (!still.running && !quiet.running) quietWork() }
    function quietWork() {
        var a = ahead;
        // the Anime tab first: shown unbuilt, its rows are a 180 ms stall on the way in
        if (onHome && started && anime.warm()) { }
        else if (a && onHome && selected(a.source, a.item) && episodesIn(a.show) > 1) { ahead = null; showPage.load(a.item, a.show) }      // (a film has no page to build)
        else {
            ahead = null;
            // not over a video: its overlay moves on its own clock
            if (littered && !watching) { littered = false; gc() }
            return;
        }
        littered = true; quiet.restart();
    }
    // the season came in after the quiet began: the Anime tab doesn't wait for the next one
    Connections { target: catalog; onSeasonLoaded: if (!still.running && !quiet.running) app.quietWork() }
    // (the work a few frames after the rest begins: what moves by itself has gone to the render thread by then)
    // OK on a title that has to come in first is a wait with nothing moving, so the quiet begins as soon as
    // the press has shown: a page built the moment its title arrived, 25 ms of it, held up a frame when that
    // was inside the second after the key.
    Timer { id: still; interval: app.franchiseOpening ? 300 : 1000; onTriggered: { Remote.resting = !probe.variant.noRest; quiet.restart() } }
    Timer { id: quiet; interval: 64; onTriggered: app.quietWork() }
    // Home's own start (its art decodes for about 5 s after launch) is not idleness: the Anime tab waits it out
    property bool started: false
    Timer { interval: 2500; running: !app.warming; onTriggered: { app.started = true; if (!still.running) still.start() } }

    // ---- the title in hand, and the way back ----------------------------------------------------------
    property var held: null
    // `show` only when there is something to browse: a film, or a show whose whole run is one episode, is
    // held alone
    function hold(item, show, video) { held = { item: item, show: episodesIn(show) > 1 ? show : null, video: video || (item ? item.video : "") || "" } }
    // Home's selection as the title in hand: an anime's franchise when it's in
    function holdSelection() {
        commit();
        var f = displayItem && fetched(displayItem) ? catalog.franchise(displayItem.id) : null;
        if (f) hold(f.item, f.show, picked(f, displayItem)); else hold(displayItem, displayItem ? showData(displayItem.id) : null);
    }
    // The episode a franchise was picked for: the release's own, by id or (an anime's calendar release) by
    // its number in the entry picked, else where you are in that entry (Franchise's `video`)
    function picked(f, item) {
        var entries = f.show.entries || [], at = -1, found = "";
        for (var i = 0; i < entries.length; i++) if (entries[i].id === f.item.id) at = i;
        // by number first: the franchise's own item carries the release's number too, with its `video`
        // already set to where you are in the entry
        if (item.number > 0) f.show.seasons.forEach(function (s) { s.episodes.forEach(function (e) { if (e.entry === at && e.number === item.number) found = e.id }) });
        return found || item.video || f.item.video || "";
    }
    // the title a page renders: Home's selection, or the one in hand once a page has it
    readonly property var pageItem: onHome || !held ? displayItem : held.item
    // The backdrop a title has: its own, or what the catalog knows of it (a library title is a name and a
    // poster), or its franchise's once that has come in (`arrivals`: one more has)
    property int arrivals: 0
    function backdropOf(item) {
        if (!item) return "";
        var f = arrivals >= 0 ? catalog.franchise(item.id) : null;
        return item.backdrop || catalog.backdrop(item.id) || (f && f.item.backdrop) || "";
    }
    // The episode playing as IMDb numbers it ("tt…:season:episode"), for the skip databases keyed that way:
    // only an episode of a numbered season that is one entry counted from 1. A later part of a split
    // season, a film and a special are numbered otherwise there, and another episode's intro is worse
    // than none.
    function imdbEpisode(id) {
        var at = held && held.show && held.show.imdb ? Episodes.find(held.show, id) : null;
        if (!at) return "";
        var season = held.show.seasons[at.s], ep = season.episodes[at.e];
        return season.season > 0 && !season.kind && ep.number === ep.episode ? held.show.imdb + ":" + season.season + ":" + ep.episode : "";
    }
    function heldEpisode(id) { var at = held && held.show ? Episodes.find(held.show, id) : null; return at ? held.show.seasons[at.s].episodes[at.e] : null }
    // what the player and the stream list show for a video: its entry in an anime franchise (a season's or
    // a film's own name, logo and art), else the title
    function lookFor(id) {
        if (!held) return null;
        var ep = heldEpisode(id), entry = ep && held.show.entries && ep.entry !== undefined ? held.show.entries[ep.entry] : null;
        return entry ? { name: entry.title, logo: entry.logo || "", backdrop: entry.backdrop || held.item.backdrop, year: entry.year } : held.item;
    }
    property var trail: []
    onOnHomeChanged: if (onHome) trail = []
    // onto another screen; `from` is the title that was in hand when a page opens over a page (Related)
    function go(to, from) { if (!onHome) trail = trail.concat([{ layer: layer, held: from || held }]); layer = to }
    function back() {
        var t = trail.slice(), to = t.pop() || { layer: "home", held: held };
        trail = t;
        if (to.held && to.held !== held) {                  // a page that another replaced: it comes back as it opens
            held = to.held;
            if (to.layer === "show") showPage.open(held.item, held.show, held.video); else if (to.layer === "title") titlePage.open(held.item);
        }
        // the show page comes back on what was last played (it may have changed in the player)
        else if (layer === "player" && to.layer === "show" && playingAt) showPage.rest(playTarget.id);
        layer = to.layer;
    }

    // out of the player, by Back or because the file ended with nothing after it
    function leavePlayer() { endReport(); streams.cancel(); player.stop(); back(); if (watchingStale) { watchingStale = false; catalog.reload() } }

    // ---- the library, and watch state -------------------------------------------------------------------
    // What the title in hand is in Stremio's library: on Home the selection (its menu is a Continue
    // Watching card's, Stremio's own item); on a page an anime franchise's entry on screen (each is a title
    // of its own there), else the page's title.
    readonly property var libraryItem: {
        if (onHome) return displayItem && displayItem.type ? { id: displayItem.id, type: displayItem.type, name: displayItem.name, poster: displayItem.poster || "" } : null;
        var e = layer === "show" && held && held.show ? showPage.entry : null, i = held ? held.item : null;
        if (e) return { id: e.id, type: e.kind === "film" ? "movie" : "series", name: e.title, poster: e.poster || "" };
        if (!i) return null;
        return { id: i.id, type: held.show ? "series" : "movie", name: i.name,
                 poster: i.poster || (/^tt/.test(i.id) ? "https://images.metahub.space/poster/medium/" + i.id + "/img" : i.art || "") };
    }
    // A title's two entries, wherever a title has a menu or buttons (a page's after Play, Home's menu, a
    // held film or related show): in the library or not, watched or not, as the account has it now; and
    // what they do.
    function libraryEntries(item) {
        var known = account.libraryRevision >= 0 && !!item, has = known && account.inLibrary(item.id), seen = known && account.watched(item.id);
        // (`primary`: a page's round button is the white disc with the dark check a watched card wears,
        // so the button says the title is watched before it is focused)
        return [{ label: has ? "Remove from library" : "Add to library", icon: has ? "minus" : "plus", round: true },
                { label: seen ? "Mark unwatched" : "Mark watched", icon: "check", round: true, primary: seen }];
    }
    function libraryAct(item, index) {
        if (!item) return;
        if (index === 1) account.markWatched(item, !account.watched(item.id));
        else if (account.inLibrary(item.id)) account.removeFromLibrary(item.id); else account.addToLibrary(item);
    }
    readonly property var libraryButtons: libraryEntries(libraryItem)
    // The account's watch state changed (a title played, another device, a sign-in): Home takes it again,
    // but never under the video (it would rebuild rows behind the film); the page in hand follows.
    property bool watchingStale: false
    // (a title added to the library changes the calendar though Continue Watching stays as it was)
    function accountChanged() { if (layer === "player") watchingStale = true; else catalog.reload() }
    Connections { target: account; onWatchingChanged: app.accountChanged(); onLibraryChanged: app.accountChanged() }
    property string franchiseRefresh: ""                   // the franchise asked for again, for the page in hand
    function refreshHeld() {
        shows = ({});                                      // (Catalog has forgotten its pages with the library they were made with)
        if (!held || onHome || layer === "player" || layer === "signin") return;
        if (fetched(held.item)) { franchiseRefresh = held.item.id; catalog.loadFranchise(held.item) }
        else if (held.show) rehold(held.item, showData(held.item.id));
    }
    // the same title with new data: the page stays where it is
    function rehold(item, show) {
        hold(item, show, held.video);
        if (layer === "show" && held.show) showPage.refresh(held.item, held.show);
    }
    // ---- watch progress ----------------------------------------------------------------------------------
    // What plays is reported to Stremio's core (Account), whose rules say what is watched and where
    // Continue Watching resumes. `reported` is the video the core has been told is playing.
    property string reported: ""
    function endReport() { if (reported) { account.timeChanged(player.position, player.duration); account.stopped(); reported = "" } }
    Connections {
        target: player
        // a lab tour plays without telling Stremio (`unreported`): it would move the account's own progress
        onPlayingChanged: if (player.playing && app.layer === "player" && app.playTarget && player.stream && app.reported !== app.playTarget.id && !probe.variant.unreported) {
            app.reported = app.playTarget.id;
            account.playing(app.playTarget.id, app.playTarget.type || "series", player.stream.url);
        }
        onPausedChanged: if (app.reported) { account.timeChanged(player.position, player.duration); account.paused(player.paused) }
        onSought: if (app.reported) account.seeked(to, player.duration)
    }
    Timer { running: app.reported !== "" && player.playing && !player.paused; interval: 10000; repeat: true; onTriggered: account.timeChanged(player.position, player.duration) }
    function open() {
        commit();
        // an anime opens as its whole franchise, wherever it was picked (Continue Watching, the calendar, the
        // Anime tab); a title from a list, the library or a search is fetched the same way (a search's
        // title that isn't in yet is not what the info shows, and opens all the same)
        var thin = !!(focusItem && focusItem.thin), it = thin ? focusItem : displayItem;
        if (it && (thin || fetched(it))) { openFranchise(it); return }
        openPage();
    }
    function openPage() { hold(displayItem, showData(displayItem.id)); showHeld(null) }
    // the page for the title in hand: the show page, on the episode it was picked for or where you are in
    // it, or the title page for a film or a single episode
    function showHeld(from) {
        var to = held.show ? "show" : "title";
        if (held.show) showPage.open(held.item, held.show, held.video); else titlePage.open(held.item);
        if (onHome) layer = to; else go(to, from);
    }
    // Playing. Play (and OK on an episode) plays the AI pick: the player opens at once and says what it's
    // doing while `streams` fetches, asks the decision model and resolves the link; if the pick fails, the
    // stream list opens on what was fetched. A long OK offers both ways (Play AI Pick, Play from Stream).
    // `episode` is { id, label, progress } from a show's page; without one it's the movie, or the show's
    // next episode.
    property var playTarget: null
    // where it is in the held show ({ s, e }), or null: a film on its own, or nothing playing
    readonly property var playingAt: playTarget && held && held.show ? Episodes.find(held.show, playTarget.id) : null
    // Without an `episode`: the one the title was picked for (`video`: a calendar release, the entry of a
    // franchise that Continue Watching had), else where you are in it, else the film itself
    function target(episode) {
        if (episode) return { type: episode.type || "series", id: episode.id, label: episode.label, progress: episode.progress };
        var sh = held.show || showData(held.item.id), at = sh && held.video ? Episodes.find(sh, held.video) : null;
        var t = at ? showPage.target(sh, at.s, sh.seasons[at.s].episodes[at.e]) : showPage.resumeTarget(sh);
        return t ? { type: t.type, id: t.id, label: held.show ? t.label : "", progress: t.progress }
                 : { type: "movie", id: held.item.id, label: "", progress: held.item.progress || 0 };
    }
    function playAi(episode) {
        endReport();                                       // another video: the one playing ends where it is
        playMenu = false;
        if (onHome) holdSelection();                        // Play from Home's menu: no page had it yet
        playTarget = target(episode);
        // the row under the player is the show page's, on this title: a film has it as an episode does
        if (held.show && showPage.show !== held.show) showPage.load(held.item, held.show);
        // switching episodes inside the player keeps the release: Stremio's binge group (see Streams.play)
        var binge = layer === "player" && player.stream ? player.stream.bingeGroup || "" : "";
        player.prepare(lookFor(playTarget.id), playTarget.label);
        if (layer !== "player") go("player");               // an episode from the player goes back where the player came from
        streams.play(playTarget.type, playTarget.id, held.item.name + (playTarget.label ? " " + playTarget.label : ""), binge);
    }
    // a video's thumbnail from the held show, or the art of what it belongs to
    function episodeArt(id) {
        var ep = heldEpisode(id), look = lookFor(id);
        return ep && ep.thumb ? ep.thumb : look ? look.backdrop || "" : "";
    }
    function openStreams(episode) {
        playMenu = false;
        if (onHome) holdSelection();
        // the fetch starts before the page is up, so its list waits for the new streams instead of
        // building the last ones first
        playTarget = target(episode);
        streamPage.open(lookFor(playTarget.id), playTarget); go("streams");
    }
    Connections {
        target: streams
        onPlayable: {
            if (app.layer === "streams") { player.prepare(app.lookFor(app.playTarget.id), streamPage.label); app.go("player") }
            if (app.layer !== "player") return;
            // resume where it was left, unless it was nearly done
            // a stream switch keeps the time exactly (`resumeMs`: files of one episode differ in length)
            var t = app.playTarget, p = t ? t.progress || 0 : 0;
            player.start(url, stream, t && t.resumeMs !== undefined ? { ms: t.resumeMs } : p > 0 && p < 95 ? p / 100 : 0);
        }
        onFailed: {
            if (app.layer !== "player") return;
            app.layer = "streams";                          // in the player's place: Back goes where the player would have
            // with nothing listed the list says why itself
            streamPage.show(app.lookFor(app.playTarget.id), app.playTarget.label, streams.total ? reason + ". Choose a stream to play." : "");
        }
    }
    // The menu of what was held (a long OK on Play, on a card of a show's row, on a title's card in a grid),
    // over the screen that has it and beside the card. `menuEpisode` is that card, or null for a title
    // page's Play:
    //   { id, type, plays, watched, ahead, name, poster, kind }
    //   type    "series" an episode, "movie" a film, "show" a title with a page (`kind`: "movie" when it is a film)
    //   plays   OK on it plays it (an episode or a film on a show's row); else OK opens its page
    // What it is says what the menu has, the same wherever that kind of card is:
    //   what plays                              Play AI Pick, Play from Stream
    //   a title (a film, a show)                the library's two entries
    //   an episode                              watched or not
    //   a season's tab (type "season")          all of it watched or not (ShowScreen.seasonCard)
    // and nothing is marked that airs later (`ahead`). A series marked watched takes its episodes with it
    // (Account.markWatched).
    property bool playMenu: false
    property var menuEpisode: null
    property rect menuAnchor: Qt.rect(0, 0, 0, 0)
    // (Remote.menuOver first: what the menu takes the remote from keeps its focused look, HeldFocus)
    function openPlayMenu(episode, r) { commit(); menuEpisode = episode; menuAnchor = r; Remote.menuOver = true; playMenu = true }
    readonly property var menuTitle: menuEpisode && (menuEpisode.type === "movie" || menuEpisode.type === "show")
        ? { id: menuEpisode.id, type: (menuEpisode.kind || menuEpisode.type) === "movie" ? "movie" : "series", name: menuEpisode.name, poster: menuEpisode.poster } : null
    readonly property int menuPlays: menuEpisode && !menuEpisode.plays ? 0 : 2
    readonly property var playEntries: [{ label: "Play AI Pick", icon: "play" }, { label: "Play from Stream", icon: "list" }]
    readonly property var menuEntries: {
        var e = menuEpisode, entries = menuPlays ? playEntries : [];
        if (!e) return entries;
        if (e.type === "season") return [{ label: e.watched ? "Mark all unwatched" : "Mark all watched", icon: "check" }];
        if (menuTitle) return entries.concat(libraryEntries(menuTitle).slice(0, e.ahead ? 1 : 2));
        return e.ahead ? entries : entries.concat([{ label: e.watched ? "Mark unwatched" : "Mark watched", icon: "check" }]);
    }
    function menuAct(index) {
        var e = menuEpisode;
        if (index < menuPlays) { if (index === 0) playAi(e); else openStreams(e); return }
        playMenu = false;
        if (menuTitle) libraryAct(menuTitle, index - menuPlays);
        else if (e.type !== "season") account.markEpisode(e.id, !e.watched);
        // a season: each title its cards are, whole; a plain series' season by its number
        else if (e.titles.length) e.titles.forEach(function (t) { account.markWatched(t, !e.watched) });
        else account.markSeason(e.id, e.season, !e.watched);
    }
    // A title's card in a grid (the Anime tab, Movies, Series, the Library, a search). A card of the Anime
    // tab is AniList's until its franchise is in, which says which of Stremio's titles it is (a Kitsu id):
    // asked for if it isn't, and the menu opens when it comes, if the card still has the focus.
    property var menuWaiting: null                         // { item, rect }
    function openTitleMenu(item, r) {
        var f = /^anilist:/.test(item.id) ? catalog.franchise(item.id) : null;
        if (/^anilist:/.test(item.id) && !f) { menuWaiting = { item: item, rect: r }; catalog.loadFranchise(item); return }
        var t = f ? f.item : item, entry = f && f.show && f.show.entries ? f.show.entries.filter(function (e) { return e.id === t.id })[0] : null;
        openPlayMenu({ id: t.id, type: "show", plays: false, kind: entry ? (entry.kind === "film" ? "movie" : "series") : t.type,
                       name: entry ? entry.title : t.name, poster: entry ? entry.poster : t.poster || "" }, r);
    }
    // A release's card in an open calendar day (an episode of a show in the library). OK opens its show's
    // page, so nothing plays from here: watched or not, once it has aired.
    function openReleaseMenu(entry, r) {
        if (entry.video && entry.released <= today) openPlayMenu({ id: entry.video, type: "series", plays: false, watched: entry.watched, ahead: false }, r);
    }
    function titleMenuArrived(sourceId, item) {
        var w = menuWaiting;
        if (!w || w.item.id !== sourceId) return;
        menuWaiting = null;
        if (layer === "home" && selected(sourceId, item)) openTitleMenu(w.item, w.rect);
    }
    onPlayMenuChanged: probe.captures()                    // lab: captures follow the Play options too
    readonly property bool menuOpen: layer === "menu" || playMenu
    onMenuOpenChanged: if (!menuOpen) Remote.menuOver = false
    // a handoff (a switch inside the player) is still watching: the scene behind stays away, or the
    // title's backdrop showed through as the still dissolved into the new video
    readonly property bool watching: layer === "player" && (player.playing || !!player.handoff)
    // lab: { "playList": [{ "title", "url", "at" }], "playSeconds": 20, "control": url } plays each in turn (from
    // `at` of the way through: a film opens on a silent logo) from 8 s
    // after launch and logs how each went (playLog, in the lab reports; tools/playback-matrix.py). After one
    // that fails, `control` (a file known to play) plays: if it fails too, the TV's media service is stuck and
    // nothing after it would mean anything, so the run stops there. Each one's picture is captured 5 s in
    // (`playShotAt` ms: an HDR or Dolby Vision file needs the panel to switch modes first)
    // (play-<title>.png beside the lab's other captures): the pipeline reports no error for a track it can't
    // decode, so only the screen and someone's ears say whether it really played.
    property var playLog: []
    property int playIndex: -1
    property bool playControl: false
    Timer { id: playShot; interval: probe.variant.playShotAt || 5000; property string name: ""; onTriggered: probe.capture("/media/developer/temp/play-" + name + ".png") }
    Timer {
        running: !!probe.variant.playList; repeat: true
        interval: app.playIndex < 0 ? 8000 : (probe.variant.playSeconds || 20) * 1000
        onTriggered: {
            var list = probe.variant.playList, control = probe.variant.control;
            var play = function (title, url, at) { player.prepare({ name: title }, ""); player.start(url, null, at || 0); app.layer = "player"; playShot.name = title; playShot.restart() }
            if (app.playIndex >= 0) {
                var s = player.seen, log = app.playLog, ok = player.position > 2000 && !player.failure;       // (a short clip may have ended)
                log.push({ title: app.playControl ? "control" : list[app.playIndex].title, ok: ok, playing: player.playing, position: player.position,
                           duration: player.duration, failure: player.failure, tracks: player.subtitleInfo().replace(/^.* audioTrack /, "audioTrack ").replace(/ prefs .* audio /, " audio "),
                           video: (s.videoInfo || "").slice(0, 420), source: (s.sourceInfo || "").slice(0, 700), error: (s.error || "").slice(0, 200) });
                app.playLog = log; player.stop();
                if (app.playControl) { app.playControl = false; if (!ok) { stop(); app.layer = "home"; return } }
                else if (!ok && control) { app.playControl = true; play("control", control); return }
            }
            if (++app.playIndex >= list.length) { stop(); app.layer = "home"; return }
            play(list[app.playIndex].title, list[app.playIndex].url, list[app.playIndex].at);
        }
    }
    // Home's menu is for the card it opened on (`menuCard`: that title, as the library has it). A list that
    // changes under it (Continue Watching taken again: a title gone, another order) closes it, so what it
    // does never lands on the title that took the card's place.
    property var menuCard: null
    function openMenu() { commit(); playMenu = false; menuCard = libraryItem; Remote.menuOver = true; layer = "menu"; probe.captures() }
    onLayerChanged: { Remote.stir(); probe.act(layer); probe.captures() }      // a screen coming or going is movement, whoever asked

    // effects that are needed later are drawn invisibly for a moment at startup, so their shaders
    // compile before anyone opens them
    property bool warming: true
    Timer { running: catalog.ready; interval: 600; onTriggered: app.warming = false }      // (an account with nothing watched has Home's data too)

    // the data, held natively (Seimio.Data); a show's seasons come over to QML once and are kept, so the
    // show page sees the same object again and needn't rebuild
    // everything comes live from the services, and the account from Stremio's core (Account)
    Catalog { id: catalog; today: app.today; onLoaded: app.refreshHeld() }
    Account { id: account; onMarkFailed: app.say("Couldn't mark it") }
    // A moment's word at the bottom of the screen when something asked for couldn't be done: a show that
    // can't open (not on Kitsu yet, its episodes didn't load), a season that didn't load, an episode that
    // couldn't be marked. The Anime tab's season on its way shows there too.
    property string notice: ""
    function say(text) { notice = text; noticeTimer.restart() }
    Timer { id: noticeTimer; interval: 2600; onTriggered: app.notice = "" }
    property var shows: ({})
    function showData(id) { if (!shows[id]) shows[id] = catalog.show(id); return shows[id] }
    // episodes in a show: the library's, or one loaded since (the Anime tab's)
    function episodesIn(sh) {
        var n = 0;
        for (var s = 0; sh && sh.seasons && s < sh.seasons.length; s++) n += sh.seasons[s].episodes.length;
        return n;
    }
    function episodeCount(id) { return episodesIn(showData(id)) }
    // An anime (a Kitsu or AniList id) is a franchise (Catalog.loadFranchise): fetched once, ahead while the
    // selection rests on it or on OK, held by Catalog under the id it was asked for and its Kitsu id
    // (`catalog.franchise(id)`: asking twice fetches once, and what is held, on its way or not to be had is
    // Catalog's to know), and opened when it's in if OK asked for it (`franchiseOpening`) and it's still
    // the selection. Without it (not on Kitsu, the services down) the title's own page opens, if it has one.
    // (Whether a video is anime, for the pick's rules and the track choices, is Streams' to say and nobody
    // else's: `streams.anime`. This is only whether an id is one a franchise can be fetched for.)
    function franchiseId(id) { return /^(kitsu|anilist):/.test(id || "") }
    // whether a title's page is fetched (Catalog.loadFranchise): an anime, and anything the catalog doesn't
    // hold whole already (it holds Continue Watching's titles with their seasons)
    function fetched(item) { return franchiseId(item.id) || !catalog.holds(item.id) }
    property string franchiseOpening: ""
    property var franchiseFrom: null                       // the title in hand when it was asked for
    function openFranchise(item) {
        var f = catalog.franchise(item.id), from = held;
        if (!f) { franchiseOpening = item.id; franchiseFrom = held; catalog.loadFranchise(item); return }
        hold(f.item, f.show, picked(f, item));
        showHeld(from);                                    // from a page's Related tab, over that page
        probe.captures();                                  // lab: a page over a page is a screen change too
    }
    function selected(sourceId, item) { var s = focusItem; return !!s && (s.id === sourceId || s.id === item.id) }
    // the title OK asked for has come in: its page opens a few frames later, if it is still the selection
    Timer {
        id: arrived
        property string source
        property var title: null
        interval: 48
        onTriggered: if (app.onHome && app.selected(source, title)) { app.commit(); app.openFranchise(title) }
    }
    Connections {
        target: catalog
        onFranchiseReady: {
            app.arrivals++;
            if (app.onHome && app.focusItem && app.focusItem.thin && app.focusItem.id === sourceId && !settle.running) app.commit();      // the cursor rested on it: now it shows
            if (sourceId === app.franchiseRefresh) {         // asked for again after the watch state changed
                app.franchiseRefresh = "";
                if (app.held && (app.held.item.id === item.id || app.held.item.id === sourceId)) app.rehold(item, show);
                return;
            }
            app.shows[item.id] = show;                     // its episodes, for the player's row and what's next
            if (sourceId.indexOf("anilist:") === 0) anime.resolve(sourceId, item);   // the chart's selection becomes the Kitsu item
            app.titleMenuArrived(sourceId, item);                 // a held card's menu waited for it
            // playing already (Play from Home before it was in): the franchise becomes the title in hand, so
            // the player has its row
            var playing = app.layer === "player" && app.held && app.playTarget && (app.held.item.id === sourceId || app.held.item.id === item.id) ? Episodes.find(show, app.playTarget.id) : null;
            if (playing) { app.hold(item, show); if (!showPage.load(item, show, app.playTarget.id)) showPage.place(playing); return }
            // asked for from a page's Related tab: it opens over the page
            if (sourceId === app.franchiseOpening && app.layer === "show" && app.held === app.franchiseFrom) { app.franchiseOpening = ""; app.openFranchise(item); return }
            if (!app.onHome || !app.selected(sourceId, item)) { if (sourceId === app.franchiseOpening) app.franchiseOpening = ""; return }
            if (sourceId !== app.franchiseOpening) { app.buildAhead(sourceId, item, show); return }
            app.franchiseOpening = "";
            // (a few frames after it came in: taking it in, 20 ms of it for a long show, and building its
            // page, 25 ms, were one stall of 60 to 70 ms)
            arrived.source = sourceId; arrived.title = item; arrived.restart();
        }
        onFranchiseFailed: {
            if (app.onHome && app.focusItem && app.focusItem.thin && app.focusItem.id === sourceId && !settle.running) app.commit();      // shown as the search gave it
            // a held card's menu waited for it: it is no title of Stremio's, so there is nothing to offer but why
            if (app.menuWaiting && app.menuWaiting.item.id === sourceId) { app.menuWaiting = null; app.say(reason) }
            if (sourceId !== app.franchiseOpening) return;
            app.franchiseOpening = "";
            if (app.animeTab) app.say(reason); else if (app.onHome && app.focusItem && app.focusItem.id === sourceId) app.openPage();
        }
    }
    WindowTools { id: tools; onKeyPressed: Remote.stir() }
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
    property bool lab: true                                // previews turn the lab off (LabProbe.on)
    property bool still: false                             // and hold what moves by itself (Theme.still)
    Binding { target: Theme; property: "still"; value: app.still }
    LabProbe {
        id: probe; window: app; on: app.lab
        stateOf: function () {
            function id(x) { return x ? x.id || x.name || "?" : null }
            return { layer: app.layer, row: home.row, dayOpen: home.dayOpen, scrolled: home.scrolled,
                     queries: catalog.queries(),            // what the data thread's cache holds and fetched (Catalog.queries)
                     pictures: catalog.pictures(),          // and the picture loader: where each picture came from, and how long it took
                     season: { asked: catalog.seasonAsked, shown: catalog.seasonName },
                     focusItem: id(app.focusItem), displayItem: id(app.displayItem), held: id(app.held ? app.held.item : null),
                     video: app.playTarget ? app.playTarget.id : "", trail: app.trail.map(function (t) { return t.layer }).join(">"),
                     info: { item: id(info.item), m: id(info.m), pending: id(info.pending), fadeIn: info.fadeIn, away: info.away,
                             visible: info.visible, opacity: info.opacity, y: info.y, busy: info.busy },
                     playLog: app.playLog, subs: player.active ? player.subtitleInfo() : "",
                     playMenu: app.playMenu, menuCard: app.playMenu && app.menuEpisode ? app.menuEpisode.id : "",
                     menuEntries: app.playMenu ? app.menuEntries.map(function (e) { return e.label }).join(" | ") : "",
                     stage: streams.stage, picks: streams.picksStatus,
                     streamQueries: streams.queries(),      // the same for a play: the list, the decision and the link (Streams.queries)
                     art: { loads: ArtCache.loads, reloads: ArtCache.reloads, heldMb: Math.round(ArtCache.held / 1048576) },
                     account: { signedIn: account.signedIn, link: account.link.state || "", code: account.link.code || "", menu: app.profileOpen },
                     tab: app.tab, browse: { what: browse.what, row: browse.row, rows: browse.page.count || 0, loading: !!browse.page.loading },
                     redraws: Remote.tallies, watching: catalog.continueWatching.slice(0, 8).map(function (i) { return i.id + " " + i.episode + " " + (i.video || "-") + " " + i.progress }), resume: showPage.resumeLabel, header: showPage.headerState(), hero: hero.labState(),
                     search: { text: searchBar.text, kind: search.kind, zone: searchBar.zone, cursor: searchBar.kindBar.cursor, row: search.row, found: search.found, counts: app.searchKinds.map(function (k) { return search.count(k[1]) }).join(","), shownLag: app.shownLag },
                     library: { item: app.libraryItem ? app.libraryItem.id : "", "in": !!app.libraryItem && account.inLibrary(app.libraryItem.id), watched: !!app.libraryItem && account.watched(app.libraryItem.id), reported: app.reported, stale: app.watchingStale },
                     page: { season: showPage.shownSeason, episode: showPage.focusedEp ? showPage.focusedEp.id : "", zone: showPage.zone },
                     player: { playing: player.playing, paused: player.paused, failure: player.failure, position: player.position, duration: player.duration, seen: player.seen } };
        }
        onAutopop: if (app.layer === "menu") app.layer = "home"; else app.openMenu()
        onOpenMenu: app.openMenu()
        onOpenStreams: if (app.focusItem) app.openStreams(null)      // (on a title: with the cursor off the cards there is none to open)
        onSearch: { app.tab = 5; app.layer = "tabs"; searchBar.text = text; search.enter() }      // typed, and Enter: on to what is found
        onVariantChanged: {
            if (variant.signIn && account.ready && !account.signedIn) account.signInWith(variant.signIn[0], variant.signIn[1]);   // lab: a tour can't approve a code
            if (variant.signOut && account.signedIn) account.signOut();
            // lab: { "queryFault": ["search", 3000, false] } makes the queries with that in their key 3 s slower (true: fail)
            if (variant.queryFault) catalog.fault(variant.queryFault[0], variant.queryFault[1] || 0, !!variant.queryFault[2]);
            // lab: { "forgetPictures": true } empties the picture loader's disk cache, to see and time first views again
            if (variant.forgetPictures) catalog.forgetPictures();
            // lab: { "tunePictures": [1, 2] }: one picture decoded at a time, two coming in on the side at once
            if (variant.tunePictures) catalog.tunePictures(variant.tunePictures[0], variant.tunePictures[1]);
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
            opacity: app.watching || app.layer === "signin" ? 0 : 1      // holds: the scene keeps its screens under the video
            // gone, not just transparent, under the video: its backdrop's slow zoom and the calendar's light
            // stop, so nothing redraws over the film
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 500 } }

            Backdrop {
                id: hero
                width: parent.width; height: parent.height
                // an anime franchise's page wears the backdrop of the entry it's on (ShowScreen.backdrop)
                target: app.layer === "show" && showPage.backdrop ? showPage.backdrop : app.backdropOf(app.pageItem)
                // parallax: the backdrop drifts a little against moves along a row
                pan: app.onHome && (home.row === 0 || home.dayOpen) ? Math.min(8, home.row === 0 ? home.column : home.dayColumn) * 5 : 0
                Behavior on pan { NumberAnimation { duration: 700; easing.type: Theme.ease } }
                onCrossfadeStarted: { Remote.stir(); probe.act("hero crossfade") }   // a crossfade is movement too
                covered: backdropFrost.covering
            }
            // the backdrop frosts on Home below the first row, where the info has stepped aside and the art
            // is only a background
            Frost {
                id: backdropFrost
                anchors.fill: parent
                source: hero
                readonly property bool wanted: (app.onHome && (app.scrolled || app.bare) && !home.dayOpen) || app.layer === "streams" || app.layer === "player"
                // On its way out its blur stays as it is: a backdrop still crossfading under it as a page
                // opened had it blurred again every frame of the fade (five passes more), and the page opened
                // at 30 fps, six or seven late frames.
                readonly property bool leaving: !wanted && opacity > 0.01
                frozen: true; sourceBusy: !leaving && hero.settling; sourceMoving: wanted && hero.fading
                // The filter bars of a grid tab are glass made of this blur, also over a clear backdrop: left
                // alone there, it went stale and the bars wore a blur of whatever was up when it last showed.
                // (Not every frame of a crossfade for them: 20 a second while the backdrop settles is plenty.)
                needed: app.onHome && (app.animeTab || app.browseTab)
                onWantedChanged: if (wanted) refresh()      // back before it had gone: of the backdrop as it is now
                // fully in, it hides the backdrop: drawing it under an opaque frost was a wasted full-screen pass
                hideCovered: true
                opacity: wanted ? 1 : (app.warming ? 0.003 : 0)      // holds: a blur of what is under it: nothing of its own
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
                // Home's selection; on the title page, the title in hand. Under a show page it is away, and
                // keeps what it showed (the page has its own header)
                item: (app.scrolled || app.bare) && app.onHome && !home.dayOpen ? null : app.layer === "title" && app.held ? app.held.item : app.displayItem
                // on the title page it moves down to sit just above the actions
                y: app.layer === "title" ? titlePage.actionsY - 40 - contentHeight : home.dayOpen ? 260 : (app.scrolled ? 90 : 150)
                // it only glides while on screen; hidden, it takes its new place at once and fades in there
                Behavior on y { enabled: info.visible; NumberAnimation { duration: 460; easing.type: Theme.ease } }
                // below Home's first row, and on the show page, the info steps aside
                property real away: ((app.scrolled || app.bare) && app.onHome && !home.dayOpen) || app.layer === "show" || app.layer === "streams" || app.layer === "player" ? 1 : 0
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
                onOpenShow: app.openFranchise(show)
                extras: app.libraryButtons
                onAction: app.libraryAct(app.libraryItem, index)
                active: app.layer === "show"
                source: hero
                onZoneChanged: { probe.act("show " + ["actions", "seasons", "episodes"][zone]); probe.captures() }
                onEntryIndexChanged: if (active) { probe.act("show entry"); probe.captures() }      // (a page built ahead sets its entry too: that is no move of anyone's)
            }
            TitleScreen {
                id: titlePage
                focus: app.layer === "title" && !app.playMenu
                onPlay: app.playAi(null)
                onPlayHeld: app.openPlayMenu(null, rect)
                extras: app.libraryButtons
                onAction: app.libraryAct(app.libraryItem, index)
                active: app.layer === "title"
            }
            HomeScreen {
                id: home
                width: parent.width; height: parent.height
                focus: app.layer === "home" && app.tab === 0 && !app.playMenu
                shown: app.onHome && app.tab === 0
                continueWatching: catalog.continueWatching
                catalog: catalog
                glassSource: backdropFrost
                today: app.today
                onActivated: app.open()
                onHeld: app.openMenu()
                onReleaseHeld: app.openReleaseMenu(entry, rect)
                onExitTop: app.layer = "tabs"
                onColumnChanged: probe.act("row move")
                onRowChanged: probe.act("row change")
            }
            AnimeScreen {
                id: anime
                width: parent.width; height: parent.height
                focus: app.layer === "home" && app.animeTab && !app.playMenu
                shown: app.onHome && app.animeTab
                catalog: catalog
                watched: account.watchedTitles
                glassSource: backdropFrost
                shownItem: app.displayItem
                onExitTop: app.layer = "tabs"
                onRowChanged: probe.act("anime row")
                onMenuChanged: probe.captures()            // lab: captures follow its lists, and a season on its way
                onSeasonLoadingChanged: probe.captures()
                // a show from the chart opens once its franchise is in (Catalog.loadFranchise)
                onActivated: app.open()
                onHeld: app.openTitleMenu(item, rect)
                onSaid: app.say(text)
            }
            BrowseScreen {
                id: browse
                width: parent.width; height: parent.height
                focus: app.layer === "home" && app.browseTab && !app.playMenu
                shown: app.onHome && app.browseTab
                account: account
                what: app.browsed
                glassSource: backdropFrost
                onExitTop: app.layer = "tabs"
                onRowChanged: probe.act("browse row")
                onActivated: app.open()
                onHeld: app.openTitleMenu(item, rect)
            }
            SearchScreen {
                id: search
                width: parent.width; height: parent.height
                focus: app.layer === "home" && app.searchTab && !app.playMenu
                shown: app.onHome && app.searchTab
                catalog: catalog
                watched: account.watchedTitles
                query: searchBar.text
                kind: catalog.searchKind
                onExitTop: { searchBar.zone = 1; app.layer = "tabs" }      // up from the results: onto the kinds, which change what they are
                onEntered: app.layer = "home"
                onRowChanged: probe.act("search row")
                onActivated: app.open()
                onHeld: app.openTitleMenu(item, rect)
            }
        }

        // quick actions frost and dim everything except the focused card; the scene is captured once
        // when the menu opens, and again only while the backdrop or info is still changing
        Frost {
            anchors.fill: parent
            source: scene
            darken: 0.55
            readonly property bool wanted: app.layer === "menu" || app.playMenu
            // It follows the scene only while a menu is up. Warming at launch, nobody sees it: following
            // the backdrop and the title coming in then was a capture of the whole screen twenty times a
            // second through the first second, and frames of the launch came late for it (the search
            // tour, which opens the search as the app starts, had 12, 6 and 10 late against 3, 3 and 7
            // once the title's panel stayed busy until its chips were in).
            frozen: true; sourceBusy: wanted && (hero.busy || info.busy)
            onWantedChanged: if (wanted) refresh()      // of the scene as it is when the menu opens
            // around the held card, or the held Play button or episode
            hole: app.playMenu ? Qt.rect(app.menuAnchor.x - 14, app.menuAnchor.y - 14, app.menuAnchor.width + 28, app.menuAnchor.height + 28) : home.focusRect
            opacity: wanted ? 1 : (app.warming ? 0.003 : 0)      // holds: a blur of what is under it: nothing of its own
            Behavior on opacity { NumberAnimation { duration: 320; easing.type: Easing.InOutQuad } }
        }
        SegmentedBar {
            id: tabs
            focus: app.layer === "tabs" && !app.searchTab
            source: scene
            // Its blur is taken every frame, five small passes: taken twice a second instead (the backdrop
            // under it only drifts), each capture was a 14 to 16 ms frame on its own and often a late one,
            // where the steady chain costs about 2 ms of every frame.
            // The search at the left end, then the tabs: Left from Home reaches it, and Right from the
            // Library goes on to the account at the right edge of the screen.
            model: [{ icon: "search" }, "Home", "Anime", "Movies", "Series", "Library"]
            function placeOf(tab) { return tab === 5 ? 0 : tab + 1 }
            currentIndex: 1
            // the tab bar belongs to the top of Home; pages and the calendar move it away
            readonly property bool shown: app.onHome && !app.scrolled
            shadow: shown ? 0.8 : 0
            x: (parent.width - width) / 2; y: shown ? 44 : -100
            opacity: app.searchTab ? 0 : app.layer === "menu" || app.playMenu ? 0.3 : 1      // holds: only dims (or makes way for the search field); its tabs do not change
            Behavior on y { NumberAnimation { duration: Theme.slow; easing.type: Theme.ease } }
            Behavior on opacity { NumberAnimation { duration: 300 } }
            onCurrentIndexChanged: { app.tab = currentIndex === 0 ? 5 : currentIndex - 1; probe.act("tabs") }
        }
        // The search tab opens into this, in the tab bar's place: the field and, at its left, the kinds
        // of title (SearchBar). Reaching the tab gives the field the remote and the TV's keyboard comes
        // up. The tabs are to its right, where they were walked from: Right at the end of the text goes
        // back to them, Left at its start onto the kinds, Down to what was found.
        SearchBar {
            id: searchBar
            width: parent.width; y: tabs.y
            open: app.searchTab && tabs.shown
            focus: app.layer === "tabs" && app.searchTab
            opacity: app.layer === "menu" || app.playMenu ? 0.3 : 1      // holds: only dims, as the tab bar does under a menu
            Behavior on opacity { NumberAnimation { duration: 300 } }
            source: scene
            iconX: tabs.x
            // a kind the search found nothing of is dim
            kinds: app.searchKinds.map(function (k) { return { label: k[0], faint: search.found.length > 1 && !search.count(k[1]) } })
            kind: Math.max(0, app.searchKinds.map(function (k) { return k[1] }).indexOf(catalog.searchKind))
            onChosen: { catalog.searchKind = app.searchKinds[index][1]; probe.act("search kind"); probe.captures() }
            onZoneChanged: { probe.act("search bar"); probe.captures() }
            Connections { target: searchBar.kindBar; onCursorChanged: { probe.act("search bar"); probe.captures() } }
            onExitRight: app.tab = 0
            Keys.onDownPressed: search.enter()
            Keys.onUpPressed: {}
            onAccepted: search.enter()                      // Enter on the keyboard: on to what was found
            onDismissed: text = ""                          // Back on the keyboard: it closes, and the bar is cleared
        }
        // The account, at the top right on the tab bar's line: Right from the Library's tab reaches it, OK
        // opens its menu, which hangs from its right edge. It comes and goes with the tab bar.
        FocusScope {
            id: profile
            x: parent.width - Theme.margin - width; y: tabs.y + (tabs.height - height) / 2
            width: picture.width; height: picture.height
            focus: app.layer === "profile" && !app.profileOpen
            opacity: app.layer === "menu" || app.playMenu ? 0.3 : 1      // holds: only dims; the picture does not change
            Behavior on opacity { NumberAnimation { duration: 300 } }
            Avatar { id: picture; source: account.avatar; focused: app.layer === "profile" }
            OkPress { id: profileOk; onTapped: app.profileOpen = true }
            Keys.forwardTo: [profileOk]
            Keys.onLeftPressed: app.layer = "tabs"
            Keys.onRightPressed: {}                         // (the end of the line)
            Keys.onDownPressed: app.layer = "home"
        }
        DropMenu {
            width: 620                                      // room for an address
            x: profile.x + profile.width - width; y: profile.y + profile.height + 18
            fromRight: true
            open: app.profileOpen
            model: [{ label: "Log out", detail: account.email }]
            onTriggered: { app.profileOpen = false; account.signOut() }
        }
        SignInScreen { anchors.fill: parent; active: app.layer === "signin"; account: account }
        Letters { }
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
            // the row is the show page's, whenever what plays is in the show in hand (an episode, a film, a
            // special); Related is left off, there's nothing to play in it
            readonly property bool inShow: !!app.playingAt && showPage.show === app.held.show
            episodes: inShow ? showPage.episodes : []
            row: !inShow ? ({}) : showPage.row.next && showPage.row.next.kind === "related" ? ({ cards: showPage.row.cards, prev: showPage.row.prev }) : showPage.row
            posterRow: inShow && showPage.posterRow
            rowLabel: inShow ? showPage.seasonName(showPage.shownSeason) : ""
            onTurnSeason: showPage.place({ s: key, e: 0 })
            onOpeningEpisodes: { var at = Episodes.find(showPage.show, episodeId); if (at && at.s !== showPage.shownSeason) showPage.place(at) }
            episodeId: app.playTarget ? app.playTarget.id : ""
            stillArt: app.playTarget ? app.episodeArt(app.playTarget.id) : ""
            videoId: app.playTarget ? app.playTarget.id : ""
            imdbEpisode: app.playTarget ? app.imdbEpisode(app.playTarget.id) : ""
            // inside the player, an episode change hands off: the picture fades into the episode's still
            // the episode after this one (Up next, and fetched ahead), into the next season
            nextEpisode: app.playingAt ? Episodes.after(app.held.show, app.playTarget.id, app.today) : null
            onPlayEpisode: {
                player.beginHandoff(episode.thumb, episode.type === "movie" ? "" : Episodes.chip(episode.episode), episode.title || "");
                // the row below the player follows into another season
                var at = Episodes.find(app.held.show, episode.id);
                if (at) showPage.place(at);
                app.playAi(showPage.target(app.held.show, at ? at.s : showPage.shownSeason, episode));
            }
            // once an episode plays, the next one's streams are fetched ahead (as stremio-core does)
            onPlayingChanged: if (playing && nextEpisode) streams.prefetch(nextEpisode.type || "series", nextEpisode.id)
            // a stream that fails before its first frame, or whose file isn't one to watch: the next
            // candidate plays instead (Streams.leaveOut)
            function next(why, forGood) {
                if (!stream || !streams.ownPick()) return;
                var url = stream.url;
                // (first: the old stream is cleared before the next is asked for. A lab `playId` has no label.)
                prepare(app.playTarget ? app.lookFor(app.playTarget.id) : null, app.playTarget ? app.playTarget.label || "" : "");
                streams.leaveOut(url, why, forGood);
            }
            onFailureChanged: if (failure && startMs < 0) next("Didn't play", false)
            onUnsuitable: next(why, certain)
            onFinished: app.leavePlayer()
            onZoneChanged: probe.captures()            // lab: screen captures follow the overlay too
            onMenuLevelChanged: probe.captures()
            onFavoriteMenuChanged: probe.captures()
            onUpNextModeChanged: probe.captures()
            // another stream of the same video, from where it is now
            onSwitchStream: { app.playTarget.resumeMs = player.position; streams.playRow(row) }
            // anime by its Kitsu id; everything else keeps its own track choices
            group: probe.variant.playGroup || (streams.anime ? "anime" : "other")       // lab: the play list's clips as anime
            focus: app.layer === "player"
            active: app.layer === "player"
        }
        QuickMenu {
            id: menu
            focus: app.layer === "menu"
            open: app.layer === "menu"
            source: scene
            x: Theme.margin + home.focusCardWidth * 1.1 + 44
            y: Math.min(home.focusRect.y + 10, Theme.screenHeight - height - 60)
            // The two ways to play, as every menu of something that plays has them; the library's two, as
            // on a page; the last takes the title off Continue Watching (the panel is as wide as that
            // label needs)
            width: 544
            actions: app.playEntries.concat(app.libraryEntries(app.menuCard), [{ label: "Remove from Continue Watching", icon: "close" }])
            onTriggered: {
                if (actionIndex === 0) { app.playAi(null); return }
                if (actionIndex === 1) { app.openStreams(null); return }
                if (actionIndex < 4) app.libraryAct(app.menuCard, actionIndex - 2); else if (app.menuCard) account.stopWatching(app.menuCard.id);
                app.layer = "home";
            }
        }
        QuickMenu {
            id: playOptions
            focus: app.playMenu
            open: app.playMenu
            source: scene
            actions: app.menuEntries
            // beside the card: on its right, or on its left where the right has no room (a grid's last columns)
            fromRight: app.menuAnchor.x + app.menuAnchor.width + 44 + width > Theme.screenWidth - Theme.margin
            x: fromRight ? app.menuAnchor.x - 44 - width : app.menuAnchor.x + app.menuAnchor.width + 44
            y: Math.min(app.menuAnchor.y, Theme.screenHeight - height - 60)
            onTriggered: app.menuAct(actionIndex)
        }
        Fade {
            anchors.horizontalCenter: parent.horizontalCenter; y: Theme.screenHeight - 120
            value: app.notice || (app.onHome && app.animeTab && anime.seasonLoading ? "Loading " + catalog.seasonAsked : "")
            Chip { kind: "solid"; size: 24; text: parent.current || "" }
        }

        Keys.onPressed: {
            if (Remote.isBack(event.key) && app.profileOpen) { event.accepted = true; app.profileOpen = false }
            else if (Remote.isBack(event.key) && app.playMenu) { event.accepted = true; app.playMenu = false }
            else if (Remote.isBack(event.key) && app.layer === "player") { event.accepted = true; app.leavePlayer() }
            else if (Remote.isBack(event.key) && app.layer === "streams") { event.accepted = true; streams.cancel(); app.back() }
            else if (Remote.isBack(event.key) && app.layer === "signin") event.accepted = true                       // nowhere to go back to: signed out, the app is this screen
            // Back in the search bar: what is typed goes first, and from an empty bar it leaves the search
            else if (Remote.isBack(event.key) && app.searchTab && app.layer === "tabs") { event.accepted = true; if (searchBar.text) searchBar.text = ""; else { app.tab = 0; app.layer = "home" } }
            else if (Remote.isBack(event.key) && app.onHome && app.layer !== "home") { event.accepted = true; app.layer = "home" }
            else if (Remote.isBack(event.key) && app.layer !== "home") { event.accepted = true; app.back() }
            else if (event.key === Qt.Key_Down && app.layer === "tabs") { event.accepted = true; app.layer = "home" }
            else if (event.key === Qt.Key_Right && app.layer === "tabs") { event.accepted = true; app.layer = "profile" }     // past the last tab: the account
            else if (event.key === Qt.Key_Left && app.layer === "tabs") event.accepted = true                               // (nothing left of the search)
        }
    }

    Component.onCompleted: {
        // Back reaches the app only with this window property; without it webOS opens the exit menu
        tools.setWindowProperty(app, "_WEBOS_ACCESS_POLICY_KEYS_BACK", "true");
        tools.watchKeys(app);
        requestActivate();
    }
}
