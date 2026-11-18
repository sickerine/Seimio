// The streams for a title, to pick one to play. The filter bar sits where Home's tabs are (anime: All,
// Seasonal, BD; anything else: All, Supported, Unsupported, starting on Supported), the title and a
// summary of what's listed on the left, the streams on the right. The list, its filter and order live in
// `streams` (Seimio.Data Streams). open() fetches a video's streams; show() lists what `streams` already
// holds (after the AI pick gave up), with `note` saying why. OK on a stream resolves and plays it.
import QtQuick 2.12
import Seimio.UI 1.0

FocusScope {
    id: page
    property bool active: false
    property var item: null
    property var streams                 // Seimio.Data Streams
    property Item source                 // what the filter bar's glass shows (already blurred)
    property string label: ""            // the episode, "S2 E3" or "E7"; empty for a movie
    property string note: ""             // why the list opened instead of playing
    property bool fresh: false           // rows deal in one after another while true
    property int starting: -1            // the row that's starting to play
    width: Theme.screenWidth; height: Theme.screenHeight
    opacity: active ? 1 : 0      // holds: the title and list stay until the next open()
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: page.active ? 240 : 200 } }

    readonly property bool loading: streams.loading
    readonly property int count: list.count
    readonly property var kinds: streams.anime ? ["All", "Seasonal", "BD"] : ["All", "Supported", "Unsupported"]
    readonly property var captions: streams.anime ? ["streams", "seasonal releases", "Blu-ray releases"] : ["streams", "play here", "won't play here"]

    function open(title, target) { show(title, target.label, ""); streams.fetch(target.type, target.id) }
    function show(title, episodeLabel, why) {
        item = title; label = episodeLabel; note = why; starting = -1;
        list.currentIndex = 0; list.focus = true;
        if (!loading) dealIn();
    }
    function dealIn() { fresh = true; dealt.restart(); list.currentIndex = 0; list.positionViewAtBeginning() }
    Timer { id: dealt; interval: 900; onTriggered: page.fresh = false }
    Connections {
        target: page.streams
        onListChanged: { if (bar.currentIndex !== page.streams.kind) bar.currentIndex = page.streams.kind; if (!page.loading) page.dealIn() }
        onPlayable: page.starting = -1
        onFailed: page.starting = -1
    }

    Keys.onPressed: {
        if (event.key === Qt.Key_Up && list.activeFocus && list.currentIndex === 0) { bar.focus = true; event.accepted = true }
        else if (event.key === Qt.Key_Down && bar.activeFocus && page.count) { list.focus = true; event.accepted = true }
    }

    // ---- filter bar, where Home's tabs are ----
    SegmentedBar {
        id: bar
        source: page.source; preblurred: true
        model: page.kinds
        onCurrentIndexChanged: page.streams.kind = currentIndex
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
                Chip { visible: page.label !== ""; kind: "solid"; icon: "play"; text: page.label }
                Chip { visible: !!(page.item && page.item.year); text: page.item && page.item.year ? page.item.year : "" }
            }
            Text {
                width: 460; wrapMode: Text.WordWrap; visible: page.note !== ""
                text: page.note; color: Theme.inkDim
                font.family: Theme.face; font.pixelSize: 24
            }
            // how many, and their resolutions as one bar
            Item {
                width: 460; height: 150
                opacity: page.loading || !page.count ? 0 : 1      // holds: the counts of the list, which stays until the new one is in
                Behavior on opacity { NumberAnimation { duration: Theme.base } }
                Text {
                    id: count
                    text: page.count; color: Theme.ink
                    font.family: Theme.face; font.pixelSize: 84; font.weight: Font.Bold
                }
                Text {
                    anchors.left: count.right; anchors.leftMargin: 16; anchors.baseline: count.baseline
                    text: page.captions[bar.currentIndex] || ""; color: Theme.inkDim
                    font.family: Theme.face; font.pixelSize: 30; font.weight: Font.Medium
                }
                Row {
                    id: mixBar
                    y: 112; width: 460; height: 10; spacing: 4
                    readonly property real unit: page.count ? (width - spacing * 3) / page.count : 0
                    Repeater {
                        model: [["4K", Theme.rating], ["1080p", "#f2ffffff"], ["720p", "#80ffffff"], ["other", "#40ffffff"]]
                        Rectangle {
                            height: 10; radius: 5; color: modelData[1]
                            width: Math.max(0, (page.streams.mix[modelData[0]] || 0) * mixBar.unit)
                            Behavior on width { NumberAnimation { duration: Theme.slow; easing.type: Theme.ease } }
                        }
                    }
                }
                Row {
                    y: 136; spacing: 22
                    Repeater {
                        model: ["4K", "1080p", "720p"]
                        Text {
                            visible: (page.streams.mix[modelData] || 0) > 0
                            text: modelData + "  " + (page.streams.mix[modelData] || 0); color: Theme.inkDim
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
        opacity: page.loading && page.active ? 1 : 0      // holds: fixed words
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
        opacity: !page.loading && page.active && page.count === 0 ? 1 : 0      // holds: the label stays until the next open()
        Behavior on opacity { NumberAnimation { duration: Theme.base } }
        Text {
            text: page.streams.failure ? "Couldn't load streams" : page.streams.total ? "No " + page.captions[bar.currentIndex] : "No streams yet"
            color: Theme.ink; font.family: Theme.face; font.pixelSize: 40; font.weight: Font.DemiBold
        }
        Text {
            width: 900; wrapMode: Text.WordWrap
            text: page.streams.failure ? page.streams.failure
                : page.streams.total ? "Try All to see every release."
                : "Nobody has released " + (page.label || "this") + " yet. It shows here once someone does."
            color: Theme.inkDim; font.family: Theme.face; font.pixelSize: 26
        }
    }

    ListView {
        id: list
        x: page.listX; y: 180; width: page.listWidth; height: Theme.screenHeight - y
        clip: true
        spacing: 14
        // rows exist only while the page is up, built once its streams are in: the player's AI pick fills
        // the same model, and building rows behind the video cost a 50-60 ms stall as it started
        model: page.active && !page.loading ? page.streams : null
        opacity: page.loading ? 0 : 1      // holds: the list stays until the new one is in
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
            readonly property bool current: ListView.isCurrentItem && list.activeFocus
            readonly property bool unsupported: model.support === "unsupported"
            // the static chips, made in C++ (inside a Repeater, `model` is its own, so read it here)
            readonly property var chips: model.chips || []
            width: page.listWidth; height: page.rowHeight
            // the row's content is made a few rows a frame (Qt's incubator, inside its frame budget) and
            // deals in as it's ready: made at once, a screenful cost 50-65 ms on the TV as the list came in
            Loader { asynchronous: true; width: row.width; height: row.height; sourceComponent: Component {
            Reveal {
                shown: true
                delay: page.fresh ? Math.min(index, 7) * 45 : 0
                duration: page.fresh ? Theme.slow : 1
                dy: 18
                width: row.width; height: row.height
                opacity: t * (row.unsupported && !row.current ? 0.5 : 1)      // holds: only dims a row; its words stay

                // resolution, and which HDR
                Column {
                    x: 34; y: 26; width: 120; spacing: 8
                    Text {
                        text: model.res || "SD"
                        color: model.res === "4K" ? Theme.rating : model.res === "1080p" ? Theme.ink : Theme.inkDim
                        font.family: Theme.face; font.pixelSize: model.res === "4K" ? 40 : 30; font.weight: Font.Bold
                    }
                    Chip { visible: !!model.hdr; size: 16; kind: "tint"; tint: model.hdr === "DV" ? "#8b5cf6" : "#e8590c"; text: model.hdr || "" }
                }
                Text {
                    x: 180; y: 22; width: page.listWidth - 180 - 40
                    text: model.shortName
                    elide: Text.ElideRight; color: Theme.ink; textFormat: Text.PlainText
                    font.family: Theme.face; font.pixelSize: 27; font.weight: Font.DemiBold
                }
                Row {
                    x: 180; y: 66; spacing: 8
                    // why it won't play here, or that it's starting
                    Chip {
                        visible: row.unsupported || page.starting === index
                        size: 18; kind: page.starting === index ? "solid" : "tint"; tint: "#b42318"
                        icon: page.starting === index ? "play" : ""
                        text: page.starting === index ? "Starting" : "No " + (model.why || "audio")
                        SequentialAnimation on opacity { running: page.starting === index; loops: Animation.Infinite
                            NumberAnimation { to: 0.5; duration: 500 } NumberAnimation { to: 1; duration: 500 } }
                    }
                    // the last AI pick for this video, to tell it apart
                    Chip { visible: model.aiPick; size: 18; kind: "tint"; tint: "#2563eb"; icon: "star"; text: "AI pick" }
                    Repeater {
                        model: row.chips
                        Chip {
                            size: 18; text: modelData.text; icon: modelData.icon
                            kind: modelData.tag ? "tint" : "glass"; tint: modelData.tag === "bd" ? "#0f766e" : "#7c3aed"
                        }
                    }
                }
            }
            } }
        }
    }

    function choose() {
        if (!count || starting >= 0) return;
        starting = list.currentIndex;
        streams.playRow(list.currentIndex);
    }
}
