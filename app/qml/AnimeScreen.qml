// The Anime tab: a season as AniChart charts it. Under the focused show's info (App's HeroInfo) and
// its next episode's countdown sit the controls: the season (its name is the control: it drops the list
// of seasons), the view (the chart, or the week's schedule by day and time), a genre, the format and
// the order. A season picked is fetched live and shown once it is in whole: until then its name is in
// the title and the season on screen stays, dimmed and out of reach. Below them the shows: a grid of covers, each counting down
// to its next episode, or a row per day with air times. Moving into the rows lifts the controls into the
// tab bar's place, as the calendar's months do, and the info steps aside.
//
// The season comes from Catalog (seasonChart, seasonSchedule), filtered and sorted in C++; a change of
// control asks again once the selection has settled. The rows are a fixed pool of strips handed new
// rows as the list moves, as CardStrip does with cards, so a long chart never builds more than a screen.
import QtQuick 2.12
import Seimio.UI 1.0
import "Episodes.js" as Episodes

FocusScope {
    id: anime
    property var catalog: null
    property var watched: ({})               // ids of the titles watched (Account.watchedTitles): the chart's posters wear their check by it
    property Item glassSource
    property bool shown: false
    property var shownItem: null             // the show App's info is on (the countdown follows it)
    property double now: Date.now() / 1000   // epoch seconds; previews fix it
    property bool live: true                 // previews turn the clock off

    // -1 the controls, 0.. the rows (CardGrid)
    property alias row: grid.row
    readonly property bool scrolled: grid.scrolled
    property string view: "chart"
    property string format: "all"
    property string sort: "popular"
    property string genre: ""
    readonly property string menu: listBar ? listBar.filter.key : ""       // the list that is open, by its control's key, or none
    // a season was picked and isn't in yet
    readonly property bool seasonLoading: !!catalog && catalog.seasonAsked !== catalog.seasonName
    // a season with nothing left to air has no week to lay out: the schedule is passed over
    property bool airs: true

    readonly property var views: [["Chart", "chart"], ["Schedule", "schedule"]]
    readonly property var formats: [["All formats", "all"], ["TV", "tv"], ["Movies", "movie"], ["ONA & OVA", "other"]]
    readonly property var sorts: [["Popular", "popular"], ["Top rated", "score"], ["Airing soon", "airing"], ["A–Z", "title"]]
    readonly property int perRow: 7

    // [{ title, date, items }]: the chart cut into rows, or the days that have episodes
    readonly property alias rows: grid.rows
    property int total: 0
    // the focused show; once opened, its Kitsu version (playable), which App's selection then follows
    readonly property var focusItem: { var raw = grid.focusItem; return raw && resolved[raw.id] ? resolved[raw.id] : raw }
    property var resolved: ({})
    function resolve(sourceId, item) { var r = Object.assign({}, resolved); r[sourceId] = item; resolved = r }
    signal said(string text)                 // a moment's word for the app to show (a season that didn't load)
    signal activated(var item)
    signal held(var item, rect rect)         // a long OK on a card: its menu goes beside `rect`
    signal exitTop()

    // asked while the tab is up, or once ahead while Home is idle (`warm`): building on the way in was
    // 18 ms of the key press, then the cards' bindings and decodes over the next frames. Never at launch:
    // its covers decoding then slowed Home.
    // the rows for the current view and filters, from Catalog
    function build() {
        var out = [];
        if (view === "chart") {
            var items = catalog.seasonChart(format, genre, sort, now);
            total = items.length;
            for (var i = 0; i < items.length; i += perRow) out.push({ title: "", date: "", schedule: false, items: items.slice(i, i + perRow) });
        } else {
            var days = catalog.seasonSchedule(format, genre, now);
            total = 0;
            for (var d = 0; d < days.length; d++) if (days[d].items.length) { days[d].schedule = true; out.push(days[d]); total += days[d].items.length }
        }
        return out;
    }
    // built ahead of its first show; true when it built rows (a chart with nothing in it has none, and
    // says so each time it's asked)
    function warm() {
        if (shown || rows.length || !catalog || !catalog.seasonReady) return false;
        var ahead = build();
        if (ahead.length) grid.show(ahead, view);
        return ahead.length > 0;
    }
    property bool stale: false                       // a season came in while the tab was away
    // on screen, the old rows fade out, the new ones take their place and rise in, as one piece, with
    // the view they're laid out for (CardGrid.show)
    function refresh() {
        if (!catalog || !catalog.seasonReady) return;
        if (!shown) { stale = rows.length > 0; return }
        stale = false;
        grid.show(build(), view);
    }
    Connections {
        target: anime.catalog
        // another season: its own genres, from its top, and the chart if nothing in it airs any more
        onSeasonLoaded: {
            if (anime.genre && anime.catalog.seasonGenres.indexOf(anime.genre) < 0) anime.genre = "";
            anime.airs = anime.catalog.seasonChart("all", "", "popular", anime.now).some(function (m) { return m.nextAt > anime.now });
            if (!anime.airs) anime.view = "chart";
            anime.row = -1;
            anime.refresh();
        }
        onSeasonFailed: anime.said("Couldn't load " + name)
    }
    onShownChanged: if (shown && (!rows.length || stale)) refresh()
    // a choice (OK on a bar) asks again, once for changes made together
    onViewChanged: Qt.callLater(anime.refresh)
    onFormatChanged: Qt.callLater(anime.refresh)
    onSortChanged: Qt.callLater(anime.refresh)
    onGenreChanged: Qt.callLater(anime.refresh)
    // The minute tick: countdowns move on. Unlike a choice it doesn't fade the rows or move anyone's place:
    // only rows whose shows or countdowns changed are replaced, in place, and the others keep their very
    // object, so their cards aren't touched (a full refresh a minute flashed the page and reloaded rows).
    Timer { interval: 60000; running: anime.live && anime.shown; repeat: true; onTriggered: anime.tick() }
    function tick() {
        now = Date.now() / 1000;
        if (!catalog || !catalog.seasonReady || !rows.length || grid.layout !== view || grid.swapping) return;
        var out = build();
        grid.replace(out.map(function (n, i) { var o = rows[i]; return o && rowKey(o) === rowKey(n) ? o : n }));
    }
    function rowKey(r) { return r.title + "|" + r.date + "|" + r.items.map(function (x) { return x.id + "/" + x.label + "/" + x.episode }).join(",") }

    opacity: shown ? 1 : 0      // holds: its rows stay until the next refresh
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: 320 } }

    // The left edge's shade, mirrored into the top-right corner under the countdown, so it reads over any
    // art: full from the countdown's left edge to the screen's, down to below the day, then fading out
    // above the controls. It fades with the countdown.
    ShaderEffect {
        opacity: countdown.opacity
        visible: opacity > 0
        x: Theme.screenWidth - width; y: 0; width: 1100; height: 640
        fragmentShader: "
            varying highp vec2 qt_TexCoord0;
            uniform lowp float qt_Opacity;
            void main() {
                lowp float a = 0.62 * smoothstep(0.0, 0.5, qt_TexCoord0.x) * (1.0 - smoothstep(0.62, 1.0, qt_TexCoord0.y));
                gl_FragColor = vec4(0.0, 0.0, 0.0, a) * qt_Opacity;
            }"
    }

    // ---- the next episode, beside the info --------------------------------------------------------------
    Item {
        id: countdown
        // the show it counts down for, held while it fades out (it emptied as a show without a next
        // episode came in)
        readonly property bool itemAiring: !!(anime.shownItem && anime.shownItem.nextAt > anime.now)
        Latch { id: counted; value: anime.shownItem; live: anime.row <= 0 && countdown.itemAiring }
        readonly property var m: counted.current
        readonly property double at: m && m.nextAt ? m.nextAt : 0
        readonly property double remaining: Math.max(0, at - anime.now)
        readonly property bool airing: at > anime.now
        x: Theme.screenWidth - Theme.margin - width; y: 170
        width: 470; height: 230
        opacity: anime.row <= 0 && itemAiring ? 1 : 0      // holds: `counted` latches the show
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Theme.base } }
        // Each new show rises in, as the info does, and so does the countdown coming back on show. By the
        // show it counts for, never by `m` being written: the chart's show is handed over again as
        // another object once it is made playable, about a second after it is landed on, and the
        // countdown rose a second time (10 rises for 5 shows, counted on the TV; "countdown rise").
        property real rise: 0
        transform: Translate { y: countdown.rise }
        readonly property string countsFor: m ? (m.name || "") + "|" + at : ""
        onCountsForChanged: if (countsFor) Qt.callLater(countdown.risen)
        Connections { target: counted; onLiveChanged: if (counted.live) Qt.callLater(countdown.risen) }
        function risen() { Remote.tally("countdown rise"); riseIn.restart() }
        SequentialAnimation {
            id: riseIn
            NumberAnimation { target: countdown; property: "rise"; to: 14; duration: 1 }
            NumberAnimation { target: countdown; property: "rise"; to: 0; duration: 520; easing.type: Theme.ease }
        }
        function part(n, unit) { return { n: n, unit: unit } }
        readonly property var parts: {
            var s = Math.floor(remaining), d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), mi = Math.floor(s % 3600 / 60);
            return d ? [part(d, "d"), part(h, "h"), part(mi, "m")] : h ? [part(h, "h"), part(mi, "m")] : [part(Math.max(1, mi), "m")];
        }
        Column {
            id: countdownText
            anchors.right: parent.right
            spacing: 6
            Text {
                anchors.right: parent.right
                text: countdown.m ? Episodes.named(countdown.m.nextEpisode) : ""
                color: Theme.inkDim; font.family: Theme.face; font.pixelSize: 28; font.weight: Font.Medium
            }
            Row {
                anchors.right: parent.right
                spacing: 18
                Repeater {
                    model: countdown.parts.length
                    Row {
                        spacing: 4
                        Text {
                            text: countdown.parts[index].n
                            color: Theme.ink; font.family: Theme.face; font.pixelSize: 96; font.weight: Font.Bold
                        }
                        Text {
                            anchors.baseline: parent.children[0].baseline
                            text: countdown.parts[index].unit
                            color: Theme.inkDim; font.family: Theme.face; font.pixelSize: 40; font.weight: Font.Medium
                        }
                    }
                }
            }
            // the week since the last episode, filling towards the next, in the show's own colour
            Item {
                anchors.right: parent.right
                width: 420; height: 8
                Rectangle { anchors.fill: parent; radius: 4; color: "#33ffffff" }
                Rectangle {
                    height: parent.height; radius: 4
                    width: parent.width * Math.max(0.03, 1 - Math.min(1, countdown.remaining / 604800))
                    color: countdown.m && countdown.m.color ? countdown.m.color : Theme.ink
                    Behavior on width { NumberAnimation { duration: 600; easing.type: Theme.ease } }
                }
            }
            Text {
                anchors.right: parent.right
                topPadding: 8
                text: countdown.airing ? new Date(countdown.at * 1000).toLocaleString(Qt.locale(), "dddd HH:mm") : ""
                color: Theme.inkSoft; font.family: Theme.face; font.pixelSize: 28; font.weight: Font.Medium
            }
        }
    }

    // ---- the controls -------------------------------------------------------------------------------------
    // in the flow under the info, or in the tab bar's place once the rows are up
    FocusScope {
        id: controls
        z: 2                                     // the rows pass under it once it's at the top
        x: Theme.margin
        y: anime.scrolled ? 44 : 560
        width: bars.width; height: 64
        focus: anime.row < 0
        Behavior on y { NumberAnimation { duration: 480; easing.type: Theme.ease } }
        // The controls, in a row walked by one cursor: the season, the view, a genre, the format and the
        // order. One with three choices or fewer has them all in sight (the view); one with more shows
        // its choice and drops a list (FilterBar), and goes to another choice's width in a glide, the
        // bars after it with it.
        // A control that has no say is not in the row: the view for a season with nothing airing (the
        // ones after it close up, Fade's `gap`), and the order in the schedule, which is in air-time
        // order (the last in the row, so nothing moves for it).
        BarRow {
            id: bars
            focus: true
            spacing: 22
            bars: [seasonBar].concat(anime.airs ? [viewBar] : [], [genreBar, formatBar], anime.view === "schedule" ? [] : [sortBar])
            // the season's name, larger than the other bars' labels: the page's title, and the way to
            // another. (Not a FilterBar, nor the genres': each is a list to drop however few it holds,
            // and says the season asked for, or "All genres", before its list is in.)
            SegmentedBar {
                id: seasonBar; selectOnOk: true
                readonly property var filter: anime.seasonFilter
                source: anime.glassSource; preblurred: true
                sx: controls.x + x; sy: anime.y + controls.y + y
                barHeight: 64; fontSize: 27; segmentPad: 38; shadow: anime.scrolled ? 0.8 : 0
                model: [{ label: anime.catalog ? anime.catalog.seasonAsked : "", trailing: "chevrons" }]
                onTriggered: anime.openList(seasonBar)
            }
            Fade {
                id: viewPlace; value: anime.airs; gap: bars.spacing; duration: Theme.slow
                FilterBar {
                    id: viewBar; filter: anime.fixedFilter("view", anime.views)
                    source: anime.glassSource; preblurred: true
                    sx: controls.x + viewPlace.x; sy: anime.y + controls.y + viewPlace.y
                    barHeight: 64; fontSize: 22; segmentPad: 38; shadow: anime.scrolled ? 0.8 : 0
                    onChosen: anime.pick("view", option)
                }
            }
            SegmentedBar {
                id: genreBar; selectOnOk: true
                readonly property var filter: anime.genreFilter
                source: anime.glassSource; preblurred: true
                sx: controls.x + x; sy: anime.y + controls.y + y
                barHeight: 64; fontSize: 22; segmentPad: 38; shadow: anime.scrolled ? 0.8 : 0
                model: [{ label: anime.genre || "All genres", trailing: "chevrons" }]
                onTriggered: anime.openList(genreBar)
            }
            FilterBar {
                id: formatBar; filter: anime.fixedFilter("format", anime.formats)
                source: anime.glassSource; preblurred: true
                sx: controls.x + x; sy: anime.y + controls.y + y
                barHeight: 64; fontSize: 22; segmentPad: 38; shadow: anime.scrolled ? 0.8 : 0
                onDropped: anime.openList(formatBar)
            }
            Fade {
                id: sortPlace; value: anime.view !== "schedule"
                FilterBar {
                    id: sortBar; filter: anime.fixedFilter("sort", anime.sorts)
                    source: anime.glassSource; preblurred: true
                    sx: controls.x + sortPlace.x; sy: anime.y + controls.y + sortPlace.y
                    barHeight: 64; fontSize: 22; segmentPad: 38; shadow: anime.scrolled ? 0.8 : 0
                    onDropped: anime.openList(sortBar)
                }
            }
        }
        Keys.onUpPressed: anime.exitTop()
        Keys.onDownPressed: anime.toTitles()
    }
    // from the controls onto the titles (Down, and App's Back from the tab bar): not while another season
    // is on its way, when the rows are still the season before's
    function toTitles() { if (rows.length && !seasonLoading) row = 0 }

    // ---- the rows --------------------------------------------------------------------------------------------
    CardGrid {
        id: grid
        width: anime.width; height: anime.height
        focus: anime.row >= 0
        held: anime.shown
        marks: anime.watched
        dim: anime.seasonLoading ? 0.3 : 1               // the season on screen while another is fetched: dimmed, and out of reach (see the controls' Down)
        onActivated: anime.activated(item)
        onCardHeld: anime.held(item, rect)
    }

    // What each control chooses from ({ key, options, current } for its bar; `details`, a line under each
    // option in its list), and what a choice does.
    readonly property var seasonFilter: {
        var all = catalog ? catalog.seasons : [], names = all.map(function (s) { return s.label });
        return { key: "season", options: names, details: all.map(function (s) { return s.detail || "" }), current: Math.max(0, names.indexOf(catalog ? catalog.seasonAsked : "")) };
    }
    readonly property var genreFilter: {
        var all = catalog ? catalog.seasonGenres : [];
        return { key: "genre", options: ["All genres"].concat(all), current: genre ? all.indexOf(genre) + 1 : 0 };
    }
    function fixedFilter(key, choices) {
        return { key: key, options: choices.map(function (c) { return c[0] }), current: Math.max(0, choices.map(function (c) { return c[1] }).indexOf(anime[key])) };
    }
    function pick(key, option) {
        if (key === "season") { var s = catalog.seasons[option]; catalog.showSeason(s.season, s.year) }
        else if (key === "genre") genre = option === 0 ? "" : catalog.seasonGenres[option - 1];
        else anime[key] = ({ view: views, format: formats, sort: sorts })[key][option][1];
    }
    // The list a control drops, by its bar and over the rows: above it while it sits under the info (the
    // rows fill the space under it), below once it's at the top. One at a time, starting on what's
    // chosen; closing gives the remote back to the bar it came from.
    property Item listBar: null
    function openList(bar) { options.currentIndex = bar.filter.current; listBar = bar }
    onListBarChanged: if (!listBar && row < 0) bars.forceActiveFocus()
    Latch { id: dropped; value: anime.listBar; live: !!anime.listBar }
    DropMenu {
        id: options
        z: 3
        open: !!anime.listBar
        readonly property Item bar: dropped.current || null
        up: !anime.scrolled
        x: bar ? controls.x + (bar.parent.gap !== undefined ? bar.parent.x : bar.x) : 0      // (a bar in a Fade is where its place is)
        y: up ? controls.y - height - 16 : controls.y + controls.height + 16
        maxRows: 5                                              // clear of the tab bar above
        model: bar ? bar.filter.options.map(function (o, i) { return { label: o, detail: bar.filter.details ? bar.filter.details[i] : "", checked: i === bar.filter.current } }) : []
        onTriggered: { var key = bar.filter.key; anime.listBar = null; anime.pick(key, rowIndex) }
    }

    Keys.onPressed: {
        if (!Remote.isBack(event.key)) return;
        if (listBar) { listBar = null; event.accepted = true }
        else if (row >= 0) { row = -1; event.accepted = true }
    }
}
