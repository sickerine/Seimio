// Rows of cards under a screen's controls: a season's chart, a week's schedule, the library, a list of
// films. A fixed pool of row strips handed new rows as the list moves, as CardStrip does with cards, so a
// long grid never builds more than a screen.
//   rows   [{ items, schedule, shelf, title, date }]: a `schedule` row is stills that slide under a title
//          and a `shelf` posters that do (a search's results), each row keeping its own place; the others
//          are a grid of posters that share one `column`
//   row    -1 above the rows (the owner's controls have the remote), 0.. the rows; `scrolled` past the first
//   show(rows, layout, top)   on screen, the old rows fade out and the new take their place and rise in,
//          as one piece, at `top` if given (`rowTop` from then on); `replace(rows)` swaps them where they
//          are (a countdown ticking, a page more), `latest` being the rows to start from
// Up and Down walk the rows; Up from the first hands the remote back (`row` -1). `held`: the owner is up,
// so every card's art is kept decoded ahead (ArtCache), and a row scrolled to has its art already.
import QtQuick 2.12

FocusScope {
    id: grid
    property var rows: []
    property int row: -1
    property int column: 0
    readonly property bool scrolled: row > 0
    property string layout: "grid"           // the layout the rows on screen are for: "grid", "schedule" or "shelf"
    property int perRow: 7
    property bool held: false
    property real dim: 1                     // below 1 the rows dim as one piece (another list is on its way)
    property int rowTop: 650                 // where the first row sits, under the owner's controls
    readonly property bool swapping: swap.running
    readonly property var focusItem: {
        var r = rows.length ? rows[Math.max(0, row)] || rows[0] : null;
        return r ? r.items[Math.min(restingColumn(Math.max(0, row)), r.items.length - 1)] || null : null;
    }
    signal activated(var item)

    property var pending: null
    property string pendingLayout: "grid"
    property int pendingTop: rowTop
    function show(next, nextLayout, top) {
        pending = next; pendingLayout = nextLayout || "grid"; pendingTop = top === undefined ? rowTop : top;
        if (visible) Remote.stir();
        if (visible && rows.length) swap.restart(); else apply();
    }
    // the rows it shows, or the ones on their way in while the old ones fade out: what `replace` replaces
    readonly property var latest: pending || rows
    function replace(next) {
        if (visible) Remote.stir();
        if (pending) pending = next; else { rows = next; if (row >= rows.length) row = rows.length - 1 }
    }
    // new rows reach the row slots a slot a frame, top first (`staggering`): handing every slot its
    // cards at once (28 cards resized and rebound) stalled ~90 ms; they arrive while the list fades in
    property bool staggering: false
    Timer { id: staggerEnd; interval: 120; onTriggered: grid.staggering = false }
    function apply() {
        staggering = rows.length > 0 || pending.length > 0; staggerEnd.restart();
        rowColumns = ({}); rowTop = pendingTop; rows = pending; layout = pendingLayout; pending = null; if (row >= rows.length) row = rows.length - 1;
    }
    // where each row rests along itself: a grid's rows line up and share `column`; each of a schedule's
    // days slides on its own and keeps its own place (by row), starting at its first card
    property var rowColumns: ({})
    function restingColumn(rowIdx) { return layout !== "grid" ? (rowColumns[rowIdx] || 0) : column }
    function rememberColumn(rowIdx, i) { var c = Object.assign({}, rowColumns); c[rowIdx] = i; rowColumns = c }

    // the cards: a grid's posters fill the width between the margins exactly; a schedule's are stills
    readonly property int contentWidth: Theme.screenWidth - 2 * Theme.margin
    readonly property size gridCard: Theme.posterCard
    readonly property int gridGap: (contentWidth - perRow * gridCard.width) / (perRow - 1)
    readonly property size scheduleCard: Theme.stillCard
    // every card's art, held decoded ahead once the owner has been up (built ahead of that, only the rows
    // on screen decode theirs)
    readonly property var covers: {
        var out = [];
        for (var i = 0; i < rows.length; i++) for (var j = 0; j < rows[i].items.length; j++) out.push(rows[i].items[j].art || "");
        return out;
    }
    function holdCovers() {
        var c = layout === "schedule" ? scheduleCard : gridCard, size = Theme.cardDecodeSize(c.width, c.height);
        if (held) ArtCache.keep(covers, size.width, size.height);
    }
    onCoversChanged: holdCovers()
    onHeldChanged: holdCovers()

    // Coming on screen, its rows show a frame apart, top first: what the GPU sees for the first time costs
    // the frame that shows it, and a tab's first visit drew two rows of posters in one, 25 to 35 ms
    property int arrived: 4
    onVisibleChanged: if (visible) { arrived = 0; arriving.restart() }
    Timer { id: arriving; interval: 16; repeat: true; onTriggered: if (++grid.arrived >= list.slots) stop() }

    SequentialAnimation {
        id: swap
        NumberAnimation { target: list; property: "shown"; to: 0; duration: 140; easing.type: Easing.InQuad }
        ScriptAction { script: { grid.apply(); list.rise = 28 } }
        ParallelAnimation {
            NumberAnimation { target: list; property: "shown"; to: 1; duration: 320; easing.type: Theme.ease }
            NumberAnimation { target: list; property: "rise"; to: 0; duration: 420; easing.type: Theme.ease }
        }
    }
    Item {
        id: list
        property real rise: 0
        transform: Translate { y: list.rise }
        width: grid.width; height: grid.height
        // how much of it shows: the swap's fade and the dimming together. (Dimmed through a layer of its
        // own, as one piece, the screen-sized texture was made anew each time a list loaded: a 13 ms frame.)
        property real shown: 1
        property real dim: grid.dim
        Behavior on dim { NumberAnimation { duration: Theme.base } }
        opacity: shown * dim
        readonly property int stride: 430
        // once the controls have gone up, the focused row sits just under them with two more below it,
        // and the rows above have gone
        readonly property real scrollTarget: grid.row <= 0 ? 0 : grid.rowTop + grid.row * stride - 160
        property real scrollY: scrollTarget
        Behavior on scrollY { NumberAnimation { id: scrolling; duration: 480; easing.type: Theme.ease } }
        readonly property int slots: 4
        readonly property int first: Math.max(0, Math.floor((scrollY - grid.rowTop) / stride))
        Repeater {
            model: list.slots
            FocusScope {
                id: slot
                readonly property int idx: list.first + ((index - list.first) % list.slots + list.slots) % list.slots
                // the row this slot shows: at once when the slot is recycled while scrolling, a frame per
                // place down the screen when new rows arrive (grid.staggering); its layout comes with it
                readonly property var wanted: idx < grid.rows.length ? grid.rows[idx] : null
                property var r: null
                Component.onCompleted: r = wanted
                // recycled mid-scroll into a place that's hidden once the scroll ends (past the bottom, or
                // above the focused row, which fades out), it rebinds its cards after the scroll: 7 cards at
                // once cost 40-60 ms, a hitch in the slide
                readonly property bool shownAtRest: { var y = grid.rowTop + idx * list.stride - list.scrollTarget; return y < grid.height && y + height > 0 && (grid.row <= 0 || idx >= grid.row) }
                onWantedChanged: {
                    if (grid.staggering) { take.interval = 16 * (1 + Math.max(0, idx - list.first)); take.restart() }
                    else if (scrolling.running && !shownAtRest) take.stop();          // taken when the scroll ends
                    else r = wanted;
                }
                Connections { target: scrolling; onRunningChanged: if (!scrolling.running && slot.r !== slot.wanted) slot.r = slot.wanted }
                // another press moved where the scroll ends and brought it on screen: it takes its row now
                // (waiting for the scroll to end left it empty, then snapping in, while presses kept coming)
                onShownAtRestChanged: if (shownAtRest && !take.running && r !== wanted) r = wanted
                Timer { id: take; onTriggered: slot.r = slot.wanted }
                readonly property bool schedule: !!(r && r.schedule)
                readonly property bool titled: !!(r && (r.schedule || r.shelf))      // a row of its own: a title over cards that slide
                // a slot fully off screen isn't drawn (Qt draws what's off screen)
                visible: r !== null && y < grid.height && y + height > 0 && idx - list.first <= grid.arrived
                y: grid.rowTop + idx * list.stride - list.scrollY
                // a slot handed another row (the pool recycles as the list scrolls) takes that row's place
                // along itself, not the place of the row it showed before
                function place() { strip.jumpTo(Math.max(0, Math.min(grid.restingColumn(idx), (strip.model || []).length - 1))) }
                width: grid.width; height: list.stride
                focus: grid.row === idx
                opacity: grid.row > 0 && idx < grid.row ? 0 : 1      // holds: the row's cards stay
                Behavior on opacity { NumberAnimation { duration: Theme.base } }
                Row {
                    x: Theme.margin
                    visible: slot.titled
                    spacing: 16
                    Text { text: slot.r && slot.r.title || ""; color: Theme.ink; font.family: Theme.face; font.pixelSize: 30; font.weight: Font.DemiBold }
                    Text { anchors.baseline: parent.children[0].baseline; text: slot.r && slot.r.date || ""; color: Theme.inkDim; font.family: Theme.face; font.pixelSize: 24; font.weight: Font.Medium }
                }
                CardStrip {
                    id: strip
                    y: slot.schedule ? 108 : slot.titled ? 62 : 54
                    width: grid.width
                    focus: true
                    model: slot.r ? slot.r.items : []
                    slides: slot.titled
                    nextLabels: false
                    cardWidth: slot.schedule ? grid.scheduleCard.width : grid.gridCard.width
                    cardHeight: slot.schedule ? grid.scheduleCard.height : grid.gridCard.height
                    narrowest: grid.gridCard.width
                    spacing: slot.schedule ? 36 : grid.gridGap
                    showFocus: activeFocus
                    onCurrentIndexChanged: if (activeFocus) { if (slot.titled) grid.rememberColumn(slot.idx, currentIndex); else grid.column = currentIndex }
                    onActivated: grid.activated(model[cardIndex])
                    onModelChanged: slot.place()
                }
                onActiveFocusChanged: if (activeFocus) place()
            }
        }
    }
    Keys.onUpPressed: if (row > 0) row--; else if (row === 0) row = -1
    Keys.onDownPressed: if (row < rows.length - 1) row++
}
