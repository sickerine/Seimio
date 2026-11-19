// The Library, the Movies or the Series tab: one of the lists Account browses (`what`: "library", "movie"
// or "series") as a grid of posters under its filters. Movies and Series have the focused title's facts
// and backdrop above (App's HeroInfo, as on the Anime tab); the Library is the grid alone, right under
// its filters.
// Each of the three tabs has a screen of its own, as Home and the Anime tab have, so one tab goes as the
// next comes whichever two they are. (The three were one screen that changed its list where it stood:
// its filters went, the next list was waited for with the rows of the last still up, then those went
// and the new ones came, under a title above that was changing too. Movies to Series hung and flashed
// where Home to Anime crossed over.)
// Account browses one list at a time, the one whose tab is up (`mine`). A screen that is not up keeps
// what it showed: its rows, and its filters as they stood (`kept`). It takes nothing meanwhile: a list
// that comes in for a tab already left is taken as the tab next comes up. (Taken out of sight, its first
// three rows of cards were made in one go, 37 ms of the GUI thread in the next tab's entrance.)
//
// The filters are the list's own (Account.browsing.filters), each a FilterBar. A choice asks the core for
// that list; the rows on screen stay until it is in. Near the end of the rows the next page is asked for
// and its rows are added.
import QtQuick 2.12
import Seimio.UI 1.0

FocusScope {
    id: browse
    property var account
    property Item glassSource
    property bool shown: false
    property string what: ""
    readonly property bool hero: what !== "library"
    property alias row: grid.row             // -1 the filters, 0.. the rows
    readonly property alias rows: grid.rows
    readonly property bool scrolled: grid.scrolled
    readonly property var focusItem: grid.focusItem
    signal activated(var item)
    signal held(var item, rect rect)         // a long OK on a card: its menu goes beside `rect`
    signal exitTop()

    readonly property var page: account ? account.browsing : ({})
    readonly property bool mine: page.what === what
    Latch { id: kept; value: browse.page.filters || []; live: browse.mine }
    readonly property var filters: kept.current || []
    // a filter's choice, once the list Account browses is this one (its tab just up, the filters are still
    // the ones kept: a choice made then would be made of the list before)
    function choose(key, option) { if (mine) account.choose(key, option) }
    onShownChanged: if (shown && account) { account.browse(what); take(true) }

    // The rows as they were built: the list they are of (its filters' choices), the ids of its titles in
    // the order the rows show them (`order`), and how many of those have their rows (`made`). Another list
    // is shown from the top. The same list with other titles changes where it is, and the page is never shown again
    // for it:
    //   - more titles after the ones built (a page more, the rest of this one): rows are added;
    //   - a title gone or added, here or on another device: the rows that hold other titles for it are
    //     made again, the others staying the objects they are. The cursor stays on its title, or in its
    //     place if that title is the one that went. One title gone from a list on screen, the cards
    //     after it slide over to close up (CardGrid.closeUp);
    //   - while the list is on screen its titles stay in the order they are in, whatever the list's is
    //     by now (one marked watched goes to the front of "last watched"): a title gone leaves its
    //     place, a new one joins at the end. The list's own order is taken when it next comes on. A
    //     list that shuffles under the cursor because of what was just done to one title reads as a
    //     refresh.
    // Three rows are made at a time, a frame apart (fifty titles at once was a 60 to 70 ms stall as a tab
    // first showed), and the rows under the cursor with the first of them: it is never on another title
    // while the rows before it are made.
    // the list Account has in hand, by its filters' choices (of the page itself: `filters` is a turn behind it)
    readonly property string listed: what + "|" + (page.filters || []).map(function (f) { return f.current }).join(",")
    property string built: ""
    property var order: []                   // the titles' ids in the order the rows show them, or are to
    property int made: 0                     // how many of them have their rows
    Connections { target: browse.account; onBrowsingChanged: browse.take() }
    Timer { id: rest; interval: 16; onTriggered: browse.take() }
    // `now`: the list is coming on screen, so its own order is taken
    function take(now) {
        if (!shown || !mine || page.loading && !page.count) return;
        var key = listed, ids = account.ids(), per = grid.perRow;
        var fresh = key !== built, want = ids;
        if (fresh) { order = []; made = 0 }
        else if (!now) {
            var has = {}, had = {};
            ids.forEach(function (id) { has[id] = true });
            order.forEach(function (id) { had[id] = true });
            want = order.filter(function (id) { return has[id] }).concat(ids.filter(function (id) { return !had[id] }));
        }
        var keep = 0;                                // how far the rows made are still what is wanted
        while (keep < made && keep < want.length && order[keep] === want[keep]) keep++;
        if (!fresh && keep === made && made === want.length) { order = want; return }
        var rows = fresh ? [] : grid.latest.slice(), gone = -1;
        // a row of the titles wanted in its place: the one there if it holds them already
        function fill(r) {
            var its = want.slice(r * per, r * per + per), row = rows[r];
            if (!row || row.items.map(function (i) { return i.id }).join() !== its.join()) rows[r] = { items: account.itemsOf(its) };
        }
        if (keep < made) {
            // one title gone and the rest as they were: its place, for closing up
            if (want.indexOf(order[keep]) < 0 && order.slice(keep + 1).join() === want.slice(keep).join()) gone = keep;
            var on = grid.row >= 0 && grid.focusItem ? want.indexOf(grid.focusItem.id) : -1;
            if (on >= 0) { grid.row = Math.floor(on / per); grid.column = on % per }
            for (var r = Math.max(0, grid.row); r < Math.max(0, grid.row) + 3 && r * per < want.length; r++) fill(r);
        }
        var from = keep - keep % per, to = Math.min(want.length, from + 3 * per);
        for (var i = from; i < to; i += per) fill(i / per);
        if (to === want.length) rows.length = Math.ceil(to / per);      // a shorter list than the rows were: the ones past its end go
        // under the info, or right under the filters: the rows take their place as they come in
        if (fresh) { grid.row = Math.min(grid.row, 0); grid.column = 0; grid.show(rows, "grid", hero ? 650 : 240) } else grid.replace(rows);
        if (gone >= 0) grid.closeUp(gone);
        built = key; order = want; made = to;
        if (to < want.length) rest.restart();
    }
    onRowChanged: if (mine && page.more && !page.loading && row >= grid.rows.length - 3) account.more()

    opacity: shown ? 1 : 0      // holds: its rows stay until another list is in
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: 320 } }
    // How much higher than a tab with a title above its rows this one rests: the Library, by the room the
    // title takes. App stands every grid tab's screen where the tab that is up rests (its `y`), so the
    // Library rises into place and sinks out of it with the tab it changes places with.
    readonly property int level: hero ? 0 : 560 - 169

    // ---- the filters ---------------------------------------------------------------------------------------
    // in the flow under the info (or under the tab bar, with no info), in the tab bar's place once the rows are up
    FocusScope {
        id: controls
        z: 2                                     // the rows pass under it once it's at the top
        x: Theme.margin
        y: browse.scrolled ? 44 : browse.hero ? 560 : 169      // (with no info above: midway between the tab bar and the cards, 61 px from each)
        width: bars.width; height: 64
        focus: browse.row < 0
        Behavior on y { NumberAnimation { duration: 480; easing.type: Theme.ease } }
        BarRow {
            id: bars
            focus: true
            spacing: 22
            bars: [barA, barB].slice(0, browse.filters.length)
            FilterBar {
                id: barA; filter: browse.filters[0] || null
                source: browse.glassSource; preblurred: true; sx: controls.x + x; sy: browse.y + controls.y + y
                barHeight: 64; fontSize: 22; segmentPad: 38; shadow: browse.scrolled ? 0.8 : 0
                onChosen: browse.choose(filter.key, option)
                onDropped: browse.openMenu(barA)
            }
            FilterBar {
                id: barB; filter: browse.filters[1] || null
                source: browse.glassSource; preblurred: true; sx: controls.x + x; sy: browse.y + controls.y + y
                barHeight: 64; fontSize: 22; segmentPad: 38; shadow: browse.scrolled ? 0.8 : 0
                onChosen: browse.choose(filter.key, option)
                onDropped: browse.openMenu(barB)
            }
        }
        Keys.onUpPressed: browse.exitTop()
        Keys.onDownPressed: if (grid.rows.length) browse.row = 0
    }
    CardGrid {
        id: grid
        width: browse.width; height: browse.height
        focus: browse.row >= 0
        held: browse.shown
        marks: browse.account ? browse.account.watchedTitles : ({})
        // another list is on its way: one chosen by a filter. (Not the one these rows are of, asked for
        // again as its tab comes up: its rows dimmed and came back each time the tab did.)
        dim: browse.mine && browse.page.loading && browse.listed !== browse.built ? 0.3 : 1
        onActivated: browse.activated(item)
        onCardHeld: browse.held(item, rect)
    }

    // the list a filter drops, by its bar; one at a time, starting on what's chosen
    property Item menuBar: null
    function openMenu(bar) { options.currentIndex = bar.filter.current; menuBar = bar }
    onMenuBarChanged: if (!menuBar && row < 0) bars.forceActiveFocus()
    Latch { id: dropped; value: browse.menuBar; live: !!browse.menuBar }
    DropMenu {
        id: options
        z: 3
        open: !!browse.menuBar
        readonly property Item bar: dropped.current || null
        up: browse.hero && !browse.scrolled
        x: bar ? controls.x + bar.x : 0
        y: up ? controls.y - height - 16 : controls.y + controls.height + 16
        maxRows: up ? 5 : 8
        model: bar && bar.filter ? bar.filter.options.map(function (o, i) { return { label: o, checked: i === bar.filter.current } }) : []
        onTriggered: { var f = bar.filter; browse.menuBar = null; browse.choose(f.key, rowIndex) }
    }

    Keys.onPressed: {
        if (!Remote.isBack(event.key)) return;
        if (menuBar) { menuBar = null; event.accepted = true }
        else if (row >= 0) { row = -1; event.accepted = true }
    }
}
