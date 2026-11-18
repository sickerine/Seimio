// The Library, Movies and Series tabs: what Account browses (`what`: "library", "movie" or "series") as a
// grid of posters under its filters. Movies and Series have the focused title's facts and backdrop above
// (App's HeroInfo, as on the Anime tab); the Library is the grid alone, right under its filters.
//
// The filters are the list's own (Account.browsing.filters): one with a few options is a row of segments,
// one with many is a bar that drops a list. A choice asks the core for that list; the rows on screen stay
// until it is in. Near the end of the rows the next page is asked for and its rows are added.
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
    readonly property var filters: mine ? page.filters || [] : []
    onShownChanged: if (shown && account) { account.browse(what); if (stale) take(true) }
    onWhatChanged: if (shown && account) account.browse(what)

    // The rows as they were built: the list they are of (its filters' choices) and the ids of the titles
    // in them, in the order they show (`builtIds`), as far as rows have been made. Another list is shown
    // from the top. The same list with other titles changes where it is, and the page is never shown again
    // for it:
    //   - more titles after the ones built (a page more, the rest of this one): rows are added;
    //   - a title gone or added, here or on another device: the rows that hold other titles for it are
    //     made again, the others staying the objects they are. The cursor stays on its title, or in its
    //     place if that title is the one that went. One title gone from a list on screen, the cards
    //     after it slide over to close up (CardGrid.closeUp);
    //   - while the list is on screen its titles stay in the order they are in, whatever the list's is
    //     by now (one marked watched goes to the front of "last watched"): a title gone leaves its
    //     place, a new one joins at the end. The list's own order is taken when it next comes on
    //     (`stale`). A list that shuffles under the cursor because of what was just done to one title
    //     reads as a refresh.
    // Three rows are made at a time, a frame apart (fifty titles at once was a 60 to 70 ms stall as a tab
    // first showed), and the rows under the cursor with the first of them: it is never on another title
    // while the rows before it are made.
    property string built: ""
    property var builtIds: []
    property bool stale: false
    Connections { target: browse.account; onBrowsingChanged: browse.take() }
    Timer { id: rest; interval: 16; onTriggered: browse.take() }
    // `now`: the list is coming on screen, so its own order is taken
    function take(now) {
        if (!mine || page.loading && !page.count) return;
        var key = what + "|" + filters.map(function (f) { return f.current }).join(","), ids = account.ids(), per = grid.perRow;
        var fresh = key !== built, want = ids;
        if (fresh) builtIds = [];
        else if (shown && !now) {
            var has = {}, had = {};
            ids.forEach(function (id) { has[id] = true });
            builtIds.forEach(function (id) { had[id] = true });
            want = builtIds.filter(function (id) { return has[id] }).concat(ids.filter(function (id) { return !had[id] }));
        }
        stale = want.join() !== ids.join();
        var keep = 0;                                // how far the rows are still what is wanted
        while (keep < builtIds.length && keep < want.length && builtIds[keep] === want[keep]) keep++;
        if (!fresh && keep === builtIds.length && keep === want.length) return;
        var rows = fresh ? [] : grid.latest.slice(), gone = -1;
        // a row of the titles wanted in its place: the one there if it holds them already
        function fill(r) {
            var its = want.slice(r * per, r * per + per), row = rows[r];
            if (!row || row.items.map(function (i) { return i.id }).join() !== its.join()) rows[r] = { items: account.itemsOf(its) };
        }
        if (keep < builtIds.length) {
            // one title gone and the rest as they were: its place, for closing up
            if (want.indexOf(builtIds[keep]) < 0 && builtIds.slice(keep + 1).join() === want.slice(keep, builtIds.length - 1).join()) gone = keep;
            var on = grid.row >= 0 && grid.focusItem ? want.indexOf(grid.focusItem.id) : -1;
            if (on >= 0) { grid.row = Math.floor(on / per); grid.column = on % per }
            for (var r = Math.max(0, grid.row); r < Math.max(0, grid.row) + 3 && r * per < want.length; r++) fill(r);
        }
        var from = keep - keep % per, to = Math.min(want.length, from + 3 * per);
        for (var i = from; i < to; i += per) fill(i / per);
        if (to === want.length) rows.length = Math.ceil(to / per);      // a shorter list than the rows were: the ones past its end go
        // under the info, or right under the filters: the rows take their place as they come in
        if (fresh) { grid.row = Math.min(grid.row, 0); grid.column = 0; grid.show(rows, "grid", hero ? 650 : 240) } else grid.replace(rows);
        if (gone >= 0 && shown) grid.closeUp(gone);
        built = key; builtIds = want.slice(0, to);
        if (to < want.length) rest.restart();
    }
    onRowChanged: if (mine && page.more && !page.loading && row >= grid.rows.length - 3) account.more()

    opacity: shown ? 1 : 0      // holds: its rows stay until another list is in
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: 320 } }

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
                source: browse.glassSource; preblurred: true; sx: controls.x + x; sy: controls.y + y
                barHeight: 64; fontSize: 22; segmentPad: 38; shadow: browse.scrolled ? 0.8 : 0
                onChosen: browse.account.choose(filter.key, option)
                onDropped: browse.openMenu(barA)
            }
            FilterBar {
                id: barB; filter: browse.filters[1] || null
                source: browse.glassSource; preblurred: true; sx: controls.x + x; sy: controls.y + y
                barHeight: 64; fontSize: 22; segmentPad: 38; shadow: browse.scrolled ? 0.8 : 0
                onChosen: browse.account.choose(filter.key, option)
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
        dim: browse.mine && browse.page.loading ? 0.3 : 1      // another list is on its way
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
        onTriggered: { var f = bar.filter; browse.menuBar = null; browse.account.choose(f.key, rowIndex) }
    }

    Keys.onPressed: {
        if (!Remote.isBack(event.key)) return;
        if (menuBar) { menuBar = null; event.accepted = true }
        else if (row >= 0) { row = -1; event.accepted = true }
    }
}
