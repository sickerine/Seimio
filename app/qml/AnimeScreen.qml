// The Anime tab: the season as AniChart charts it. Under the focused show's info (App's HeroInfo) and
// its next episode's countdown sit the controls: the view (the chart, or the week's schedule by day and
// time), the format, the order, and a genre. Below them the shows: a grid of covers, each counting down
// to its next episode, or a row per day with air times. Moving into the rows lifts the controls into the
// tab bar's place, as the calendar's months do, and the info steps aside.
//
// The season comes from Catalog (seasonChart, seasonSchedule), filtered and sorted in C++; a change of
// control asks again once the selection has settled. The rows are a fixed pool of strips handed new
// rows as the list moves, as CardStrip does with cards, so a long chart never builds more than a screen.
import QtQuick 2.12
import Seimio.UI 1.0

FocusScope {
    id: anime
    property var catalog: null
    property Item glassSource
    property bool shown: false
    property var shownItem: null             // the show App's info is on (the countdown follows it)
    property double now: Date.now() / 1000   // epoch seconds; previews fix it
    property bool live: true                 // previews turn the clock off

    // -1 the controls, 0.. the rows
    property int row: -1
    property int column: 0
    readonly property bool scrolled: row > 0
    property string view: "chart"
    property string format: "all"
    property string sort: "popular"
    property string genre: ""
    property bool genreMenu: false

    readonly property var views: [["Chart", "chart"], ["Schedule", "schedule"]]
    readonly property var formats: [["All", "all"], ["TV", "tv"], ["Movies", "movie"], ["ONA & OVA", "other"]]
    readonly property var sorts: [["Popular", "popular"], ["Top rated", "score"], ["Airing soon", "airing"], ["A–Z", "title"]]
    readonly property int perRow: 7

    // [{ title, date, items }]: the chart cut into rows, or the days that have episodes
    property var rows: []
    property int total: 0
    // the focused show; once opened, its Kitsu version (playable), which App's selection then follows
    readonly property var focusItem: {
        var r = rows.length ? rows[Math.max(0, row)] || rows[0] : null, raw = r ? r.items[Math.min(column, r.items.length - 1)] || null : null;
        return raw && resolved[raw.id] ? resolved[raw.id] : raw;
    }
    property var resolved: ({})
    function resolve(sourceId, item) { var r = Object.assign({}, resolved); r[sourceId] = item; resolved = r }
    // a moment's word when a show can't open (not on Kitsu yet, its episodes didn't load)
    property string notice: ""
    function say(text) { notice = text; noticeTimer.restart() }
    Timer { id: noticeTimer; interval: 2600; onTriggered: anime.notice = "" }
    signal activated(var item)
    signal exitTop()

    // asked only while the tab is up (a hidden screen builds nothing: its covers decoding at launch
    // slowed Home)
    function refresh() {
        if (!catalog || !catalog.ready || !shown) return;
        var out = [];
        if (view === "chart") {
            var items = catalog.seasonChart(format, genre, sort, now);
            total = items.length;
            for (var i = 0; i < items.length; i += perRow) out.push({ title: "", date: "", items: items.slice(i, i + perRow) });
        } else {
            var days = catalog.seasonSchedule(format, genre, now);
            total = 0;
            for (var d = 0; d < days.length; d++) if (days[d].items.length) { out.push(days[d]); total += days[d].items.length }
        }
        // on screen, the old rows fade out, the new ones take their place and rise in, as one piece
        pending = out;
        if (shown && rows.length) { swap.restart(); return }
        apply();
    }
    property var pending: null
    function apply() { rows = pending; pending = null; if (row >= rows.length) row = rows.length - 1 }
    Connections { target: anime.catalog; onLoaded: anime.refresh() }
    onShownChanged: if (shown && !rows.length) refresh()
    // a control's choice is asked for once the selection rests (moving along a bar selects)
    Timer { id: requery; interval: 260; onTriggered: anime.refresh() }
    onViewChanged: requery.restart()
    onFormatChanged: requery.restart()
    onSortChanged: requery.restart()
    onGenreChanged: requery.restart()
    Timer { interval: 60000; running: anime.live && anime.shown; repeat: true; onTriggered: { anime.now = Date.now() / 1000; anime.refresh() } }

    opacity: shown ? 1 : 0
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: 320 } }

    // ---- the next episode, beside the info --------------------------------------------------------------
    Item {
        id: countdown
        // the show it counts down for, held while it fades out (it emptied as a show without a next
        // episode came in)
        readonly property bool itemAiring: !!(anime.shownItem && anime.shownItem.nextAt > anime.now)
        Latch { id: counted; value: anime.shownItem; live: anime.row <= 0 && countdown.itemAiring }
        readonly property var m: counted.current
        readonly property double at: m && m.nextAt ? m.nextAt : 0
        readonly property double remaining: Math.max(0, at - anime.now)
        readonly property bool airing: at > anime.now
        x: Theme.screenWidth - Theme.margin - width; y: 170
        width: 470; height: 230
        opacity: anime.row <= 0 && itemAiring ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Theme.base } }
        // each new show rises in, as the info does
        property real rise: 0
        transform: Translate { y: countdown.rise }
        onMChanged: { riseIn.restart() }
        SequentialAnimation {
            id: riseIn
            NumberAnimation { target: countdown; property: "rise"; to: 14; duration: 1 }
            NumberAnimation { target: countdown; property: "rise"; to: 0; duration: 520; easing.type: Theme.ease }
        }
        function part(n, unit) { return { n: n, unit: unit } }
        readonly property var parts: {
            var s = Math.floor(remaining), d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), mi = Math.floor(s % 3600 / 60);
            return d ? [part(d, "d"), part(h, "h"), part(mi, "m")] : h ? [part(h, "h"), part(mi, "m")] : [part(Math.max(1, mi), "m")];
        }
        Column {
            anchors.right: parent.right
            spacing: 6
            Text {
                anchors.right: parent.right
                text: countdown.m ? "Episode " + countdown.m.nextEpisode : ""
                color: Theme.inkDim; font.family: Theme.face; font.pixelSize: 28; font.weight: Font.Medium
            }
            Row {
                anchors.right: parent.right
                spacing: 18
                Repeater {
                    model: countdown.parts.length
                    Row {
                        spacing: 4
                        Text {
                            text: countdown.parts[index].n
                            color: Theme.ink; font.family: Theme.face; font.pixelSize: 96; font.weight: Font.Bold
                        }
                        Text {
                            anchors.baseline: parent.children[0].baseline
                            text: countdown.parts[index].unit
                            color: Theme.inkDim; font.family: Theme.face; font.pixelSize: 40; font.weight: Font.Medium
                        }
                    }
                }
            }
            // the week since the last episode, filling towards the next, in the show's own colour
            Item {
                anchors.right: parent.right
                width: 420; height: 8
                Rectangle { anchors.fill: parent; radius: 4; color: "#33ffffff" }
                Rectangle {
                    height: parent.height; radius: 4
                    width: parent.width * Math.max(0.03, 1 - Math.min(1, countdown.remaining / 604800))
                    color: countdown.m && countdown.m.color ? countdown.m.color : Theme.ink
                    Behavior on width { NumberAnimation { duration: 600; easing.type: Theme.ease } }
                }
            }
            Text {
                anchors.right: parent.right
                topPadding: 8
                text: countdown.airing ? new Date(countdown.at * 1000).toLocaleString(Qt.locale(), "dddd HH:mm") : ""
                color: Theme.inkSoft; font.family: Theme.face; font.pixelSize: 28; font.weight: Font.Medium
            }
        }
    }

    // ---- the controls -------------------------------------------------------------------------------------
    // in the flow under the info, or in the tab bar's place once the rows are up
    FocusScope {
        id: controls
        z: 2                                     // the rows pass under it once it's at the top
        x: Theme.margin
        y: anime.scrolled ? 44 : 560
        width: bars.width; height: 64
        focus: anime.row < 0
        Behavior on y { NumberAnimation { duration: 480; easing.type: Theme.ease } }
        readonly property var order: anime.view === "schedule" ? [viewBar, formatBar, genreBar] : [viewBar, formatBar, sortBar, genreBar]
        property int at: 0
        function go(step) {
            var i = order.indexOf(order[at]) + step;
            if (i < 0 || i >= order.length) return;
            at = i; order[i].forceActiveFocus();
        }
        onActiveFocusChanged: if (activeFocus && !anime.genreMenu) order[Math.min(at, order.length - 1)].forceActiveFocus()
        Row {
            id: bars
            spacing: 22
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: anime.catalog ? anime.catalog.seasonName : ""
                rightPadding: 10
                color: Theme.ink; font.family: Theme.face; font.pixelSize: 34; font.weight: Font.Bold
            }
            SegmentedBar {
                id: viewBar
                source: anime.glassSource; preblurred: true
                sx: controls.x + x; sy: controls.y + y
                barHeight: 64; fontSize: 22; segmentPad: 38; shadow: anime.scrolled ? 0.8 : 0
                model: anime.views.map(function (v) { return v[0] })
                onCurrentIndexChanged: anime.view = anime.views[currentIndex][1]
            }
            SegmentedBar {
                id: formatBar
                source: anime.glassSource; preblurred: true
                sx: controls.x + x; sy: controls.y + y
                barHeight: 64; fontSize: 22; segmentPad: 38; shadow: anime.scrolled ? 0.8 : 0
                model: anime.formats.map(function (v) { return v[0] })
                onCurrentIndexChanged: anime.format = anime.formats[currentIndex][1]
            }
            SegmentedBar {
                id: sortBar
                source: anime.glassSource; preblurred: true
                sx: controls.x + x; sy: controls.y + y
                barHeight: 64; fontSize: 22; segmentPad: 38; shadow: anime.scrolled ? 0.8 : 0
                model: anime.sorts.map(function (v) { return v[0] })
                // the schedule is in air-time order: the order has no say there
                opacity: anime.view === "schedule" ? 0.3 : 1
                Behavior on opacity { NumberAnimation { duration: Theme.base } }
                onCurrentIndexChanged: anime.sort = anime.sorts[currentIndex][1]
            }
            SegmentedBar {
                id: genreBar
                source: anime.glassSource; preblurred: true
                sx: controls.x + x; sy: controls.y + y
                barHeight: 64; fontSize: 22; segmentPad: 38; shadow: anime.scrolled ? 0.8 : 0
                model: [{ label: anime.genre || "All genres", icon: "" }]
                Keys.onReturnPressed: anime.genreMenu = true
                Keys.onEnterPressed: anime.genreMenu = true
            }
        }
        Keys.onLeftPressed: go(-1)
        Keys.onRightPressed: go(1)
        Keys.onUpPressed: anime.exitTop()
        Keys.onDownPressed: if (anime.rows.length) anime.row = 0
    }

    // ---- the rows --------------------------------------------------------------------------------------------
    SequentialAnimation {
        id: swap
        NumberAnimation { target: list; property: "opacity"; to: 0; duration: 140; easing.type: Easing.InQuad }
        ScriptAction { script: { anime.apply(); list.rise = 28 } }
        ParallelAnimation {
            NumberAnimation { target: list; property: "opacity"; to: 1; duration: 320; easing.type: Theme.ease }
            NumberAnimation { target: list; property: "rise"; to: 0; duration: 420; easing.type: Theme.ease }
        }
    }
    Item {
        id: list
        property real rise: 0
        transform: Translate { y: list.rise }
        width: anime.width; height: anime.height
        readonly property int stride: 430
        readonly property int rowTop: 650
        // once the controls have gone up, the focused row sits just under them with two more below it,
        // and the rows above have gone
        property real scrollY: anime.row <= 0 ? 0 : rowTop + anime.row * stride - 160
        Behavior on scrollY { NumberAnimation { duration: 480; easing.type: Theme.ease } }
        readonly property int slots: 4
        readonly property int first: Math.max(0, Math.floor((scrollY - rowTop) / stride))
        Repeater {
            model: list.slots
            FocusScope {
                id: slot
                readonly property int idx: list.first + ((index - list.first) % list.slots + list.slots) % list.slots
                readonly property var r: idx < anime.rows.length ? anime.rows[idx] : null
                readonly property bool schedule: anime.view === "schedule"
                visible: r !== null
                y: list.rowTop + idx * list.stride - list.scrollY
                width: anime.width; height: list.stride
                focus: anime.row === idx
                opacity: anime.row > 0 && idx < anime.row ? 0 : 1
                Behavior on opacity { NumberAnimation { duration: Theme.base } }
                Row {
                    x: Theme.margin
                    visible: slot.schedule
                    spacing: 16
                    Text { text: slot.r ? slot.r.title : ""; color: Theme.ink; font.family: Theme.face; font.pixelSize: 30; font.weight: Font.DemiBold }
                    Text { anchors.baseline: parent.children[0].baseline; text: slot.r ? slot.r.date : ""; color: Theme.inkDim; font.family: Theme.face; font.pixelSize: 24; font.weight: Font.Medium }
                }
                CardStrip {
                    id: strip
                    y: slot.schedule ? 108 : 54
                    width: anime.width
                    focus: true
                    model: slot.r ? slot.r.items : []
                    slides: slot.schedule
                    nextLabels: false
                    cardWidth: slot.schedule ? 384 : 190
                    cardHeight: slot.schedule ? 216 : 285
                    spacing: 36
                    showFocus: activeFocus
                    onCurrentIndexChanged: if (activeFocus) anime.column = currentIndex
                    onActivated: anime.activated(model[cardIndex])
                }
                onActiveFocusChanged: if (activeFocus) strip.jumpTo(Math.min(anime.column, strip.count - 1))
            }
        }
    }

    // the genres, by their bar and over the rows
    Rectangle {
        id: genrePanel
        z: 3
        readonly property bool open: anime.genreMenu
        // above the bar while it sits under the info (the rows fill the space under it), below once it's
        // at the top
        x: controls.x + genreBar.x + genreBar.width - width
        y: anime.scrolled ? controls.y + controls.height + 16 : controls.y - height - 16
        width: 420; height: genres.implicitHeight + 32; radius: 32
        color: "#f0141418"; border.width: 1; border.color: "#26ffffff"
        opacity: open ? 1 : 0; scale: open ? 1 : 0.92; transformOrigin: anime.scrolled ? Item.TopRight : Item.BottomRight
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: 200 } }
        Behavior on scale { NumberAnimation { duration: 340; easing.type: Theme.spring; easing.overshoot: 1.3 } }
        MenuList {
            id: genres
            x: 16; y: 16; width: parent.width - 32
            maxRows: 5                                          // clear of the tab bar above
            focus: genrePanel.open
            shown: genrePanel.open
            model: [{ label: "All genres", checked: anime.genre === "" }].concat((anime.catalog ? anime.catalog.seasonGenres : []).map(function (g) { return { label: g, checked: anime.genre === g } }))
            onTriggered: { anime.genre = rowIndex === 0 ? "" : anime.catalog.seasonGenres[rowIndex - 1]; anime.genreMenu = false }
        }
        onOpenChanged: if (open) { genres.currentIndex = anime.genre ? anime.catalog.seasonGenres.indexOf(anime.genre) + 1 : 0; genres.follow(true); genres.forceActiveFocus() } else if (anime.row < 0) genreBar.forceActiveFocus()
    }

    Latch { id: noticeShown; value: anime.notice; live: anime.notice !== "" }
    Chip {
        z: 4
        anchors.horizontalCenter: parent.horizontalCenter; y: Theme.screenHeight - 120
        kind: "solid"; size: 24; text: noticeShown.current || ""
        opacity: anime.notice ? 1 : 0; visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Theme.base } }
    }

    Keys.onUpPressed: if (row > 0) row--; else if (row === 0) row = -1
    Keys.onDownPressed: if (row < rows.length - 1) row++
    Keys.onPressed: {
        if (!Remote.isBack(event.key)) return;
        if (genreMenu) { genreMenu = false; event.accepted = true }
        else if (row >= 0) { row = -1; event.accepted = true }
    }
}
