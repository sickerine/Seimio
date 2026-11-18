// A month as a grid of days, Monday first. It always shows six weeks, so its size never changes between
// months; days of the neighbouring months fill the edges, faded, and past days are a little dimmer.
// Each day shows its first release (art, name, episode); a day with more stacks them behind it as up
// to two cards whose top edges peek out, with "+N" in the corner, and the stack rises when focused.
// A glowing outline glides over the grid to the focused day, its leading edge first, and the day lifts
// under it. A light runs around today.
//
// Arrows move the focused day (`selected`, "YYYY-MM-DD"), within `first`..`last` (past them the day
// bounces). Up stays in the month: from its first week it passes on to the parent (the way out). Down
// from the last week, Left on the 1st and Right on the last day carry on into the neighbouring month as
// one scroll:
// the week being entered is on screen in both months, so the other weeks fade, the new month is laid out
// with that week where it already is, and the month slides into place with the outline riding on the
// day. A jump to a month that isn't on screen (from a month bar) ripples the days in instead.
//
// What each day shows comes from `days`, a CalendarModel (Seimio.Data, native): it works the days out in
// C++ and hands new ones over a few rows a frame, the week on screen first (see catalog.h).
import QtQuick 2.12

FocusScope {
    id: grid
    property var days: null
    property string today: key(new Date())       // set it from one app-wide clock
    property string selected: today
    property string first: "0000-01-01"
    property string last: "9999-12-31"
    property int cellWidth: 228
    property int cellHeight: 129
    property int gap: 14
    property bool showFocus: activeFocus
    // false shows only the selected week and the weeks under it, the week itself faded (a peek of the
    // grid); turning it true fades the weeks above in one after another, nearest first, and brings the
    // week to full. Each day animates itself, so no JavaScript runs per frame.
    property bool revealAll: true
    readonly property int peekRow: Math.floor(indexOf(selected) / 7)
    onRevealAllChanged: revealed()
    // the peek's week moves when the month is first set or the grid returns to today
    onPeekRowChanged: if (!revealAll) revealed()
    signal revealed()
    // the month on screen (its 1st). Set only when the grid turns: a binding on `selected` would hand
    // every cell a new month on each move and rebuild all 42 (50 ms per move on the TV)
    property var month: new Date(0)
    Component.onCompleted: month = firstOf(parse(selected))
    property int moveDir: 1                      // 1 right, -1 left, 2 down, -2 up
    width: 7 * cellWidth + 6 * gap
    height: 6 * cellHeight + 5 * gap

    function pad(n) { return (n < 10 ? "0" : "") + n }
    function key(d) { return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate()) }
    function parse(k) { var p = k.split("-"); return new Date(+p[0], +p[1] - 1, +p[2]) }
    function firstOf(d) { return new Date(d.getFullYear(), d.getMonth(), 1) }
    function sameMonth(a, b) { return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() }
    // the Monday on or before the 1st
    readonly property var start: new Date(month.getFullYear(), month.getMonth(), 1 - (month.getDay() + 6) % 7)
    // the model lays out the month: the week `firstWeek` at once (the one on screen, or where a ripple
    // starts), the rest a few days a frame; -1 lays it all out at once
    property int firstWeek: -1
    function layOut() { if (days) { days.layOut(month.getFullYear(), month.getMonth() + 1, firstWeek); firstWeek = -1 } }
    onMonthChanged: layOut()
    onDaysChanged: if (days) { days.today = today; layOut() }
    onTodayChanged: if (days) days.today = today
    function indexOf(k) { return Math.round((parse(k) - start) / 86400000) }
    // a day's rectangle in the grid
    function cellRect(k) { var i = indexOf(k); return Qt.rect((i % 7) * (cellWidth + gap), Math.floor(i / 7) * (cellHeight + gap), cellWidth, cellHeight) }

    function select(k) { if (k >= first && k <= last) selected = k }
    // go to day k without any animation, a week at a time starting with k's (for when the grid is off
    // screen or moving away, e.g. returning to today as the calendar leaves)
    function jump(k) {
        var d = parse(k);
        if (!sameMonth(d, month)) {
            var m = firstOf(d), ms = new Date(m.getFullYear(), m.getMonth(), 1 - (m.getDay() + 6) % 7);
            firstWeek = Math.floor(Math.round((d - ms) / 86400000) / 7);
            month = m;
        }
        selected = k;
    }
    function move(days) {
        var d = parse(selected); d.setDate(d.getDate() + days);
        var k = key(d);
        if (k < first || k > last) { bounce.restart(); return }
        // Left/Right onto another week (wrapping a row's end): the outline doesn't travel across the
        // grid; it leaves the old day and appears on the new one
        var from = indexOf(selected), to = indexOf(k);
        if ((days === 1 || days === -1) && Math.floor(from / 7) !== Math.floor(to / 7) && sameMonth(d, month)) {
            snap = true; selected = k; snap = false;
            wrap.restart();
            return;
        }
        selected = k;
    }
    // the outline appearing on a day it didn't glide to
    property real outlineIn: 1
    SequentialAnimation {
        id: wrap
        PropertyAction { target: grid; property: "outlineIn"; value: 0 }
        NumberAnimation { target: grid; property: "outlineIn"; to: 1; duration: 260; easing.type: Easing.OutCubic }
    }
    onSelectedChanged: {
        var d = parse(selected);
        if (sameMonth(d, month)) return;
        turnDir = d > month ? 1 : -1;
        nextMonth = firstOf(d);
        var oldIndex = indexOf(selected);
        // a week just past the grid (Down from a sixth week) still scrolls; anything further ripples in
        if (oldIndex < -7 || oldIndex >= 49) { turn.restart(); return }
        var nextStart = new Date(nextMonth.getFullYear(), nextMonth.getMonth(), 1 - (nextMonth.getDay() + 6) % 7);
        shareOld = Math.floor(oldIndex / 7);
        shareNew = Math.floor(Math.round((d - nextStart) / 86400000) / 7);
        scroll.restart();
    }

    // the scroll into a neighbouring month (see the top): the week on screen in both is `shareOld` in
    // the old month and `shareNew` in the new one
    property int shareOld: 0
    property int shareNew: 0
    property real slide: 0                       // the month's offset while it slides into place
    property bool snap: false                    // the outline jumps (with the month) instead of gliding
    signal leaving(int keepRow)
    signal arriving(int fromRow)
    SequentialAnimation {
        id: scroll
        ScriptAction { script: grid.leaving(grid.shareOld) }
        PauseAnimation { duration: 150 }
        ScriptAction {
            script: {
                grid.snap = true;
                grid.firstWeek = grid.shareNew;
                grid.month = grid.nextMonth;
                grid.slide = (grid.shareOld - grid.shareNew) * (grid.cellHeight + grid.gap);
                grid.arriving(grid.shareNew);
                grid.snap = false;
            }
        }
        NumberAnimation { target: grid; property: "slide"; to: 0; duration: 560; easing.type: Easing.OutCubic }
    }

    // turning to another month: the old days fade, then the new ones ripple in from the side moved
    // toward. Each day runs its own animation on its own properties, so the ripple costs no JavaScript
    // per frame (a shared 0-to-1 value driving 42 days' bindings took 30 ms a frame on the TV).
    property var nextMonth: month
    property int turnDir: 1
    property real fade: 1
    signal turned()
    SequentialAnimation {
        id: turn
        NumberAnimation { target: grid; property: "fade"; to: 0; duration: 110; easing.type: Easing.InQuad }
        // all days at once: the ripple shows days from every week within ~300 ms, sooner than staging
        // would reach them (it's hidden behind the fade, and only month-bar jumps ripple)
        ScriptAction { script: { grid.firstWeek = -1; grid.month = grid.nextMonth; grid.fade = 1; grid.turned() } }
    }

    // a light running around today's day (the day in the month on screen that is today says which it is)
    property Item todayLight: null
    function light(effect, on) { if (on) todayLight = effect; else if (todayLight === effect) todayLight = null }
    property Ambient sweep: Ambient { effect: grid.todayLight; uniform: "turn"; period: 3600; running: grid.visible }

    Item {
        id: content
        width: grid.width; height: grid.height
        y: grid.slide
        opacity: grid.fade
        Repeater {
            model: grid.days
            Item {
                id: cell
                // what this day shows, from the model's roles (named here, since the stack's own
                // Repeater below has a `model` of its own)
                readonly property string k: model.key
                readonly property int date: model.date
                readonly property int count: model.count
                readonly property string art0: model.art0
                readonly property string art1: model.art1
                readonly property string art2: model.art2
                readonly property string name: model.name
                readonly property string episode: model.episode
                readonly property string more: model.more
                Component.onCompleted: settle(false)
                // neighbouring months' days are faded most, past days a little. The day is one texture (see
                // `deck`), so fading it fades the stack as a whole, without its cards showing through each
                // other, and costs no JavaScript or re-drawing per frame.
                readonly property real dayOpacity: model.dayOpacity
                // a peek shows only the selected week, faded; revealing brings it to full and fades the weeks
                // above in, nearest first (the weeks under it come up from below the screen)
                function settle(animate) {
                    var above = row < grid.peekRow;
                    var show = grid.revealAll ? 1 : (row === grid.peekRow ? 0.3 : 0);
                    if (!animate) { reveal.stop(); grow.opacity = show; return }
                    revealPause.duration = grid.revealAll && above ? 60 + (grid.peekRow - 1 - row) * 80 : 0;
                    showAnim.to = show; showAnim.duration = show > 0 ? 400 : 160;
                    reveal.restart();
                }
                Connections { target: grid; onRevealed: cell.settle(true) }
                SequentialAnimation {
                    id: reveal
                    PauseAnimation { id: revealPause }
                    NumberAnimation { id: showAnim; target: grow; property: "opacity"; easing.type: Easing.OutCubic }
                }
                // room at the top for the cards behind to peek out: 6 px per card behind, up to two
                readonly property real stackRoom: model.stackRoom
                readonly property bool isToday: model.isToday
                readonly property bool focused: k === grid.selected && grid.showFocus
                readonly property int row: Math.floor(index / 7)
                readonly property int col: index % 7
                x: col * (grid.cellWidth + grid.gap)
                y: row * (grid.cellHeight + grid.gap)
                width: grid.cellWidth; height: grid.cellHeight
                // the focused day above all, its week above the others, so a lifted day isn't covered
                z: focused ? 3 : (row === Math.floor(grid.focusIndex / 7) ? 2 : 1)
                transform: Translate { id: rise }

                // the scroll: the other weeks fade before the month changes, and the new month's weeks fade
                // in by their distance from the shared week as it slides
                Connections {
                    target: grid
                    onLeaving: if (cell.row !== keepRow) { arrive.stop(); enter.stop(); leave.restart() }
                    onArriving: {
                        arrive.stop(); leave.stop();
                        if (cell.row === fromRow) { enter.stop(); cell.opacity = 1; return }
                        cell.opacity = 0;
                        enterPause.duration = Math.abs(cell.row - fromRow) * 90;
                        enter.restart();
                    }
                }
                NumberAnimation { id: leave; target: cell; property: "opacity"; to: 0; duration: 150; easing.type: Easing.InQuad }
                SequentialAnimation {
                    id: enter
                    PauseAnimation { id: enterPause }
                    NumberAnimation { target: cell; property: "opacity"; to: 1; duration: 300; easing.type: Easing.OutCubic }
                }
                // the ripple: days nearer the side the grid turned toward arrive first
                Connections { target: grid; onTurned: { cell.opacity = 0; arrive.restart() } }
                SequentialAnimation {
                    id: arrive
                    PauseAnimation { duration: ((grid.turnDir > 0 ? cell.row + cell.col : (5 - cell.row) + (6 - cell.col)) / 11) * 300 }
                    ParallelAnimation {
                        NumberAnimation { target: cell; property: "opacity"; from: 0; to: 1; duration: 340; easing.type: Easing.OutQuad }
                        NumberAnimation { target: rise; property: "y"; from: 26 * grid.turnDir; to: 0; duration: 440; easing.type: Easing.OutCubic }
                        NumberAnimation { target: grow; property: "scale"; from: 0.88; to: 1; duration: 440; easing.type: Easing.OutCubic }
                    }
                }

                Item {
                    id: grow
                    anchors.fill: parent
                    // (it stays on at no opacity, in the weeks a peek leaves out: hidden, a day drew its
                    // texture and sent its art to the GPU only as the month opened, 28 days in one 134 ms
                    // frame, where at no opacity they do it one by one as the art comes in at launch. The
                    // price is that all 42 are drawn again in the frame Home comes back in, 13 to 15 ms.)
                    Item {
                        id: face
                        anchors.fill: parent
                        scale: cell.focused ? 1.06 : 1
                        transform: Translate { y: cell.focused ? grid.nudge : 0 }
                        Behavior on scale { NumberAnimation { duration: 280; easing.type: Easing.OutBack; easing.overshoot: 1.3 } }

                        // the day drawn into one texture: a stack of cards with their chips and text is about a dozen
                        // draw calls, and a month of them was 12-15 ms a frame on the TV. As one texture each day is a
                        // single quad, re-drawn only when it changes (art loading, the stack rising, fading). It reaches
                        // past the day for the stack that rises above it, and is a little larger so the lift stays sharp.
                        Item {
                            id: deck
                            x: -4; y: -24; width: cell.width + 8; height: cell.height + 28
                            layer.enabled: true
                            opacity: cell.dayOpacity
                            Behavior on opacity { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
                            layer.smooth: true
                            layer.textureSize: Qt.size(Math.ceil(width * 1.1), Math.ceil(height * 1.1))
                            Item {
                                x: 4; y: 24; width: cell.width; height: cell.height
                                // an empty day
                                Rectangle {
                                    visible: cell.count === 0
                                    anchors.fill: parent; radius: 14
                                    color: cell.focused ? "#33ffffff" : "#17ffffff"
                                    Behavior on color { ColorAnimation { duration: Theme.fast } }
                                }
                                // the day's other releases, as up to two cards behind the top one: their top edges
                                // peek out above it, narrower and darker the further back, and rise when focused.
                                // Every day keeps both cards and shows what it needs, so turning the month creates
                                // no cards (creating them per month cost about 100 ms on the TV)
                                Repeater {
                                    model: 2
                                    CardArt {
                                        visible: index < cell.count - 1
                                        readonly property real inset: (index + 1) * cell.width * 0.05
                                        z: -1 - index
                                        x: inset; width: cell.width - 2 * inset
                                        y: cell.stackRoom - (index + 1) * (cell.focused ? 10 : 6)
                                        height: cell.height - cell.stackRoom
                                        Behavior on y { NumberAnimation { duration: 320; easing.type: Easing.OutBack; easing.overshoot: 1.6 } }
                                        radius: 12
                                        art: index ? cell.art2 : cell.art1
                                        dim: 0.4 + index * 0.25
                                    }
                                }
                                // the day's first release
                                Item {
                                    visible: cell.count > 0
                                    y: cell.stackRoom; width: cell.width; height: cell.height - cell.stackRoom
                                    CardArt { anchors.fill: parent; radius: 14; art: cell.art0; shade: 0.8 }
                                    Text {
                                        x: 12; y: parent.height - height - 10; width: parent.width - 70
                                        elide: Text.ElideRight
                                        text: cell.name; color: Theme.ink; textFormat: Text.PlainText
                                        font.family: Theme.face; font.pixelSize: 17; font.weight: Font.DemiBold
                                    }
                                    Chip {
                                        anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: 8
                                        size: 14; text: cell.episode
                                    }
                                    // how many more the day has
                                    Chip {
                                        visible: cell.count > 1
                                        anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 8
                                        size: 14; kind: "solid"; text: cell.more
                                    }
                                }
                                // the date, top left; today's in a white pill
                                Rectangle {
                                    x: 8; y: cell.stackRoom + 8
                                    height: 30; radius: 15; width: Math.max(30, date.implicitWidth + 16)
                                    color: cell.isToday ? Theme.focusFill : (cell.count ? "#73000000" : "transparent")
                                    Text {
                                        id: date
                                        anchors.centerIn: parent
                                        text: cell.date; textFormat: Text.PlainText
                                        color: cell.isToday ? Theme.inkOnLight : Theme.ink
                                        font.family: Theme.face; font.pixelSize: 19; font.weight: Font.DemiBold
                                    }
                                }
                            }
                        }

                        // today: a light runs around the top card
                        ShaderEffect {
                            id: ring
                            visible: cell.isToday
                            x: -2; y: cell.stackRoom - 2; width: cell.width + 4; height: cell.height - cell.stackRoom + 4
                            property size box: Qt.size(width, height)
                            property real radius: 16
                            property real turn: 0                 // once around, 0 to 1 (grid.sweep)
                            readonly property bool lit: cell.isToday
                            onLitChanged: grid.light(ring, lit)
                            Component.onCompleted: if (lit) grid.light(ring, true)
                            fragmentShader: "
                                varying highp vec2 qt_TexCoord0;
                                uniform highp vec2 box;
                                uniform highp float radius;
                                uniform highp float turn;
                                uniform lowp float qt_Opacity;
                                void main() {
                                    highp float angle = 6.28318 * turn;
                                    highp vec2 p = qt_TexCoord0 * box - box * 0.5;
                                    highp vec2 q = abs(p) - (box * 0.5 - vec2(radius));
                                    highp float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
                                    highp float ring = smoothstep(-3.0, -1.0, d) * (1.0 - smoothstep(-1.0, 0.5, d));
                                    highp float a = atan(p.y, p.x) - angle;
                                    a = mod(a + 3.14159, 6.28318) - 3.14159;
                                    lowp float light = 0.25 + 0.75 * exp(-a * a * 2.5);
                                    gl_FragColor = vec4(ring * light) * qt_Opacity;
                                }"
                        }
                    }
                }
            }
        }
        // the outline over the focused day (it slides with the month); above every day, the focused one
        // and its stack included
        ShaderEffect {
            z: 10
            readonly property real pad: 24           // room for the glow
            x: grid.plateL - pad; y: grid.plateT - pad + grid.nudge
            width: grid.plateR - grid.plateL + 2 * pad; height: grid.plateB - grid.plateT + 2 * pad
            // eased only for focus coming and going; the pop-in onto a wrapped day drives `outlineIn` itself
            property real focusShown: grid.showFocus && grid.fade > 0.5 ? 1 : 0
            Behavior on focusShown { NumberAnimation { duration: Theme.base } }
            opacity: focusShown * grid.outlineIn
            scale: 1.08 - 0.08 * grid.outlineIn
            visible: opacity > 0
            property size box: Qt.size(width, height)
            property real inset: pad
            property real radius: 22
            fragmentShader: "
                varying highp vec2 qt_TexCoord0;
                uniform highp vec2 box;
                uniform highp float inset;
                uniform highp float radius;
                uniform lowp float qt_Opacity;
                void main() {
                    highp vec2 p = qt_TexCoord0 * box;
                    highp vec2 q = abs(p - box * 0.5) - (box * 0.5 - vec2(inset + radius));
                    highp float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
                    lowp float top = clamp(1.0 - (p.y - inset) / (box.y - 2.0 * inset), 0.0, 1.0);
                    // a bright line on the edge, strongest at the top, and a soft glow on both sides of it
                    lowp float line = 1.0 - smoothstep(0.6, 1.8, abs(d));
                    lowp float glow = exp(-abs(d) / 8.0);
                    lowp float a = line * (0.55 + 0.45 * top) + glow * 0.28;
                    gl_FragColor = vec4(a) * qt_Opacity;
                }"
        }
    }

    // the outline over the focused day; each edge animates on its own, the leading one first
    readonly property int focusIndex: indexOf(selected)
    readonly property real plateGrow: 12
    property real plateL: (focusIndex % 7) * (cellWidth + gap) - plateGrow
    property real plateR: (focusIndex % 7) * (cellWidth + gap) + cellWidth + plateGrow
    property real plateT: Math.floor(focusIndex / 7) * (cellHeight + gap) - plateGrow
    property real plateB: Math.floor(focusIndex / 7) * (cellHeight + gap) + cellHeight + plateGrow
    Behavior on plateL { enabled: !grid.snap; NumberAnimation { duration: grid.moveDir > 0 ? 380 : 220; easing.type: Theme.ease } }
    Behavior on plateR { enabled: !grid.snap; NumberAnimation { duration: grid.moveDir < 0 ? 380 : 220; easing.type: Theme.ease } }
    Behavior on plateT { enabled: !grid.snap; NumberAnimation { duration: grid.moveDir === 2 ? 380 : 220; easing.type: Theme.ease } }
    Behavior on plateB { enabled: !grid.snap; NumberAnimation { duration: grid.moveDir === -2 ? 380 : 220; easing.type: Theme.ease } }

    Keys.onLeftPressed: { moveDir = -1; move(-1) }
    Keys.onRightPressed: { moveDir = 1; move(1) }
    function inMonth(days) { var d = parse(selected); d.setDate(d.getDate() + days); return sameMonth(d, month) }
    Keys.onDownPressed: { moveDir = 2; move(7) }
    Keys.onUpPressed: { if (inMonth(-7)) { moveDir = -2; move(-7) } else event.accepted = false }
    // the end of the month: the outline and the day dip and spring back
    property real nudge: 0
    SequentialAnimation {
        id: bounce
        NumberAnimation { target: grid; property: "nudge"; to: 12; duration: 90; easing.type: Easing.OutQuad }
        NumberAnimation { target: grid; property: "nudge"; to: 0; duration: 320; easing.type: Easing.OutBack; easing.overshoot: 2 }
    }
}
