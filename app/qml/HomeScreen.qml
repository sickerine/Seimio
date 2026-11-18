// Home, tailored to you: Continue Watching under the hero info, and below it the calendar of release days
// in your library. The strip and the calendar handle their own keys; Home moves between them with
// Up/Down. On the calendar the info and the tab bar step aside (`scrolled`) and the calendar moves up to
// fill the screen. Up from Continue Watching leaves through `exitTop`.
import QtQuick 2.12
import Seimio.UI 1.0

FocusScope {
    id: home
    property var continueWatching: []
    property var catalog: null               // a Catalog (Seimio.Data), for the calendar
    property Item glassSource                // what the calendar's month bar blurs
    property string today
    property bool shown: true                // false sinks Home away (a page is open)
    property int row: 0                      // 0 Continue Watching, 1 calendar
    readonly property bool scrolled: row > 0
    readonly property int column: strip.currentIndex
    readonly property int dayColumn: cal.dayColumn
    // an open calendar day: the hero info and backdrop show its focused release
    readonly property bool dayOpen: cal.dayOpen
    readonly property var focusItem: row === 0 ? watchingItem : cal.focusItem
    // The Continue Watching title under the cursor, set whole with the row the strip shows (`take`) and
    // by a move. The cursor stays on its title when the row is taken again in another order (the title
    // just watched moves to the front): held by its place in the row, Back from that title's page landed
    // on whatever had taken the place, and another title had the focus for a moment on the way.
    property var watchingItem: null
    onContinueWatchingChanged: take()
    Component.onCompleted: take()
    function take() {
        var at = -1;
        for (var i = 0; watchingItem && i < continueWatching.length && at < 0; i++) if (continueWatching[i].id === watchingItem.id) at = i;
        if (at >= 0) strip.jumpTo(at);                    // first: its move names the same title in the new row
        Remote.tally("home taken");
        strip.model = continueWatching;
        watchingItem = continueWatching[strip.currentIndex] || null;
    }
    // the focused Continue Watching card once lifted, for keeping it clear of a frost
    readonly property rect focusRect: Qt.rect(Theme.margin - 20, column.y + 56 - 11.25, 440, 247.5)
    readonly property real focusCardWidth: 400
    signal activated(var item)
    signal held(var item)
    signal releaseHeld(var entry, rect rect)         // a long OK on a release of an open calendar day
    signal exitTop()

    readonly property int cwHeight: 56 + 225 + 84

    Item {
        id: column
        width: home.width
        // a page opening sinks Continue Watching away; the calendar fills the screen, so it only drops a
        // little as it fades
        y: home.row === 0 ? (home.shown ? 610 : 1200) : 64 - home.cwHeight + (home.shown ? 0 : 60)
        opacity: home.shown ? 1 : 0      // holds: its rows stay
        visible: opacity > 0
        Behavior on y { NumberAnimation { duration: 480; easing.type: Theme.ease } }
        Behavior on opacity { NumberAnimation { duration: 320 } }

        Item {
            width: home.width; height: home.cwHeight
            // above the screen while the calendar is up; hidden then, so nothing of it shows when the
            // calendar shifts (opening a page drops it a little)
            opacity: home.row === 0 ? 1 : 0      // holds: the row's cards stay
            Behavior on opacity { NumberAnimation { duration: 300 } }
            Text {
                x: Theme.margin; text: "Continue watching"; color: Theme.ink
                font.family: Theme.face; font.pixelSize: 30; font.weight: Font.DemiBold
            }
            CardStrip {
                id: strip
                y: 56; width: home.width
                cardWidth: 400; cardHeight: 225; spacing: 40
                onCurrentIndexChanged: home.watchingItem = home.continueWatching[currentIndex] || null
                focus: home.row === 0
                onActivated: home.activated(home.continueWatching[cardIndex])
                onHeld: home.held(home.continueWatching[cardIndex])
            }
        }
        CalendarSection {
            id: cal
            active: home.row === 1
            y: home.cwHeight
            focus: home.row === 1
            catalog: home.catalog
            glassSource: home.glassSource
            today: home.today
            sceneY: column.y + y
            onActivated: home.activated(entry.item)
            onHeld: home.releaseHeld(entry, rect)
        }
    }
    Keys.onUpPressed: if (row > 0) row--; else exitTop()
    Keys.onDownPressed: if (row < 1) row++
    // Back leaves the calendar (an open day closes itself first)
    Keys.onPressed: if (Remote.isBack(event.key) && row > 0) { event.accepted = true; row = 0 }
    // the calendar always opens on its grid
    onRowChanged: if (row === 1) cal.zone = 1
}
