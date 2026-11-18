// A CardStrip of one page of a longer sequence (a day's releases, a season's episodes), with a tile for the
// neighbouring page at each end. Focusing a tile previews it; OK on it, or Left/Right past it, turns the
// page: the cards fade and slide out the way you go, the owner swaps in the new page (`turn`, emitted while
// the row is hidden, answered with `show`), and the new cards slide in with focus on the first (going on)
// or the last (going back). `content` is what shows, as one value: `cards` is the page's card data (as CardStrip's model), `prev`
// and `next` the tiles' card data, or nothing where the sequence ends; a tile's data carries the `key` the
// owner needs to find that page. One value, so the row hands its cards their data once per page: as three
// inputs set one after another, every card was rebound for each (a show page took 60-90 ms to load on the
// TV, three times what its cards cost).
// `turning(dir)` comes as a turn starts, for anything the owner animates with it (the calendar's date).
import QtQuick 2.12

FocusScope {
    id: paged
    property var content: ({})
    readonly property var cards: content.cards || []
    readonly property var prev: content.prev || null
    readonly property var next: content.next || null
    property alias cardWidth: strip.cardWidth
    property alias cardHeight: strip.cardHeight
    property alias narrowest: strip.narrowest
    property alias spacing: strip.spacing
    property alias showTitles: strip.showTitles
    property alias nextLabels: strip.nextLabels
    property alias showFocus: strip.showFocus
    // the focused card among the page's cards (-1 on a tile), and which tile has focus
    readonly property int currentIndex: strip.currentIndex - (prev ? 1 : 0)
    readonly property string onTile: prev && strip.currentIndex === 0 ? "prev" : next && strip.currentIndex === strip.count - 1 ? "next" : ""
    readonly property bool turningNow: turnAnim.running
    signal activated(int cardIndex)
    signal held(int cardIndex)
    signal turning(int dir)
    signal turn(int dir, var key, int land)      // `land`: the card focus lands on, -1 for the last
    height: strip.height

    function jumpTo(i) { strip.jumpTo(i + (prev ? 1 : 0)) }
    // another page with focus on its card `i`, handed over as one change: the row is emptied, moved and
    // filled, so each card takes its data once (content and then a jump bound most of them twice)
    function show(page, i) {
        content = ({});
        strip.jumpTo((i < 0 ? Math.max(0, (page.cards || []).length - 1) : i) + (page.prev ? 1 : 0));
        content = page;
    }
    function go(dir) { var tile = dir > 0 ? next : prev; if (tile) turnTo(dir, tile.key, -1) }
    // turning to any page (a season bar picks one): `land` is the card focus lands on, -1 for the first
    // (going on) or the last (going back). The last one asked for wins: while the cards are still on their
    // way out it only changes where they're going, and once the new ones are coming in it starts over.
    function turnTo(dir, key, land) {
        turnDir = dir; turnKey = key; turnLand = land;
        turning(dir);
        if (!turnAnim.running || entering) { entering = false; turnAnim.restart() }
    }

    // the owner placed a page itself (another show opened): a turn still running would swap in its stale page
    function settle() { turnAnim.stop(); entering = false; shift = 0; fade = 1 }

    property int turnDir: 1
    property var turnKey
    property int turnLand: -1
    property real shift: 0
    property real fade: 1
    property bool entering: false       // the page has been swapped and its cards are coming in
    SequentialAnimation {
        id: turnAnim
        ParallelAnimation {
            NumberAnimation { target: paged; property: "fade"; to: 0; duration: 160; easing.type: Easing.InQuad }
            NumberAnimation { target: paged; property: "shift"; to: -80 * paged.turnDir; duration: 160; easing.type: Easing.InQuad }
        }
        ScriptAction {
            script: {
                paged.turn(paged.turnDir, paged.turnKey, paged.turnLand >= 0 ? paged.turnLand : paged.turnDir > 0 ? 0 : -1);
                paged.shift = 80 * paged.turnDir;
                paged.entering = true;
            }
        }
        ParallelAnimation {
            NumberAnimation { target: paged; property: "fade"; to: 1; duration: 320; easing.type: Theme.ease }
            NumberAnimation { target: paged; property: "shift"; to: 0; duration: 460; easing.type: Theme.ease }
        }
        ScriptAction { script: paged.entering = false }
    }

    CardStrip {
        id: strip
        width: paged.width
        focus: true
        opacity: paged.fade
        transform: Translate { x: paged.shift }
        model: (paged.content.prev ? [paged.content.prev] : []).concat(paged.content.cards || []).concat(paged.content.next ? [paged.content.next] : [])
        onActivated: {
            if (paged.onTile) paged.go(paged.onTile === "next" ? 1 : -1);
            else paged.activated(paged.currentIndex);
        }
        onHeld: if (!paged.onTile) paged.held(paged.currentIndex)
    }
    // past either end of the row: the neighbouring page
    Keys.onLeftPressed: if (prev) go(-1); else event.accepted = false
    Keys.onRightPressed: if (next) go(1); else event.accepted = false
}
