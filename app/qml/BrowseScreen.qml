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
    signal exitTop()

    readonly property var page: account ? account.browsing : ({})
    readonly property bool mine: page.what === what
    readonly property var filters: mine ? page.filters || [] : []
    onShownChanged: if (shown && account) account.browse(what)
    onWhatChanged: if (shown && account) account.browse(what)

    // The rows as they were built: the list they are of (its filters' choices), how many titles and which
    // (`stamp`). The same titles again change nothing; the same list with more after the ones built (a
    // page more, or the rest of this one) adds rows where they are; anything else (another list, a title
    // gone, another order) replaces them from the top. Three rows are built at a time, a frame apart:
    // fifty titles at once was a 60 to 70 ms stall as a tab first showed.
    property string built: ""
    property int builtCount: 0
    property var builtStamp
    property string builtLast: ""
    Connections { target: browse.account; onBrowsingChanged: browse.take() }
    Timer { id: rest; interval: 16; onTriggered: browse.take() }
    function take() {
        if (!mine || page.loading && !page.count) return;
        var key = what + "|" + filters.map(function (f) { return f.current }).join(",");
        if (key === built && page.stamp === builtStamp && builtCount === page.count) return;
        var more = key === built && page.count > builtCount && builtCount > 0 && (account.items(builtCount - 1, 1)[0] || {}).id === builtLast;
        var from = more ? builtCount - builtCount % grid.perRow : 0, to = Math.min(page.count, from + 3 * grid.perRow), rows = more ? grid.latest.slice() : [];
        for (var i = from; i < to; i += grid.perRow) rows[i / grid.perRow] = { items: account.items(i, grid.perRow) };
        // under the info, or right under the filters: the rows take their place as they come in
        if (more) grid.replace(rows); else { grid.row = Math.min(grid.row, 0); grid.column = 0; grid.show(rows, "grid", hero ? 650 : 240) }
        built = key; builtCount = to; builtStamp = page.stamp; builtLast = to ? account.items(to - 1, 1)[0].id : "";
        if (to < page.count) rest.restart();
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
        y: browse.scrolled ? 44 : browse.hero ? 560 : 150
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
        dim: browse.mine && browse.page.loading ? 0.3 : 1      // another list is on its way
        onActivated: browse.activated(item)
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
