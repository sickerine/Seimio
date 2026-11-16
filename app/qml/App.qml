// The app window. State lives here and nowhere else:
//   layer        which screen has the remote: home | tabs | show | title | menu | streams | player
//   focusItem    the title the remote is on (from Home), changes instantly
//   displayItem  the one title the backdrop, info and the title pages render; it changes only through
//                commit(). Moving focus commits once it settles, so key presses stay light; opening
//                anything commits first, so nothing opens on a stale title.
// Screens and controls handle their own keys (Qt focus scopes); a key nobody handles reaches the root
// here, which handles Back and moving between the tab bar and Home.
import QtQuick 2.12
import Eos.Window 0.1
import Seimio.UI 1.0
import Seimio.Native 1.0
import Seimio.Data 1.0

WebOSWindow {
    id: app
    appId: "com.seimio.tv"
    // native apps only get Back and the rest when the window asks for them
    keyMask: WebOSWindow.KeyMaskBack | WebOSWindow.KeyMaskInfo | WebOSWindow.KeyMaskOk | WebOSWindow.KeyMaskLeft | WebOSWindow.KeyMaskRight | WebOSWindow.KeyMaskUp | WebOSWindow.KeyMaskDown | WebOSWindow.KeyMaskDefault
    visible: true
    width: Theme.screenWidth; height: Theme.screenHeight
    color: watching ? "transparent" : "black"

    property string layer: "home"
    // today's date ("YYYY-MM-DD"), checked every minute so the calendar moves on at midnight; previews
    // set it to a fixed day
    property string today: Qt.formatDate(new Date(), "yyyy-MM-dd")
    Timer { interval: 60000; running: true; repeat: true; onTriggered: { var t = Qt.formatDate(new Date(), "yyyy-MM-dd"); if (t !== app.today) app.today = t } }
    readonly property bool onHome: layer === "home" || layer === "tabs" || layer === "menu"
    readonly property var focusItem: home.focusItem
    property var displayItem: null
    function commit() { settle.stop(); if (displayItem !== focusItem) displayItem = focusItem }
    onFocusItemChanged: { if (!displayItem) commit(); else settle.restart(); probe.captures(); if (home.row === 1) probe.act(home.dayOpen ? "day move" : "calendar move") }
    Timer { id: settle; interval: 280; onTriggered: app.commit() }
    // opening or closing a calendar day changes the whole screen, so it commits at once
    Connections { target: home; onDayOpenChanged: { app.commit(); probe.act(home.dayOpen ? "day open" : "day close") } }
    // the show page for the selected Continue Watching title is built once Home has been still for a
    // moment (after the backdrop and info have changed), so opening it costs nothing. Not from the
    // calendar: resting on its days would build a page each time (~25 ms) for an open that's rarer there
    onDisplayItemChanged: prepareShow.restart()
    Timer {
        id: prepareShow; interval: 1200
        onTriggered: { if (app.displayItem && app.onHome && home.row === 0 && catalog.episodeCount(app.displayItem.id) > 1) showPage.load(app.displayItem, app.showData(app.displayItem.id)) }
    }

    function open() {
        commit();
        // the title page is for a movie, or a show whose whole run is one season with one episode; any
        // other show gets the show page, even when one of its seasons has a single episode
        if (displayItem && catalog.episodeCount(displayItem.id) > 1) { showPage.open(displayItem, showData(displayItem.id)); layer = "show" }
        else { titlePage.open(displayItem); layer = "title" }
    }
    // MOCK: the stream picker and player, on lab data (app/art/streams.json, tools/fetch-streams.mjs)
    property var streamData: ({})
    property string pageLayer: "title"          // the page the picker returns to
    function openStreams() { pageLayer = layer; streamPage.open(displayItem, streamData[displayItem.id]); layer = "streams" }
    readonly property bool watching: layer === "player" && player.playing
    function openMenu() { commit(); layer = "menu"; probe.captures() }
    onLayerChanged: { probe.act(layer); probe.captures() }

    // effects that are needed later are drawn invisibly for a moment at startup, so their shaders
    // compile before anyone opens them
    property bool warming: true
    Timer { running: catalog.continueWatching.length > 0; interval: 600; onTriggered: app.warming = false }

    // the data, held natively (Seimio.Data); a show's seasons come over to QML once and are kept, so the
    // show page sees the same object again and needn't rebuild
    Catalog { id: catalog; base: Qt.resolvedUrl("../art/"); onLoaded: app.shows = ({}) }
    property var shows: ({})
    function showData(id) { if (!shows[id]) shows[id] = catalog.show(id); return shows[id] }
    WindowTools { id: tools }
    LabProbe {
        id: probe; window: app
        stateOf: function () {
            function id(x) { return x ? x.id || x.name || "?" : null }
            return { layer: app.layer, row: home.row, dayOpen: home.dayOpen, scrolled: home.scrolled,
                     focusItem: id(app.focusItem), displayItem: id(app.displayItem),
                     info: { item: id(info.item), m: id(info.m), pending: id(info.pending), fadeIn: info.fadeIn, away: info.away,
                             visible: info.visible, opacity: info.opacity, y: info.y, busy: info.busy },
                     player: { playing: player.playing, paused: player.paused, failure: player.failure, position: player.position, duration: player.duration, seen: player.seen } };
        }
        onAutopop: if (app.layer === "menu") app.layer = "home"; else app.openMenu()
        onOpenMenu: app.openMenu()
    }

    FocusScope {
        id: root
        anchors.fill: parent
        focus: true

        // ---- the scene: everything glass and frost can blur ----
        Item {
            id: scene
            anchors.fill: parent
            opacity: app.watching ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: 500 } }

            Backdrop {
                id: hero
                width: parent.width; height: parent.height
                target: app.displayItem ? app.displayItem.backdrop : ""
                // parallax: the backdrop drifts a little against moves along a row
                pan: app.onHome && (home.row === 0 || home.dayOpen) ? Math.min(8, home.row === 0 ? home.column : home.dayColumn) * 5 : 0
                Behavior on pan { NumberAnimation { id: panning; duration: 700; easing.type: Theme.ease } }
                onCrossfadeStarted: probe.act("hero crossfade")
            }
            // the backdrop frosts on Home below the first row, where the info has stepped aside and the art
            // is only a background
            Frost {
                id: backdropFrost
                anchors.fill: parent
                source: hero
                frozen: true; sourceBusy: hero.busy || panning.running
                opacity: (app.onHome && home.scrolled && !home.dayOpen) || app.layer === "streams" || app.layer === "player" ? 1 : (app.warming ? 0.003 : 0)
                Behavior on opacity { NumberAnimation { duration: 520; easing.type: Easing.InOutQuad } }
            }
            Scrim {
                anchors.fill: parent
                readonly property bool page: app.layer === "show" || app.layer === "title" || app.layer === "streams" || home.dayOpen
                side: page ? 0.95 : 0.85
                sideMid: page ? 0.35 : 0.15
                footMid: page ? 0.7 : 0.55
            }
            HeroInfo {
                id: info
                x: Theme.margin
                // hidden on the calendar, so it doesn't swap to every day there (logo loads, text layout)
                item: home.scrolled && app.onHome && !home.dayOpen ? null : app.displayItem
                // on the title page it moves down to sit just above the actions
                y: app.layer === "title" ? titlePage.actionsY - 40 - contentHeight : home.dayOpen ? 260 : (home.scrolled ? 90 : 150)
                // it only glides while on screen; hidden, it takes its new place at once and fades in there
                Behavior on y { enabled: info.visible; NumberAnimation { duration: 460; easing.type: Theme.ease } }
                // below Home's first row, and on the show page, the info steps aside
                property real away: (home.scrolled && app.onHome && !home.dayOpen) || app.layer === "show" || app.layer === "streams" || app.layer === "player" ? 1 : 0
                Behavior on away { NumberAnimation { duration: 380; easing.type: Theme.ease } }
                opacity: 1 - away
                visible: away < 1
            }
            ShowScreen {
                id: showPage
                focus: app.layer === "show"
                onPlay: app.openStreams()
                active: app.layer === "show"
                source: hero
                onZoneChanged: probe.act("show " + ["actions", "seasons", "episodes"][zone])
            }
            TitleScreen {
                id: titlePage
                focus: app.layer === "title"
                onPlay: app.openStreams()
                active: app.layer === "title"
            }
            HomeScreen {
                id: home
                width: parent.width; height: parent.height
                focus: app.layer === "home"
                shown: app.onHome
                holdFocus: app.layer === "menu"
                continueWatching: catalog.continueWatching
                catalog: catalog
                glassSource: backdropFrost
                today: app.today
                onActivated: app.open()
                onHeld: app.openMenu()
                onExitTop: app.layer = "tabs"
                onColumnChanged: probe.act("row move")
                onRowChanged: probe.act("row change")
            }
        }

        // quick actions frost and dim everything except the focused card; the scene is captured once
        // when the menu opens, and again only while the backdrop or info is still changing
        Frost {
            anchors.fill: parent
            source: scene
            darken: 0.55
            frozen: true; sourceBusy: hero.busy || info.busy
            hole: home.focusRect
            opacity: app.layer === "menu" ? 1 : (app.warming ? 0.003 : 0)
            Behavior on opacity { NumberAnimation { duration: 320; easing.type: Easing.InOutQuad } }
        }
        SegmentedBar {
            id: tabs
            focus: app.layer === "tabs"
            source: scene
            model: ["Home", "Anime", "Movies", "Series", "Library", { icon: "search" }]
            // the tab bar belongs to the top of Home; pages and the calendar move it away
            readonly property bool shown: app.onHome && !home.scrolled
            shadow: shown ? 0.8 : 0
            x: (parent.width - width) / 2; y: shown ? 44 : -100
            opacity: app.layer === "menu" ? 0.3 : 1
            Behavior on y { NumberAnimation { duration: Theme.slow; easing.type: Theme.ease } }
            Behavior on opacity { NumberAnimation { duration: 300 } }
            onCurrentIndexChanged: probe.act("tabs")
        }
        StreamScreen {
            id: streamPage
            focus: app.layer === "streams"
            active: app.layer === "streams"
            source: backdropFrost
            onPlay: { player.start(stream, app.displayItem); app.layer = "player" }
        }
        PlayerScreen {
            id: player
            window: app
            focus: app.layer === "player"
            active: app.layer === "player"
        }
        QuickMenu {
            id: menu
            focus: app.layer === "menu"
            open: app.layer === "menu"
            source: scene
            x: Theme.margin + home.focusCardWidth * 1.1 + 44
            y: home.focusRect.y + 10
            onTriggered: app.layer = "home"
        }

        Keys.onPressed: {
            if (Remote.isBack(event.key) && app.layer === "player") { event.accepted = true; player.stop(); streamPage.starting = -1; app.layer = "streams" }
            else if (Remote.isBack(event.key) && app.layer === "streams") { event.accepted = true; app.layer = app.pageLayer }
            else if (Remote.isBack(event.key) && app.layer !== "home") { event.accepted = true; app.layer = "home" }
            else if (event.key === Qt.Key_Down && app.layer === "tabs") { event.accepted = true; app.layer = "home" }
        }
    }

    Component.onCompleted: {
        // Back reaches the app only with this window property; without it webOS opens the exit menu
        tools.setWindowProperty(app, "_WEBOS_ACCESS_POLICY_KEYS_BACK", "true");
        requestActivate();
        // MOCK: the picker's lab streams
        var x = new XMLHttpRequest();
        x.onreadystatechange = function () { if (x.readyState === XMLHttpRequest.DONE && x.responseText) app.streamData = JSON.parse(x.responseText) };
        x.open("GET", Qt.resolvedUrl("../art/streams.json")); x.send();
    }
}
