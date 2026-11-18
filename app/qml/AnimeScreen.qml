// The Anime tab: a season as AniChart charts it. Under the focused show's info (App's HeroInfo) and
// its next episode's countdown sit the controls: the season (its name is the control: it drops the list
// of seasons), the view (the chart, or the week's schedule by day and time), the format, the order, and
// a genre. A season picked is fetched live and shown once it is in whole: until then its name is in
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
    property Item glassSource
    property bool shown: false
    property var shownItem: null             // the show App's info is on (the countdown follows it)
    property double now: Date.now() / 1000   // epoch seconds; previews fix it
    property bool live: true                 // previews turn the clock off

    // -1 the controls, 0.. the rows
    property int row: -1
    property int column: 0
    readonly property bool scrolled: row > 0
    property string view: "chart"
    property string format: "all"
    property string sort: "popular"
    property string genre: ""
    property string menu: ""                 // the list that is open: "season", "genre" or none
    // a season was picked and isn't in yet
    readonly property bool seasonLoading: !!catalog && catalog.seasonAsked !== catalog.seasonName
    // a season with nothing left to air has no week to lay out: the schedule is passed over
    property bool airs: true

    readonly property var views: [["Chart", "chart"], ["Schedule", "schedule"]]
    readonly property var formats: [["All", "all"], ["TV", "tv"], ["Movies", "movie"], ["ONA & OVA", "other"]]
    readonly property var sorts: [["Popular", "popular"], ["Top rated", "score"], ["Airing soon", "airing"], ["A–Z", "title"]]
    readonly property int perRow: 7

    // [{ title, date, items }]: the chart cut into rows, or the days that have episodes
    property var rows: []
    property int total: 0
    // the focused show; once opened, its Kitsu version (playable), which App's selection then follows
    readonly property var focusItem: {
        var r = rows.length ? rows[Math.max(0, row)] || rows[0] : null, raw = r ? r.items[Math.min(restingColumn(Math.max(0, row)), r.items.length - 1)] || null : null;
        return raw && resolved[raw.id] ? resolved[raw.id] : raw;
    }
    property var resolved: ({})
    function resolve(sourceId, item) { var r = Object.assign({}, resolved); r[sourceId] = item; resolved = r }
    // a moment's word when a show can't open (not on Kitsu yet, its episodes didn't load)
    property string notice: ""
    function say(text) { notice = text; noticeTimer.restart() }
    Timer { id: noticeTimer; interval: 2600; onTriggered: anime.notice = "" }
    signal activated(var item)
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
    function warm() { if (!shown && !rows.length && catalog && catalog.seasonReady) { pending = build(); pendingView = view; apply() } }
    function refresh() {
        if (!catalog || !catalog.seasonReady || !shown) return;
        var out = build();
        // on screen, the old rows fade out, the new ones take their place and rise in, as one piece, with
        // the view they're laid out for (cards keep the old shape until then)
        pending = out; pendingView = view;
        if (shown && rows.length) { swap.restart(); return }
        apply();
    }
    property var pending: null
    property string pendingView: "chart"
    property string rowsView: "chart"                // the view the rows on screen are laid out for
    // new rows reach the row slots a slot a frame, top first (`staggering`): handing every slot its
    // cards at once (28 cards resized and rebound) stalled ~90 ms; they arrive while the list fades in
    property bool staggering: false
    Timer { id: staggerEnd; interval: 120; onTriggered: anime.staggering = false }
    function apply() {
        staggering = rows.length > 0 || pending.length > 0; staggerEnd.restart();
        rowColumns = ({}); rows = pending; rowsView = pendingView; pending = null; if (row >= rows.length) row = rows.length - 1;
    }
    // where each row rests along itself: the chart's rows line up as a grid and share `column`; each of
    // the schedule's days slides on its own and keeps its own place (by row), starting at its first card
    property var rowColumns: ({})
    function restingColumn(rowIdx) { return rowsView === "schedule" ? (rowColumns[rowIdx] || 0) : column }
    function rememberColumn(rowIdx, i) { var c = Object.assign({}, rowColumns); c[rowIdx] = i; rowColumns = c }
    Connections {
        target: anime.catalog
        // another season: its own genres, from its top, and the chart if nothing in it airs any more
        onSeasonLoaded: {
            if (anime.genre && anime.catalog.seasonGenres.indexOf(anime.genre) < 0) anime.genre = "";
            anime.airs = anime.catalog.seasonChart("all", "", "popular", anime.now).some(function (m) { return m.nextAt > anime.now });
            if (!anime.airs) viewBar.currentIndex = 0;
            anime.row = -1;
            anime.refresh();
        }
        onSeasonFailed: anime.say("Couldn't load " + name)
    }
    onShownChanged: { if (shown && !rows.length) refresh(); holdCovers() }
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
        if (!catalog || !catalog.seasonReady || !rows.length || rowsView !== view || swap.running) return;
        var out = build();
        rows = out.map(function (n, i) { var o = rows[i]; return o && rowKey(o) === rowKey(n) ? o : n });
        if (row >= rows.length) row = rows.length - 1;
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
        // each new show rises in, as the info does
        property real rise: 0
        transform: Translate { y: countdown.rise }
        onMChanged: { riseIn.restart() }
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
        // one cursor across every option; OK picks (the schedule has no order, so its bar is passed over)
        BarRow {
            id: bars
            focus: true
            spacing: 22
            bars: [seasonBar].concat(anime.airs ? [viewBar] : [], [formatBar], anime.view === "schedule" ? [] : [sortBar], [genreBar])
            // the season's name, larger than the other bars' labels: the page's title, and the way to another
            SegmentedBar {
                id: seasonBar; selectOnOk: true
                source: anime.glassSource; preblurred: true
                sx: controls.x + x; sy: controls.y + y
                barHeight: 64; fontSize: 27; segmentPad: 38; shadow: anime.scrolled ? 0.8 : 0
                model: [{ label: anime.catalog ? anime.catalog.seasonAsked : "", trailing: "chevrons" }]
                onTriggered: anime.openMenu("season")
            }
            SegmentedBar {
                id: viewBar; selectOnOk: true
                opacity: anime.airs ? 1 : 0.3      // holds: only dims; its labels don't change
                Behavior on opacity { NumberAnimation { duration: Theme.base } }
                source: anime.glassSource; preblurred: true
                sx: controls.x + x; sy: controls.y + y
                barHeight: 64; fontSize: 22; segmentPad: 38; shadow: anime.scrolled ? 0.8 : 0
                model: anime.views.map(function (v) { return v[0] })
                onCurrentIndexChanged: anime.view = anime.views[currentIndex][1]
            }
            SegmentedBar {
                id: formatBar; selectOnOk: true
                source: anime.glassSource; preblurred: true
                sx: controls.x + x; sy: controls.y + y
                barHeight: 64; fontSize: 22; segmentPad: 38; shadow: anime.scrolled ? 0.8 : 0
                model: anime.formats.map(function (v) { return v[0] })
                onCurrentIndexChanged: anime.format = anime.formats[currentIndex][1]
            }
            SegmentedBar {
                id: sortBar; selectOnOk: true
                source: anime.glassSource; preblurred: true
                sx: controls.x + x; sy: controls.y + y
                barHeight: 64; fontSize: 22; segmentPad: 38; shadow: anime.scrolled ? 0.8 : 0
                model: anime.sorts.map(function (v) { return v[0] })
                // the schedule is in air-time order: the order has no say there
                opacity: anime.view === "schedule" ? 0.3 : 1      // holds: only dims; its labels don't change
                Behavior on opacity { NumberAnimation { duration: Theme.base } }
                onCurrentIndexChanged: anime.sort = anime.sorts[currentIndex][1]
            }
            // what's left of the width, so the genre control ends on the right margin whatever its name
            Item {
                width: Math.max(0, anime.contentWidth - seasonBar.width - viewBar.width - formatBar.width - sortBar.width - genreBar.width - 5 * bars.spacing)
                height: 1
            }
            SegmentedBar {
                id: genreBar; selectOnOk: true
                source: anime.glassSource; preblurred: true
                sx: controls.x + x; sy: controls.y + y
                barHeight: 64; fontSize: 22; segmentPad: 38; shadow: anime.scrolled ? 0.8 : 0
                model: [{ label: anime.genre || "All genres", trailing: "chevrons" }]   // it opens the genre list
                onTriggered: anime.openMenu("genre")
            }
        }
        Keys.onUpPressed: anime.exitTop()
        Keys.onDownPressed: if (anime.rows.length && !anime.seasonLoading) anime.row = 0
    }

    // ---- covers kept decoded -------------------------------------------------------------------------------
    // Every cover of the view is held decoded ahead (ArtCache.keep), as the cards decode it, so a row
    // scrolled to for the first time has its covers too: ~40 MB for the chart's covers, ~55 MB for the
    // schedule's stills, of ArtCache's budget.
    readonly property var covers: {
        var out = [];
        for (var i = 0; i < rows.length; i++) for (var j = 0; j < rows[i].items.length; j++) out.push(rows[i].items[j].art || "");
        return out;
    }
    // the cards: the chart's covers, the schedule's episode stills
    // The page spans the margins, as the countdown does: the chart's 7 covers and their gaps fill the width
    // exactly (204 px covers, 42 px gaps), and the genre control's right edge sits on the right margin.
    readonly property int contentWidth: Theme.screenWidth - 2 * Theme.margin
    readonly property size chartCard: Theme.posterCard
    readonly property int chartGap: (contentWidth - perRow * chartCard.width) / (perRow - 1)
    readonly property size scheduleCard: Theme.stillCard
    readonly property size coverSize: { var c = rowsView === "schedule" ? scheduleCard : chartCard; return Theme.cardDecodeSize(c.width, c.height) }
    // once the tab has been up: warmed ahead, only the rows on screen decode theirs
    function holdCovers() { if (shown) ArtCache.keep(covers, coverSize.width, coverSize.height) }
    onCoversChanged: holdCovers()

    // ---- the rows --------------------------------------------------------------------------------------------
    SequentialAnimation {
        id: swap
        NumberAnimation { target: list; property: "opacity"; to: 0; duration: 140; easing.type: Easing.InQuad }
        ScriptAction { script: { anime.apply(); list.rise = 28 } }
        ParallelAnimation {
            NumberAnimation { target: list; property: "opacity"; to: 1; duration: 320; easing.type: Theme.ease }
            NumberAnimation { target: list; property: "rise"; to: 0; duration: 420; easing.type: Theme.ease }
        }
    }
    Item {
        id: list
        property real rise: 0
        transform: Translate { y: list.rise }
        width: anime.width; height: anime.height
        // the season on screen while another is fetched: dimmed, and out of reach (see the controls' Down)
        property real dim: anime.seasonLoading ? 0.3 : 1
        Behavior on dim { NumberAnimation { duration: Theme.base } }
        layer.enabled: dim < 1                  // faded as one piece, only while it is
        layer.effect: ShaderEffect { property real dim: list.dim; fragmentShader: "varying highp vec2 qt_TexCoord0; uniform sampler2D source; uniform lowp float dim; uniform lowp float qt_Opacity; void main() { gl_FragColor = texture2D(source, qt_TexCoord0) * dim * qt_Opacity; }" }
        readonly property int stride: 430
        readonly property int rowTop: 650
        // once the controls have gone up, the focused row sits just under them with two more below it,
        // and the rows above have gone
        readonly property real scrollTarget: anime.row <= 0 ? 0 : rowTop + anime.row * stride - 160
        property real scrollY: scrollTarget
        Behavior on scrollY { NumberAnimation { id: scrolling; duration: 480; easing.type: Theme.ease } }
        readonly property int slots: 4
        readonly property int first: Math.max(0, Math.floor((scrollY - rowTop) / stride))
        Repeater {
            model: list.slots
            FocusScope {
                id: slot
                readonly property int idx: list.first + ((index - list.first) % list.slots + list.slots) % list.slots
                // the row this slot shows: at once when the slot is recycled while scrolling, a frame per
                // place down the screen when new rows arrive (anime.staggering); its layout comes with it
                readonly property var wanted: idx < anime.rows.length ? anime.rows[idx] : null
                property var r: null
                Component.onCompleted: r = wanted
                // recycled mid-scroll into a place that's hidden once the scroll ends (past the bottom, or
                // above the focused row, which fades out), it rebinds its cards after the scroll: 7 cards at
                // once cost 40-60 ms, a hitch in the slide
                readonly property bool shownAtRest: { var y = list.rowTop + idx * list.stride - list.scrollTarget; return y < anime.height && y + height > 0 && (anime.row <= 0 || idx >= anime.row) }
                onWantedChanged: {
                    if (anime.staggering) { take.interval = 16 * (1 + Math.max(0, idx - list.first)); take.restart() }
                    else if (scrolling.running && !shownAtRest) take.stop();          // taken when the scroll ends
                    else r = wanted;
                }
                Connections { target: scrolling; onRunningChanged: if (!scrolling.running && slot.r !== slot.wanted) slot.r = slot.wanted }
                // another press moved where the scroll ends and brought it on screen: it takes its row now
                // (waiting for the scroll to end left it empty, then snapping in, while presses kept coming)
                onShownAtRestChanged: if (shownAtRest && !take.running && r !== wanted) r = wanted
                Timer { id: take; onTriggered: slot.r = slot.wanted }
                readonly property bool schedule: !!(r && r.schedule)
                // a slot fully off screen isn't drawn (Qt draws what's off screen)
                visible: r !== null && y < anime.height && y + height > 0
                y: list.rowTop + idx * list.stride - list.scrollY
                // a slot handed another row (the pool recycles as the list scrolls) takes that row's place
                // along itself, not the place of the row it showed before
                function place() { strip.jumpTo(Math.max(0, Math.min(anime.restingColumn(idx), (strip.model || []).length - 1))) }
                width: anime.width; height: list.stride
                focus: anime.row === idx
                opacity: anime.row > 0 && idx < anime.row ? 0 : 1      // holds: the row's cards stay
                Behavior on opacity { NumberAnimation { duration: Theme.base } }
                Row {
                    x: Theme.margin
                    visible: slot.schedule
                    spacing: 16
                    Text { text: slot.r ? slot.r.title : ""; color: Theme.ink; font.family: Theme.face; font.pixelSize: 30; font.weight: Font.DemiBold }
                    Text { anchors.baseline: parent.children[0].baseline; text: slot.r ? slot.r.date : ""; color: Theme.inkDim; font.family: Theme.face; font.pixelSize: 24; font.weight: Font.Medium }
                }
                CardStrip {
                    id: strip
                    y: slot.schedule ? 108 : 54
                    width: anime.width
                    focus: true
                    model: slot.r ? slot.r.items : []
                    slides: slot.schedule
                    nextLabels: false
                    cardWidth: slot.schedule ? anime.scheduleCard.width : anime.chartCard.width
                    cardHeight: slot.schedule ? anime.scheduleCard.height : anime.chartCard.height
                    narrowest: anime.chartCard.width
                    spacing: slot.schedule ? 36 : anime.chartGap
                    showFocus: activeFocus
                    onCurrentIndexChanged: if (activeFocus) { if (slot.schedule) anime.rememberColumn(slot.idx, currentIndex); else anime.column = currentIndex }
                    onActivated: anime.activated(model[cardIndex])
                    onModelChanged: slot.place()
                }
                onActiveFocusChanged: if (activeFocus) place()
            }
        }
    }

    // The lists that drop from the controls, by their bar and over the rows: above it while it sits under
    // the info (the rows fill the space under it), below once it's at the top. One is open at a time
    // (`menu`), starting on what's chosen; closing gives the remote back to the bar it came from.
    function openMenu(which) {
        if (which === "season") seasons.currentIndex = Math.max(0, catalog.seasons.map(function (s) { return s.label }).indexOf(catalog.seasonAsked));
        else genres.currentIndex = genre ? catalog.seasonGenres.indexOf(genre) + 1 : 0;
        menu = which;
    }
    onMenuChanged: if (!menu && row < 0) bars.forceActiveFocus()
    DropMenu {
        id: seasons
        z: 3
        open: anime.menu === "season"
        up: !anime.scrolled
        x: controls.x + seasonBar.x
        y: up ? controls.y - height - 16 : controls.y + controls.height + 16
        maxRows: 5                                              // clear of the tab bar above
        model: (anime.catalog ? anime.catalog.seasons : []).map(function (s) { return { label: s.label, detail: s.detail, checked: s.label === anime.catalog.seasonAsked } })
        onTriggered: { var s = anime.catalog.seasons[rowIndex]; anime.menu = ""; anime.catalog.showSeason(s.season, s.year) }
    }
    DropMenu {
        id: genres
        z: 3
        open: anime.menu === "genre"
        up: !anime.scrolled; fromRight: true
        x: controls.x + genreBar.x + genreBar.width - width
        y: up ? controls.y - height - 16 : controls.y + controls.height + 16
        maxRows: 5
        model: [{ label: "All genres", checked: anime.genre === "" }].concat((anime.catalog ? anime.catalog.seasonGenres : []).map(function (g) { return { label: g, checked: anime.genre === g } }))
        onTriggered: { anime.genre = rowIndex === 0 ? "" : anime.catalog.seasonGenres[rowIndex - 1]; anime.menu = "" }
    }

    // a season on its way, or a moment's word
    Fade {
        z: 4
        anchors.horizontalCenter: parent.horizontalCenter; y: Theme.screenHeight - 120
        value: anime.seasonLoading ? "Loading " + anime.catalog.seasonAsked : anime.notice
        Chip { kind: "solid"; size: 24; text: parent.current || "" }
    }

    Keys.onUpPressed: if (row > 0) row--; else if (row === 0) row = -1
    Keys.onDownPressed: if (row < rows.length - 1) row++
    Keys.onPressed: {
        if (!Remote.isBack(event.key)) return;
        if (menu) { menu = ""; event.accepted = true }
        else if (row >= 0) { row = -1; event.accepted = true }
    }
}
