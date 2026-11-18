// What a search found (Catalog.search): a row of films, a row of series and a row of anime, each a strip
// of posters walked on its own. The text is typed in App's search field, in the tab bar's place; this is
// the rows under it. They stay until the next search answers.
import QtQuick 2.12
import Seimio.UI 1.0

FocusScope {
    id: search
    property var catalog
    property bool shown: false
    property string query: ""                // what the field holds
    property alias row: grid.row             // -1 the field, 0.. the rows
    readonly property bool scrolled: grid.scrolled
    readonly property var focusItem: grid.focusItem
    readonly property bool any: grid.rows.length > 0
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
            if (query !== search.found) { search.found = query; grid.row = -1; grid.show(rows, "shelf", 240) }
            if (search.entering) search.enter();
        }
    }
    // from the field to what was found: now, or as soon as this text's answer is in
    function enter() {
        if (found === query.trim() && !ask.running) { entering = false; if (any) { grid.row = 0; entered() } }
        else { entering = true; if (ask.running) { ask.stop(); catalog.search(query) } }
    }
    onRowChanged: if (row < 0 && activeFocus) exitTop()

    opacity: shown ? 1 : 0      // holds: its rows stay until the next search answers
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: 320 } }

    CardGrid {
        id: grid
        width: search.width; height: search.height
        focus: true
        held: search.shown
        rowTop: 240
        onActivated: search.activated(item)
        onCardHeld: search.held(item, rect)
    }
    // a search that found nothing says so
    Fade {
        x: Theme.margin; y: 300
        value: search.found !== "" && search.found.length > 1 && !search.any ? "Nothing found for “" + search.found + "”" : ""
        Text { text: parent.current || ""; color: Theme.inkDim; font.family: Theme.face; font.pixelSize: 30; font.weight: Font.Medium }
    }
    Keys.onPressed: if (Remote.isBack(event.key) && row >= 0) { row = -1; event.accepted = true }
}
