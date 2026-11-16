// MOCK, for agreeing the design: the streams for a title, to pick one to play. The filter bar sits where
// Home's tabs are (anime: All, Seasonal, BD; anything else: All, Supported, Unsupported, starting on
// Supported), the title and a summary of what's listed on the left, the streams on the right. Anime lists
// by seeders, anything else keeps Torrentio's quality-first order (as in the patched Stremio app).
// open(item, entry) shows the loading rows, then the streams (entry is from app/art/streams.json; the lab
// data arrives after a pause so the loading state shows). OK on a stream emits play(stream).
import QtQuick 2.12
import Seimio.UI 1.0

FocusScope {
    id: page
    property bool active: false
    property var item: null
    property var entry: null
    property Item source                 // what the filter bar's glass shows (already blurred)
    property bool loading: true
    property bool fresh: false           // rows deal in one after another while true
    property var rows: []
    property int starting: -1            // the row that's starting to play
    signal play(var stream)
    width: Theme.screenWidth; height: Theme.screenHeight
    opacity: active ? 1 : 0
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: page.active ? 240 : 200 } }

    readonly property bool anime: !!(entry && entry.anime)
    readonly property var kinds: anime ? ["All", "Seasonal", "BD"] : ["All", "Supported", "Unsupported"]
    readonly property var captions: anime ? ["streams", "seasonal releases", "Blu-ray releases"] : ["streams", "play here", "won't play here"]
    readonly property int kind: bar.currentIndex
    property var pendingEntry: null

    function open(title, data) {
        item = title; entry = null; rows = []; loading = true; starting = -1;
        pendingEntry = data || { anime: title && title.id.indexOf("kitsu:") === 0, streams: [] };
        bar.currentIndex = pendingEntry.anime ? 0 : 1;
        list.currentIndex = 0; list.focus = true;
        arrive.restart();
    }
    Timer { id: arrive; interval: 1100; onTriggered: { page.entry = page.pendingEntry; page.loading = false; page.refilter() } }
    onKindChanged: if (!loading) refilter()

    function refilter() {
        var all = entry ? entry.streams : [], out;
        if (anime) out = kind === 1 ? all.filter(function (s) { return s.seasonal }) : kind === 2 ? all.filter(function (s) { return s.bd }) : all.slice();
        else out = kind === 1 ? all.filter(function (s) { return s.support !== "unsupported" }) : kind === 2 ? all.filter(function (s) { return s.support === "unsupported" }) : all.slice();
        if (anime) out.sort(function (a, b) { return b.seeders - a.seeders });
        fresh = true; dealt.restart();
        rows = out;
        list.currentIndex = 0; list.positionViewAtBeginning();
    }
    Timer { id: dealt; interval: 900; onTriggered: page.fresh = false }

    // share of each resolution among the listed streams, for the summary bar
    readonly property var mix: {
        var n = { "4K": 0, "1080p": 0, "720p": 0, other: 0 };
        for (var i = 0; i < rows.length; i++) { var r = rows[i].res; if (n[r] !== undefined) n[r]++; else n.other++ }
        return n;
    }

    Keys.onPressed: {
        if (event.key === Qt.Key_Up && list.activeFocus && list.currentIndex === 0) { bar.focus = true; event.accepted = true }
        else if (event.key === Qt.Key_Down && bar.activeFocus && rows.length) { list.focus = true; event.accepted = true }
    }

    // ---- filter bar, where Home's tabs are ----
    SegmentedBar {
        id: bar
        source: page.source; preblurred: true
        model: page.kinds
        shadow: 0.8
        x: (parent.width - width) / 2; y: page.active ? 44 : -100
        Behavior on y { NumberAnimation { duration: Theme.slow; easing.type: Theme.ease } }
    }

    // ---- the title, and what's listed ----
    Reveal {
        shown: page.active; delay: 80
        x: Theme.margin; y: 200
        Column {
            spacing: 26
            TitleArt { width: 480; height: 150; logo: page.item && page.item.logo ? page.item.logo : ""; name: page.item ? page.item.name : ""; nameSize: 56 }
            Row {
                spacing: 10
                Chip { visible: !!(page.item && page.item.episode); kind: "solid"; icon: "play"; text: page.item && page.item.episode ? page.item.episode : "" }
                Chip { visible: !!(page.item && page.item.year); text: page.item && page.item.year ? page.item.year : "" }
            }
            Item { width: 1; height: 24 }
            // how many, and their resolutions as one bar
            Item {
                width: 460; height: 150
                opacity: page.loading || !page.rows.length ? 0 : 1
                Behavior on opacity { NumberAnimation { duration: Theme.base } }
                Text {
                    id: count
                    text: page.rows.length; color: Theme.ink
                    font.family: Theme.face; font.pixelSize: 84; font.weight: Font.Bold
                }
                Text {
                    anchors.left: count.right; anchors.leftMargin: 16; anchors.baseline: count.baseline
                    text: page.captions[page.kind] || ""; color: Theme.inkDim
                    font.family: Theme.face; font.pixelSize: 30; font.weight: Font.Medium
                }
                Row {
                    id: mixBar
                    y: 112; width: 460; height: 10; spacing: 4
                    readonly property real unit: page.rows.length ? (width - spacing * 3) / page.rows.length : 0
                    Repeater {
                        model: [["4K", Theme.rating], ["1080p", "#f2ffffff"], ["720p", "#80ffffff"], ["other", "#40ffffff"]]
                        Rectangle {
                            height: 10; radius: 5; color: modelData[1]
                            width: Math.max(0, (page.mix[modelData[0]] || 0) * mixBar.unit)
                            Behavior on width { NumberAnimation { duration: Theme.slow; easing.type: Theme.ease } }
                        }
                    }
                }
                Row {
                    y: 136; spacing: 22
                    Repeater {
                        model: ["4K", "1080p", "720p"]
                        Text {
                            visible: (page.mix[modelData] || 0) > 0
                            text: modelData + "  " + (page.mix[modelData] || 0); color: Theme.inkDim
                            font.family: Theme.face; font.pixelSize: 20; font.weight: Font.Medium
                        }
                    }
                }
            }
        }
    }

    // ---- the streams ----
    readonly property int rowHeight: 124
    readonly property int listX: 700
    readonly property int listWidth: 1100

    // loading: rows of the final size, breathing until the streams arrive
    Column {
        x: page.listX; y: 180; spacing: 14
        opacity: page.loading && page.active ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Theme.base } }
        Repeater {
            model: 6
            Rectangle {
                width: page.listWidth; height: page.rowHeight; radius: 30
                color: "#12ffffff"
                SequentialAnimation on opacity {
                    running: page.loading && page.active; loops: Animation.Infinite
                    PauseAnimation { duration: index * 90 }
                    NumberAnimation { from: 1; to: 0.45; duration: 700; easing.type: Easing.InOutSine }
                    NumberAnimation { from: 0.45; to: 1; duration: 700; easing.type: Easing.InOutSine }
                }
                Rectangle { x: 34; y: 34; width: 70; height: 26; radius: 13; color: "#1fffffff" }
                Rectangle { x: 180; y: 34; width: 560 - index * 40; height: 24; radius: 12; color: "#1fffffff" }
                Rectangle { x: 180; y: 74; width: 300 + (index % 3) * 50; height: 18; radius: 9; color: "#14ffffff" }
            }
        }
    }

    // nothing to list
    Column {
        x: page.listX + 60; y: 360; spacing: 14
        opacity: !page.loading && page.active && page.rows.length === 0 ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.base } }
        Text {
            text: page.entry && page.entry.streams.length ? "No " + (page.captions[page.kind] === "streams" ? "streams" : page.kinds[page.kind].toLowerCase() + " streams") : "No streams yet"
            color: Theme.ink; font.family: Theme.face; font.pixelSize: 40; font.weight: Font.DemiBold
        }
        Text {
            width: 900; wrapMode: Text.WordWrap
            text: page.entry && page.entry.streams.length ? "Try All to see every release." : "Nobody has released " + (page.item && page.item.episode ? page.item.episode : "this") + " yet. It shows here once someone does."
            color: Theme.inkDim; font.family: Theme.face; font.pixelSize: 26
        }
    }

    ListView {
        id: list
        x: page.listX; y: 180; width: page.listWidth; height: Theme.screenHeight - y
        clip: true
        spacing: 14
        model: page.rows.length
        opacity: page.loading ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: Theme.base } }
        // the focus rests in the upper rows and the list moves under it
        highlightRangeMode: ListView.ApplyRange
        preferredHighlightBegin: 0; preferredHighlightEnd: (page.rowHeight + spacing) * 3
        highlightMoveDuration: 320
        highlightFollowsCurrentItem: true
        highlight: Rectangle {
            radius: 30; color: list.activeFocus ? "#3dffffff" : "#14ffffff"
            border.width: 1; border.color: "#33ffffff"
            Behavior on color { ColorAnimation { duration: Theme.fast } }
        }
        Keys.onReturnPressed: page.choose()
        Keys.onEnterPressed: page.choose()

        delegate: Item {
            id: row
            readonly property var s: page.rows[index] || ({})
            readonly property bool current: ListView.isCurrentItem && list.activeFocus
            width: page.listWidth; height: page.rowHeight
            Reveal {
                shown: true
                delay: page.fresh ? Math.min(index, 7) * 45 : 0
                duration: page.fresh ? Theme.slow : 1
                dy: 18
                width: row.width; height: row.height
                opacity: t * (row.s.support === "unsupported" && !row.current ? 0.5 : 1)

                // resolution, and which HDR
                Column {
                    x: 34; y: 26; width: 120; spacing: 8
                    Text {
                        text: row.s.res || "SD"
                        color: row.s.res === "4K" ? Theme.rating : row.s.res === "1080p" ? Theme.ink : Theme.inkDim
                        font.family: Theme.face; font.pixelSize: row.s.res === "4K" ? 40 : 30; font.weight: Font.Bold
                    }
                    Chip { visible: !!row.s.hdr; size: 16; kind: "tint"; tint: row.s.hdr === "DV" ? "#8b5cf6" : "#e8590c"; text: row.s.hdr || "" }
                }
                Text {
                    x: 180; y: 22; width: page.listWidth - 180 - 40
                    text: page.shortName(row.s.release || "")
                    elide: Text.ElideRight; color: Theme.ink; textFormat: Text.PlainText
                    font.family: Theme.face; font.pixelSize: 27; font.weight: Font.DemiBold
                }
                Row {
                    x: 180; y: 66; spacing: 8
                    // why it won't play here, or that it's starting
                    Chip {
                        visible: row.s.support === "unsupported" || page.starting === index
                        size: 18; kind: page.starting === index ? "solid" : "tint"; tint: "#b42318"
                        icon: page.starting === index ? "play" : ""
                        text: page.starting === index ? "Starting" : "No " + (row.s.why || "audio")
                        SequentialAnimation on opacity { running: page.starting === index; loops: Animation.Infinite
                            NumberAnimation { to: 0.5; duration: 500 } NumberAnimation { to: 1; duration: 500 } }
                    }
                    Chip { size: 18; icon: "up"; text: row.s.seeders || 0 }
                    Chip { visible: !!row.s.size; size: 18; text: row.s.size || "" }
                    Repeater { model: row.s.audio || []; Chip { size: 18; text: modelData } }
                    Chip { visible: !!row.s.bd; size: 18; kind: "tint"; tint: "#0f766e"; text: "BD" }
                    Chip { visible: !!row.s.version; size: 18; kind: "tint"; tint: "#7c3aed"; text: row.s.version || "" }
                    Repeater { model: (row.s.langs || []).slice(0, 2); Chip { size: 18; text: modelData } }
                    Chip { visible: !!row.s.file; size: 18; text: "Pack" }
                    Chip { visible: row.s.cached === false; size: 18; icon: "down"; text: "Not cached" }
                }
            }
        }
    }

    // a release name without the title in front: from just after the episode tag or year, when that
    // leaves enough to tell releases apart
    function shortName(name) {
        var t = name.replace(/\./g, " ");
        var m = /\bS\d{1,2}E\d{1,4}\b|\[S\d{1,2}E\d{1,4}\]|\s-\s\d{1,4}\b|[(\[ ](19|20)\d\d[)\] ]/i.exec(t);
        if (!m || m.index < 4 || m.index > t.length * 0.6) return t;
        var rest = t.slice(m.index + m[0].length).replace(/^[\s\]\)\-:]+/, "");
        return rest.length > 12 ? rest : t;
    }

    function choose() {
        var s = rows[list.currentIndex];
        if (!s || starting >= 0) return;
        starting = list.currentIndex;
        play(s);
    }
}
