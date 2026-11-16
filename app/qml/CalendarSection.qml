// Home's calendar: release days of everything in the library, a month at a time. A month bar over the
// month grid; Up and Down move between them, and Up from the bar passes on to Home. The month bar sits
// where the tab bar is (top centre, same size): on the calendar it takes the tab bar's place. While the
// calendar isn't `active` (Home is on Continue Watching) it peeks in at the bottom of Home like the next
// row of a page: its title, and the grid itself showing only this week (faded) and the weeks under it,
// running off the screen. Coming up, the same grid slides into place while the weeks above fade in one
// after another. Leaving returns the grid to today, so the peek always shows this week.
//
// OK on a day with one release emits `activated` with it. OK on a day with more opens the day: the
// month zooms into that day and dissolves, and the day takes the screen, with its date large at the
// top and its releases along a timeline at the bottom, ordered by air time, each card hanging from its
// time. Home shows the focused release's title, episode and synopsis over its art (`dayItem`, which
// Home hands to the hero info and the backdrop). The timeline goes on into the neighbouring days: a tile
// for the previous and the next day with releases sits at each end, and focusing one previews that day.
// OK on it, or Left/Right past it, turns to that day: the date rolls, a light runs along the timeline
// and the cards slide over. Back zooms the month back out to the day.
import QtQuick 2.12
import Seimio.UI 1.0

FocusScope {
    id: section
    property var entries: ({})
    property Item glassSource                // what the month bar's glass blurs
    property real sceneY: 0                  // this section's y in glassSource
    property string today                    // "YYYY-MM-DD"
    property bool active: true
    property real entered: active ? 1 : 0    // 0 the peek, 1 the month bar and grid
    Behavior on entered { NumberAnimation { duration: 480; easing.type: Theme.ease } }
    readonly property var dayEntries: entries[grid.selected] || []
    signal activated(var entry)
    width: Theme.screenWidth
    height: grid.y + grid.height

    property int zone: 1                     // 0 month bar, 1 grid, 2 an open day

    // ---- the open day ----
    // `openDay` holds its releases in air time order; `dayCards` is the timeline: the previous day's
    // tile, the releases, the next day's tile; `dayItems` is what Home shows for each card. All are
    // built once per day, so the focused card's item keeps its identity while the focus moves.
    property bool dayOpen: false
    property var openDay: []
    property var dayCards: []
    property var dayItems: []
    readonly property var dayCard: dayCards[dayStrip.currentIndex] || null
    readonly property var dayItem: dayOpen ? dayItems[dayStrip.currentIndex] || null : null
    readonly property int dayColumn: dayStrip.currentIndex
    // the release Home follows: the focused one in an open day (a day tile's first release), else the
    // focused day's first
    readonly property var focusEntry: dayOpen ? (dayCard ? dayCard.entry : null) : dayEntries[0] || null
    property real grown: dayOpen ? 1 : 0     // 0 the month, 1 the day
    Behavior on grown { NumberAnimation { duration: 560; easing.type: Easing.InOutCubic } }

    function daysAway(e) { return Math.round((grid.parse(e.released) - grid.parse(grid.today)) / 86400000) }
    function stateOf(e) {
        var away = daysAway(e);
        return e.watched ? "Watched" : away < 0 ? "Out" : away === 0 ? "Today" : away === 1 ? "Tomorrow" : "In " + away + " days";
    }
    function releasesOf(k) {
        return (entries[k] || []).slice().sort(function (a, b) { return (a.time || "") < (b.time || "") ? -1 : (a.time || "") > (b.time || "") ? 1 : 0 });
    }
    // the nearest day with releases before (dir -1) or after (dir 1) day k, within the calendar's months
    function neighbour(k, dir) {
        var d = grid.parse(k);
        for (var i = 0; i < 62; i++) {
            d.setDate(d.getDate() + dir);
            var n = grid.key(d);
            if (n < grid.first || n > grid.last) return "";
            if ((entries[n] || []).length) return n;
        }
        return "";
    }
    function buildDay(k) {
        var list = releasesOf(k), prev = neighbour(k, -1), next = neighbour(k, 1), cards = [];
        if (prev) cards.push({ kind: "prev", key: prev, entry: releasesOf(prev)[0] });
        list.forEach(function (e) { cards.push({ kind: "release", entry: e }) });
        if (next) cards.push({ kind: "next", key: next, entry: releasesOf(next)[0] });
        openDay = list; dayCards = cards;
        dayItems = cards.map(function (c) {
            var e = c.entry;
            if (c.kind === "release")
                return { id: e.item.id, name: e.name, title: e.name, logo: e.item.logo || "", backdrop: e.item.backdrop, art: e.art,
                         description: e.overview || e.item.description || "", episode: "Episode " + e.episode,
                         chips: [e.time, stateOf(e)].filter(function (s) { return s }), rating: "", progress: -1 };
            // a neighbouring day: its date as the title, and the first few of its shows
            var day = releasesOf(c.key), names = day.slice(0, 3).map(function (r) { return r.name });
            return { id: "day:" + c.key, name: grid.parse(c.key).toLocaleDateString(Qt.locale(), "dddd d MMMM"), title: "", logo: "",
                     backdrop: e.item.backdrop, art: e.art, episode: "",
                     description: names.join(", ") + (day.length > 3 ? ", and " + (day.length - 3) + " more" : ""),
                     chips: [day.length + (day.length === 1 ? " release" : " releases"), c.kind === "next" ? "Next day" : "Previous day"],
                     rating: "", progress: -1 };
        });
    }
    function firstRelease() { return dayCards.length && dayCards[0].kind === "prev" ? 1 : 0 }
    function openTheDay() { buildDay(grid.selected); dayStrip.jumpTo(firstRelease()); dayOpen = true; zone = 2 }
    function closeTheDay() { dayOpen = false; zone = 1 }

    // turning to a neighbouring day: the date rolls, a light runs along the timeline the way you go,
    // and the cards slide out and the new day's slide in
    property int turnDir: 1
    property string turnTo: ""
    property real cardsShift: 0
    property real cardsFade: 1
    property real dateShift: 0
    property real dateFade: 1
    function goDay(dir) {
        var k = dayCards.length ? (dir > 0 ? dayCards[dayCards.length - 1] : dayCards[0]) : null;
        if (!k || k.kind !== (dir > 0 ? "next" : "prev") || dayTurn.running) return;
        turnDir = dir; turnTo = k.key;
        rail.sweep(dir);
        dayTurn.restart();
    }
    SequentialAnimation {
        id: dayTurn
        ParallelAnimation {
            NumberAnimation { target: section; property: "cardsFade"; to: 0; duration: 160; easing.type: Easing.InQuad }
            NumberAnimation { target: section; property: "cardsShift"; to: -80 * section.turnDir; duration: 160; easing.type: Easing.InQuad }
            NumberAnimation { target: section; property: "dateFade"; to: 0; duration: 180; easing.type: Easing.InQuad }
            NumberAnimation { target: section; property: "dateShift"; to: -56 * section.turnDir; duration: 180; easing.type: Easing.InQuad }
        }
        ScriptAction {
            script: {
                grid.select(section.turnTo);
                section.buildDay(section.turnTo);
                dayStrip.jumpTo(section.turnDir > 0 ? section.firstRelease() : section.firstRelease() + section.openDay.length - 1);
                section.cardsShift = 80 * section.turnDir;
                section.dateShift = 56 * section.turnDir;
            }
        }
        ParallelAnimation {
            NumberAnimation { target: section; property: "cardsFade"; to: 1; duration: 320; easing.type: Theme.ease }
            NumberAnimation { target: section; property: "cardsShift"; to: 0; duration: 460; easing.type: Theme.ease }
            NumberAnimation { target: section; property: "dateFade"; to: 1; duration: 320; easing.type: Theme.ease }
            NumberAnimation { target: section; property: "dateShift"; to: 0; duration: 520; easing.type: Easing.OutBack; easing.overshoot: 1.2 }
        }
    }

    // last month, this one and the next two
    readonly property var months: [-1, 0, 1, 2].map(function (m) { var n = grid.parse(section.today); return new Date(n.getFullYear(), n.getMonth() + m, 1) })
    function monthIndex(d) { for (var i = 0; i < months.length; i++) if (grid.sameMonth(months[i], d)) return i; return -1 }

    // ---- the month: it zooms into the focused day as the day opens ----
    Item {
        id: monthView
        width: section.width; height: section.height
        opacity: 1 - section.grown
        visible: opacity > 0
        readonly property rect cell: grid.cellRect(grid.selected)
        transform: Scale {
            origin.x: grid.x + monthView.cell.x + monthView.cell.width / 2
            origin.y: gridFrame.y + grid.y + monthView.cell.y + monthView.cell.height / 2
            xScale: 1 + 1.8 * section.grown; yScale: xScale
        }
        SegmentedBar {
            id: bar
            opacity: section.entered
            visible: opacity > 0
            scale: 0.9 + 0.1 * section.entered
            // the tab bar's spot: centred, 44 px from the top of the screen once the calendar is up
            x: (section.width - width) / 2; y: 44 - 64
            focus: section.zone === 0
            source: section.glassSource
            sx: x; sy: section.sceneY + y
            shadow: 0.8
            model: section.months.map(function (m) { return m.toLocaleDateString(Qt.locale(), "MMMM") })
            currentIndex: 1
            // choosing a month on the bar focuses its first day, or today in this month
            onCurrentIndexChanged: if (activeFocus) {
                var m = section.months[currentIndex];
                grid.select(grid.sameMonth(m, grid.parse(grid.today)) ? grid.today : grid.key(m));
            }
        }
        Row {
            x: Theme.margin; y: 86; spacing: grid.gap
            opacity: section.entered
            Repeater {
                model: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
                Text {
                    width: grid.cellWidth; horizontalAlignment: Text.AlignHCenter
                    text: modelData; color: Theme.inkDim
                    font.family: Theme.face; font.pixelSize: 19; font.weight: Font.Medium
                }
            }
        }
        // the grid's frame: in the peek it starts at the selected week (today's), whose weeks above are
        // hidden; coming up it moves to show the whole month. The frame has room for the lifted day.
        Item {
            id: gridFrame
            readonly property real room: 28
            readonly property real peekShift: Math.floor(grid.indexOf(grid.selected) / 7) * (grid.cellHeight + grid.gap)
            // the room only matters once the calendar is up; in the peek the frame's edge is the week's edge
            y: 122 * section.entered + 56 * (1 - section.entered) - room * section.entered
            width: section.width; height: grid.height + 2 * room

            MonthGrid {
                id: grid
                x: Theme.margin; y: gridFrame.room * section.entered - gridFrame.peekShift * (1 - section.entered)
                focus: section.zone === 1
                entries: section.entries
                today: section.today
                first: key(section.months[0])
                last: key(new Date(section.months[3].getFullYear(), section.months[3].getMonth() + 1, 0))
                onMonthChanged: { var i = section.monthIndex(month); if (i >= 0) bar.currentIndex = i }
            }
        }
    }
    // leaving returns the grid to today, then folds it back into a peek of this week
    onActiveChanged: { if (!active) { closeTheDay(); grid.select(today) } grid.revealAll = active }
    Component.onCompleted: grid.revealAll = active

    // the peek's title, like the other rows of Home
    Text {
        x: Theme.margin; y: 0
        opacity: 1 - section.entered
        visible: opacity > 0
        text: "Calendar"; color: Theme.ink
        font.family: Theme.face; font.pixelSize: 30; font.weight: Font.DemiBold
    }

    // ---- the day ----
    Item {
        id: dayView
        width: section.width; height: section.height
        visible: section.grown > 0
        // closing fades it with the zoom, and the timeline sinks away
        opacity: section.grown
        readonly property var day: grid.parse(grid.selected)

        // the date, large, top left; it rolls when the day changes
        Reveal {
            shown: section.dayOpen; delay: 220; dy: -18; duration: 420
            x: Theme.margin; y: 0
            Item {
                opacity: section.dateFade
                transform: Translate { y: section.dateShift }
                width: 600; height: 150
                Text {
                    id: dayNumber
                    text: dayView.day.getDate(); color: Theme.ink
                    font.family: Theme.face; font.pixelSize: 132; font.weight: Font.Bold
                    lineHeight: 0.8
                }
                Column {
                    x: dayNumber.width + 24; y: 18; spacing: 4
                    Text {
                        text: dayView.day.toLocaleDateString(Qt.locale(), "dddd"); color: Theme.ink
                        font.family: Theme.face; font.pixelSize: 36; font.weight: Font.DemiBold
                    }
                    Text {
                        text: dayView.day.toLocaleDateString(Qt.locale(), "MMMM yyyy"); color: Theme.inkSoft
                        font.family: Theme.face; font.pixelSize: 26
                    }
                }
                Chip {
                    x: dayNumber.width + 24; y: 104
                    size: 18; text: section.openDay.length + (section.openDay.length === 1 ? " release" : " releases")
                }
            }
        }

        // the releases along a timeline: a line across the screen, each card hanging from its air time
        Reveal {
            shown: section.dayOpen; delay: 300; dy: 40; duration: 520
            y: 680
            width: section.width; height: 260
            transform: Translate { y: (1 - section.grown) * 90 }
            // the line runs through the middle of the time pills (34 tall, 54 above each card); a light
            // runs along it the way the day turns
            ShaderEffect {
                id: rail
                x: Theme.margin; y: dayStrip.y - 54 + 17 - 15
                width: section.width - Theme.margin; height: 30
                property real pos: -1                // where the light is, 0 to 1 along the line
                property real glow: 0
                function sweep(dir) { runner.from = dir > 0 ? -0.1 : 1.1; runner.to = dir > 0 ? 1.1 : -0.1; run.restart() }
                ParallelAnimation {
                    id: run
                    NumberAnimation { id: runner; target: rail; property: "pos"; duration: 900; easing.type: Easing.InOutCubic }
                    SequentialAnimation {
                        NumberAnimation { target: rail; property: "glow"; to: 1; duration: 200 }
                        PauseAnimation { duration: 400 }
                        NumberAnimation { target: rail; property: "glow"; to: 0; duration: 300 }
                    }
                }
                property real aspect: width / height
                fragmentShader: "
                    varying highp vec2 qt_TexCoord0;
                    uniform highp float pos;
                    uniform lowp float glow;
                    uniform highp float aspect;
                    uniform lowp float qt_Opacity;
                    void main() {
                        highp float x = qt_TexCoord0.x;
                        highp float y = (qt_TexCoord0.y - 0.5) * 30.0;           // pixels from the line
                        lowp float fadeOut = 1.0 - smoothstep(0.8, 1.0, x);
                        lowp float line = (1.0 - smoothstep(0.6, 1.4, abs(y))) * mix(0.35, 0.15, x) * fadeOut;
                        highp float dx = (x - pos) * aspect * 30.0 / 220.0;      // the light is about 220 px long
                        lowp float light = exp(-dx * dx) * glow;
                        lowp float a = line + light * ((1.0 - smoothstep(0.5, 2.0, abs(y))) * 0.9 + exp(-y * y / 30.0) * 0.35);
                        gl_FragColor = vec4(a) * qt_Opacity;
                    }"
            }
            CardStrip {
                id: dayStrip
                y: 66; width: section.width
                cardWidth: 320; cardHeight: 180; spacing: 32
                focus: section.zone === 2
                nextLabels: false; showTitles: false
                opacity: section.cardsFade
                transform: Translate { x: section.cardsShift }
                // releases hang from their air time; the neighbouring days' tiles show that day's art,
                // dimmed, with its date and how many releases it has
                model: section.dayCards.map(function (c) {
                    if (c.kind === "release")
                        return { art: c.entry.art, label: c.entry.time || "Any time", episode: "E" + c.entry.episode, watched: c.entry.watched };
                    var d = grid.parse(c.key), n = section.releasesOf(c.key).length;
                    return { art: c.entry.art, label: d.toLocaleDateString(Qt.locale(), "ddd d"),
                             upcoming: d.toLocaleDateString(Qt.locale(), "dddd"), episode: n + (n === 1 ? " release" : " releases") };
                })
                onActivated: {
                    var c = section.dayCards[cardIndex];
                    if (c.kind === "release") section.activated(c.entry); else section.goDay(c.kind === "next" ? 1 : -1);
                }
            }
        }
    }

    // the grid passes Up on only from its top week; an open day keeps Up and Down to itself
    Keys.onUpPressed: if (zone === 1) zone = 0; else if (zone !== 2) event.accepted = false
    Keys.onDownPressed: if (zone === 0) zone = 1; else if (zone !== 2) event.accepted = false
    Keys.onPressed: if (zone === 2 && Remote.isBack(event.key)) { event.accepted = true; closeTheDay() }
    // past the ends of an open day's timeline: the neighbouring day
    Keys.onLeftPressed: if (zone === 2) goDay(-1); else event.accepted = false
    Keys.onRightPressed: if (zone === 2) goDay(1); else event.accepted = false
    OkPress {
        id: ok
        onTapped: if (section.zone === 1 && section.dayEntries.length) {
            if (section.dayEntries.length === 1) section.activated(section.dayEntries[0]); else section.openTheDay();
        }
    }
    Keys.forwardTo: [ok]
}
