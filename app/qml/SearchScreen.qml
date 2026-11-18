// What a search found (Catalog.search), a kind at a time: a grid of posters under the focused title's
// facts and backdrop (App's HeroInfo, as on Movies and Series). The text is typed in App's search bar, in
// the tab bar's place, which also says which kind shows (`kind`: "anime", "series" or "movie"). What was
// found stays until the next search answers; another kind is the same answer's other titles. Every title
// found is in the grid: Cinemeta gives twenty films and twenty series at most, and the anime come fifty
// at a time, the next fifty asked for near the end of the rows.
import QtQuick 2.12
import Seimio.UI 1.0

FocusScope {
    id: search
    property var catalog
    property var watched: ({})               // ids of the titles watched (Account.watchedTitles): a result's poster wears its check by it
    property bool shown: false
    property string query: ""                // what the field holds
    property string kind: "anime"
    property alias row: grid.row             // -1 the bar, 0.. the rows
    readonly property bool scrolled: grid.scrolled
    readonly property var focusItem: grid.focusItem
    property var results: ({})               // what the last search found: the titles of each kind
    function count(k) { var l = results[k]; return l ? l.length : 0 }
    readonly property bool any: count(kind) > 0
    signal activated(var item)
    signal held(var item, rect rect)         // a long OK on a card: its menu goes beside `rect`
    signal exitTop()
    signal entered()                         // the remote goes to the rows (`enter`)

    // asked once the typing has paused; a short query asks for nothing and clears the rows
    property string found: ""
    property bool entering: false            // Enter came before the answer: on to the rows when it is in
    onQueryChanged: { entering = false; ask.restart() }
    onShownChanged: if (!shown) entering = false           // left before the answer: it takes no remote later
    Timer { id: ask; interval: 450; onTriggered: if (search.catalog) search.catalog.search(search.query) }
    Connections {
        target: search.catalog
        onFound: if (query === search.query.trim()) {
            // The text the rows already show, asked again (a space after it): they stay as they are. They
            // may have the remote by now, or a page over them, and a row put back to -1 then left the
            // remote with nothing: Back went nowhere.
            if (query !== search.found) { search.found = query; search.results = results; search.list() }
            if (search.entering) search.enter();
        }
        // a page more of the anime (they come fifty at a time): added under the rows there are, which
        // stay as they are with the cursor where it is
        onFoundMore: if (query === search.found) {
            var all = Object.assign({}, search.results);
            all.anime = (all.anime || []).concat(anime);
            search.results = all;
            if (search.kind === "anime") grid.replace(search.rowsOf(all.anime, grid.latest));
        }
    }
    // titles as the grid's rows: `kept` rows that are full stay the objects they are (a row handed
    // again rebinds its cards), and the rows after them are made
    function rowsOf(items, kept) {
        var rows = [], full = 0;
        while (kept && full < kept.length && kept[full].items.length === grid.perRow) full++;
        rows = kept ? kept.slice(0, full) : [];
        for (var i = full * grid.perRow; i < items.length; i += grid.perRow) rows.push({ items: items.slice(i, i + grid.perRow) });
        return rows;
    }
    // the chosen kind's titles, from the top
    function list() { grid.row = -1; grid.column = 0; grid.show(rowsOf(results[kind] || []), "grid", 560) }
    onKindChanged: list()
    // from the bar to what was found: now, or as soon as this text's answer is in
    function enter() {
        if (found === query.trim() && !ask.running) { entering = false; if (any) { grid.row = 0; entered() } }
        else { entering = true; if (ask.running) { ask.stop(); catalog.search(query) } }
    }
    onRowChanged: {
        if (row < 0 && activeFocus) exitTop();
        if (kind === "anime" && row >= 0 && row >= grid.rows.length - 3) catalog.searchMore();      // near the end: the next page, if there is one
    }

    opacity: shown ? 1 : 0      // holds: its rows stay until the next search answers
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: 320 } }

    CardGrid {
        id: grid
        width: search.width; height: search.height
        focus: true
        held: search.shown
        marks: search.watched
        rowTop: 560
        onActivated: search.activated(item)
        onCardHeld: search.held(item, rect)
    }
    // a search that found nothing of the kind says so
    Fade {
        x: Theme.margin; y: 300
        readonly property var names: ({ anime: "anime", series: "series", movie: "movies" })
        value: search.found.length > 1 && !search.any ? "No " + names[search.kind] + " found for “" + search.found + "”" : ""
        Text { text: parent.current || ""; color: Theme.inkDim; font.family: Theme.face; font.pixelSize: 30; font.weight: Font.Medium }
    }
    Keys.onPressed: if (Remote.isBack(event.key) && row >= 0) { row = -1; event.accepted = true }
}
