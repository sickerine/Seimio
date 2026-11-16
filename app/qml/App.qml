// The app window. State lives here and nowhere else:
//   layer        which screen has the remote: home | tabs | show | title | menu
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

WebOSWindow {
    id: app
    appId: "com.seimio.tv"
    // native apps only get Back and the rest when the window asks for them
    keyMask: WebOSWindow.KeyMaskBack | WebOSWindow.KeyMaskInfo | WebOSWindow.KeyMaskOk | WebOSWindow.KeyMaskLeft | WebOSWindow.KeyMaskRight | WebOSWindow.KeyMaskUp | WebOSWindow.KeyMaskDown | WebOSWindow.KeyMaskDefault
    visible: true
    width: Theme.screenWidth; height: Theme.screenHeight
    color: "black"

    property string layer: "home"
    readonly property bool onHome: layer === "home" || layer === "tabs" || layer === "menu"
    readonly property var focusItem: home.focusItem
    property var displayItem: null
    function commit() { settle.stop(); if (displayItem !== focusItem) displayItem = focusItem }
    onFocusItemChanged: { if (!displayItem) commit(); else settle.restart(); probe.captures() }
    Timer { id: settle; interval: 280; onTriggered: app.commit() }
    // the show page for the selected title is built once Home has been still for a moment (after the
    // backdrop and info have changed), so opening it costs nothing
    onDisplayItemChanged: prepareShow.restart()
    Timer {
        id: prepareShow; interval: 1200
        onTriggered: { var show = app.displayItem && catalog.series[app.displayItem.id]; if (show && app.onHome) showPage.load(app.displayItem, show) }
    }

    function open() {
        commit();
        // the title page is for a movie, or a show whose whole run is one season with one episode; any
        // other show gets the show page, even when one of its seasons has a single episode
        var show = displayItem ? catalog.series[displayItem.id] : null;
        var episodes = show ? show.seasons.reduce(function (n, s) { return n + s.episodes.length }, 0) : 0;
        if (episodes > 1) { showPage.open(displayItem, show); layer = "show" }
        else { titlePage.open(displayItem); layer = "title" }
    }
    function openMenu() { commit(); layer = "menu"; probe.captures() }
    onLayerChanged: probe.act(layer)

    // effects that are needed later are drawn invisibly for a moment at startup, so their shaders
    // compile before anyone opens them
    property bool warming: true
    Timer { running: home.rows.length > 0; interval: 600; onTriggered: app.warming = false }

    LabCatalog { id: catalog }
    WindowTools { id: tools }
    LabProbe {
        id: probe; window: app
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

            Backdrop {
                id: hero
                width: parent.width; height: parent.height
                target: app.displayItem ? app.displayItem.backdrop : ""
                // parallax: the backdrop drifts a little against moves along a row
                pan: app.onHome ? Math.min(8, home.cols[home.row] || 0) * 5 : 0
                Behavior on pan { NumberAnimation { id: panning; duration: 700; easing.type: Theme.ease } }
                onCrossfadeStarted: probe.act("hero crossfade")
            }
            // the backdrop frosts on Home below the first row, where the info has stepped aside and the art
            // is only a background
            Frost {
                anchors.fill: parent
                source: hero
                frozen: true; sourceBusy: hero.busy || panning.running
                opacity: app.onHome && home.scrolled ? 1 : (app.warming ? 0.003 : 0)
                Behavior on opacity { NumberAnimation { duration: 520; easing.type: Easing.InOutQuad } }
            }
            Scrim {
                anchors.fill: parent
                readonly property bool page: app.layer === "show" || app.layer === "title"
                side: page ? 0.95 : 0.85
                sideMid: page ? 0.35 : 0.15
                footMid: page ? 0.7 : 0.55
            }
            HeroInfo {
                id: info
                x: Theme.margin
                item: app.displayItem
                // on the title page it moves down to sit just above the actions
                y: app.layer === "title" ? titlePage.actionsY - 40 - contentHeight : (home.scrolled ? 90 : 150)
                Behavior on y { NumberAnimation { duration: 460; easing.type: Theme.ease } }
                // below Home's first row, and on the show page, the info steps aside
                property real away: (home.scrolled && app.onHome) || app.layer === "show" ? 1 : 0
                Behavior on away { NumberAnimation { duration: 380; easing.type: Theme.ease } }
                opacity: 1 - away
                visible: away < 1
            }
            ShowScreen {
                id: showPage
                focus: app.layer === "show"
                active: app.layer === "show"
                source: hero
                onZoneChanged: probe.act("show " + ["actions", "seasons", "episodes"][zone])
            }
            TitleScreen {
                id: titlePage
                focus: app.layer === "title"
                active: app.layer === "title"
            }
            HomeScreen {
                id: home
                width: parent.width; height: parent.height
                focus: app.layer === "home"
                shown: app.onHome
                holdFocus: app.layer === "menu"
                rows: catalog.rows
                onActivated: app.open()
                onHeld: app.openMenu()
                onExitTop: app.layer = "tabs"
                onColsChanged: probe.act("row move")
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
            model: ["Home", "Movies", "Series", "Library", { icon: "search" }]
            shadow: app.onHome ? 0.8 : 0
            x: (parent.width - width) / 2; y: app.onHome ? 44 : -100
            opacity: app.layer === "menu" ? 0.3 : 1
            Behavior on y { NumberAnimation { duration: Theme.slow; easing.type: Theme.ease } }
            Behavior on opacity { NumberAnimation { duration: 300 } }
            onCurrentIndexChanged: probe.act("tabs")
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
            if (Remote.isBack(event.key) && app.layer !== "home") { event.accepted = true; app.layer = "home" }
            else if (event.key === Qt.Key_Down && app.layer === "tabs") { event.accepted = true; app.layer = "home" }
        }
    }

    Component.onCompleted: {
        // Back reaches the app only with this window property; without it webOS opens the exit menu
        tools.setWindowProperty(app, "_WEBOS_ACCESS_POLICY_KEYS_BACK", "true");
        requestActivate();
    }
}
