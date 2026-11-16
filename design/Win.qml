// Design lab: an Apple TV style Home on your real Continue Watching and Cinemeta art, driven by the
// remote. Frame gaps are stamped on the render thread, grouped by what was animating, and posted to
// the Mac every 3 s.
import QtQuick 2.12
import Eos.Window 0.1
import Lab.Native 1.0

WebOSWindow {
    id: win
    appId: "lab.design.qml"
    // native apps only get Back, Info and the rest when the window asks for them
    keyMask: WebOSWindow.KeyMaskBack | WebOSWindow.KeyMaskInfo | WebOSWindow.KeyMaskOk | WebOSWindow.KeyMaskLeft | WebOSWindow.KeyMaskRight | WebOSWindow.KeyMaskUp | WebOSWindow.KeyMaskDown | WebOSWindow.KeyMaskDefault
    visible: true
    width: 1920; height: 1080
    color: "black"

    FontLoader { source: "fonts/InstrumentSans-400.ttf" }
    FontLoader { source: "fonts/InstrumentSans-500.ttf" }
    FontLoader { source: "fonts/InstrumentSans-600.ttf" }
    FontLoader { source: "fonts/InstrumentSans-700.ttf" }
    readonly property string face: "Instrument Sans"

    // ---- data and focus ----
    property var rows: []
    property int row: 0
    property var cols: []
    property int moveDir: 1
    property string mode: "home"          // home | detail (movie sheet) | series (show page)
    property var seriesData: ({})
    readonly property Item seriesPageItem: seriesPage    // for test scripts
    property bool popover: false
    property bool inTabs: false
    property int tab: 0
    property int tabDir: 1
    property int button: 0
    // State. focusItem is what the remote is on and changes instantly. displayItem is the one title
    // the backdrop, info and detail view render; it changes only through commit(). Moving focus
    // commits after it settles (so key presses stay light); every action on the focused title
    // commits first, synchronously, so nothing can open on a stale title.
    readonly property var focusItem: rows.length && cols.length ? rows[row].items[cols[row]] : null
    property var displayItem: null
    function commit() { settle.stop(); if (displayItem !== focusItem) displayItem = focusItem }
    onFocusItemChanged: { if (!displayItem) commit(); else settle.restart(); startCaptures() }
    onPopoverChanged: if (popover) startCaptures()
    function startCaptures() { if (variant.captureAt) { captureStart = Date.now(); captureIndex = 0; captureTimer.restart() } }
    // lab: { "captureAt": [ms, ...] } captures the screen at those times after each focus move
    property double captureStart: 0
    property int captureIndex: 0
    Timer {
        id: captureTimer; interval: 10; repeat: true
        onTriggered: {
            var times = win.variant.captureAt || [];
            if (win.captureIndex >= times.length) { stop(); return }
            if (Date.now() - win.captureStart >= times[win.captureIndex]) { win.capture("/media/developer/temp/cap" + times[win.captureIndex] + ".png"); win.captureIndex++ }
        }
    }
    Timer { id: settle; interval: 280; onTriggered: win.commit() }
    function openDetail() {
        commit();
        if (displayItem && seriesData[displayItem.id]) { mode = "series"; seriesPage.open(); act("series open") }
        else { button = 0; mode = "detail"; act("detail open") }
    }
    function openPopover() { commit(); popover = true; act("popover") }

    readonly property int rowsTop: 610
    // the first few frames draw every effect invisibly, so shaders compile before anyone opens them
    property bool warming: true
    Timer { running: win.rows.length > 0; interval: 600; onTriggered: win.warming = false }
    function kindOf(r) { return rows[r].kind }
    function cardW(r) { return kindOf(r) === "landscape" ? 400 : 220 }
    function cardH(r) { return kindOf(r) === "landscape" ? 225 : 330 }
    function rowH(r) { return 56 + cardH(r) + 84 }
    function rowY(r) { var y = 0; for (var i = 0; i < r; i++) y += rowH(i); return y }

    // lab switches, read from the Mac at launch: { "glass": false, "hero": false, "flair": false, "autopop": true }
    property var variant: ({})
    function on(k) { return variant[k] !== false }

    // ---- measurement ----
    KeyLatency { id: lat }
    WindowTools { id: tools }
    // lab: screen captures of the TV through LG's capture service, triggered from the Mac
    LunaClient {
        id: luna
        property var log: []
        onResponse: log.push(payload.slice(0, 400))
    }
    function capture(path) {
        var t = luna.call("luna://com.webos.service.capture/executeOneShot", JSON.stringify({ path: path, method: "DISPLAY", width: 1920, height: 1080, format: "PNG" }));
        luna.log.push("capture call -> " + t + (t < 0 ? " " + luna.lastError() : ""));
    }
    FrameStats { id: frames; phase: win.phase }
    property string phase: "idle"
    function act(p) { phase = p; phaseReset.restart() }
    Timer { id: phaseReset; interval: 900; onTriggered: win.phase = "idle" }
    property var keysSeen: []
    Timer {
        running: true; interval: 3000; repeat: true
        onTriggered: {
            var out = { latency: lat.stats(), keys: keysSeen, variant: variant, luna: luna.log };
            luna.log = [];
            var fs = frames.take();
            for (var q in fs) out["rt " + q] = fs[q];
            keysSeen = [];
            var x = new XMLHttpRequest(); x.open("POST", "http://192.168.1.47:8091/design"); x.send(JSON.stringify(out));
        }
    }
    Timer { running: !!win.variant.autopop; interval: 2500; repeat: true; onTriggered: { if (win.popover) { win.popover = false; win.act("popover") } else win.openPopover() } }

    function load(path, done) {
        var x = new XMLHttpRequest();
        x.open("GET", path);
        x.onreadystatechange = function () { if (x.readyState === 4) done(x.status === 200 || x.status === 0 ? x.responseText : "") };
        x.send();
    }
    Component.onCompleted: {
        lat.attach(win); frames.attach(win);
        luna.init("");
        if (win.variant.capture) {}
        // Back reaches the app only with this window property; without it webOS opens the exit menu
        tools.setWindowProperty(win, "_WEBOS_ACCESS_POLICY_KEYS_BACK", "true");
        load("http://192.168.1.47:8091/variant.json", function (t) { try { if (t) win.variant = JSON.parse(t) } catch (e) {} });
        load("art/series.json", function (t) { if (t) win.seriesData = JSON.parse(t) });
        load("art/cw.json", function (cwText) {
            load("art/rows.json", function (popText) {
                var cw = JSON.parse(cwText).filter(function (i) { return i.backdrop }).map(function (i) {
                    return { id: i.id, name: i.name, art: "art/" + i.backdrop, backdrop: "art/" + i.backdrop, logo: i.logo ? "art/" + i.logo : "",
                             description: i.description, chips: [String(i.year).replace(/[-\u2013]$/, "")].concat(i.genres).filter(function (s) { return s }),
                             rating: "", episode: i.episode, progress: i.progress };
                });
                var out = [{ title: "Continue watching", kind: "landscape", items: cw }];
                JSON.parse(popText).forEach(function (r) {
                    out.push({ title: r.title, kind: "portrait", items: r.items.map(function (m) {
                        return { id: m.id, name: m.name, art: "art/" + m.poster, backdrop: "art/" + m.backdrop, logo: "art/l_" + m.id + ".png",
                                 description: m.description, chips: [m.year, m.runtime].concat(m.genres).filter(function (s) { return s }),
                                 rating: m.rating, episode: "", progress: -1 };
                    }) });
                });
                win.cols = out.map(function () { return 0 });
                win.rows = out;
            });
        });
        win.requestActivate();
    }

    // ---- the scene: everything glass can blur ----
    Item {
        id: scene
        width: parent.width; height: parent.height

        // hero backdrop: follows displayItem, drifting a little against moves along a row (parallax)
        Backdrop {
            id: hero
            width: parent.width; height: parent.height
            target: win.displayItem ? (win.on("hero") ? win.displayItem.backdrop : win.rows[0].items[0].backdrop) : ""
            x: -Math.min(8, win.cols.length ? win.cols[win.row] || 0 : 0) * 5
            Behavior on x { NumberAnimation { duration: 700; easing.type: Easing.OutCubic } }
            onCrossfadeStarted: win.act("hero crossfade")
        }
        // frosted backdrop for the detail view
        Frost {
            id: frost
            anchors.fill: parent
            source: hero
            darken: 0.78
            frozen: true
            sourceBusy: hero.busy
            warm: win.warming
            opacity: win.mode === "detail" ? 1 : (win.warming ? 0.003 : 0)
            Behavior on opacity { NumberAnimation { duration: 520; easing.type: Easing.InOutQuad } }
        }
        // scrims so text stays readable over any art
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: win.mode === "series" ? "#f2000000" : "#d9000000" }
                GradientStop { position: 0.5; color: win.mode === "series" ? "#59000000" : "#26000000" }
                GradientStop { position: 1; color: "#00000000" }
            }
        }
        Rectangle {
            anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 700
            gradient: Gradient {
                GradientStop { position: 0; color: "#00000000" }
                GradientStop { position: 0.3; color: win.mode === "series" ? "#b3000000" : "#8c000000" }
                GradientStop { position: 0.55; color: "#e0000000" }
                GradientStop { position: 1; color: "#f7000000" }
            }
        }

        // title, facts and description of displayItem; below the first row it steps aside
        InfoPanel {
            id: info
            x: 120
            item: win.displayItem
            face: win.face
            y: win.mode === "detail" ? 120 : (win.row > 0 ? 90 : 150)
            Behavior on y { NumberAnimation { duration: 460; easing.type: Easing.OutCubic } }
            property real away: win.row > 0 && win.mode === "home" ? 1 : 0
            Behavior on away { NumberAnimation { duration: 380; easing.type: Easing.OutCubic } }
            property real pageAway: win.mode === "series" ? 1 : 0
            Behavior on pageAway { NumberAnimation { duration: 240 } }
            opacity: (1 - away) * (1 - pageAway)
            visible: away < 1 && pageAway < 1
        }

        SeriesPage {
            id: seriesPage
            item: win.displayItem
            show: win.displayItem ? win.seriesData[win.displayItem.id] || null : null
            face: win.face
            source: hero
            active: win.mode === "series"
        }

        // rows; the focused card always sits at the left edge and the row slides under it
        Item {
            id: rowsBox
            width: parent.width; height: 2000
            y: (win.mode !== "home" ? 1200 : (win.row > 0 ? 380 : win.rowsTop)) - (win.rows.length ? win.rowY(win.row) : 0)
            opacity: win.mode !== "home" ? 0 : 1
            Behavior on y { NumberAnimation { duration: 480; easing.type: Easing.OutCubic } }
            Behavior on opacity { NumberAnimation { duration: 320 } }
            Repeater {
                model: win.rows
                Item {
                    id: rowItem
                    property int r: index
                    y: win.rowY(index); width: parent.width; height: win.rowH(index)
                    opacity: win.row === index ? 1 : 0.6
                    Behavior on opacity { NumberAnimation { duration: 300 } }
                    Text { x: 120; text: modelData.title; color: "white"; font.family: win.face; font.pixelSize: 30; font.weight: Font.DemiBold }
                    Row {
                        id: strip
                        y: 56; spacing: win.kindOf(rowItem.r) === "landscape" ? 40 : 36
                        x: 120 - (win.cols[rowItem.r] || 0) * (win.cardW(rowItem.r) + spacing)
                        Behavior on x { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                        Repeater {
                            model: modelData.items
                            Card {
                                width: win.cardW(rowItem.r); height: win.cardH(rowItem.r)
                                art: modelData.art; title: modelData.name; episode: modelData.episode; progress: modelData.progress
                                face: win.face
                                focused: win.mode === "home" && !win.inTabs && win.row === rowItem.r && win.cols[rowItem.r] === index
                                moveDir: win.moveDir
                                flair: win.on("flair")
                            }
                        }
                    }
                }
            }
        }
    }

    // quick actions frost and dim everything except the focused card. The scene is captured at 1/8
    // size only while the menu is open, so this costs about as much as one glass panel.
    readonly property rect focusRect: rows.length ? Qt.rect(120 - cardW(row) * 0.05, rowsBox.y + rowY(row) + 56 - cardH(row) * 0.05, cardW(row) * 1.1, cardH(row) * 1.1) : Qt.rect(0, 0, 0, 0)
    Frost {
        id: veil
        anchors.fill: parent
        source: scene
        darken: 0.55
        frozen: true
        sourceBusy: hero.busy || info.busy
        warm: win.warming
        hole: win.focusRect
        opacity: win.popover ? 1 : (win.warming ? 0.003 : 0)
        Behavior on opacity { NumberAnimation { duration: 320; easing.type: Easing.InOutQuad } }
    }

    // ---- glass surfaces over the scene ----

    // tab bar; the highlight stretches like liquid: the leading edge moves first, the trailing edge follows
    // soft shadow that lifts the tab bar off the art: a 9-slice image whose shape sits 48px inside its
    // edges, so it hugs the pill at any width; dropped 8px as if lit from above
    BorderImage {
        source: "art/shadow9.png"
        border { left: 79; right: 79; top: 79; bottom: 79 }
        x: tabs.x - 48; y: tabs.y - 48 + 8; width: tabs.width + 96; height: tabs.height + 96
        opacity: tabs.visible && win.mode === "home" ? tabs.opacity * 0.8 : 0
        Behavior on opacity { NumberAnimation { duration: 300 } }
    }
    Glass {
        id: tabs
        source: scene
        visible: win.on("glass")
        opacity: win.popover ? 0.3 : 1
        Behavior on opacity { NumberAnimation { duration: 300 } }
        width: tabRow.width + 20; height: 76; radius: 38
        x: (parent.width - width) / 2; y: win.mode !== "home" ? -100 : 44
        Behavior on y { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
        property Item target: tabRow.children[win.tab] || null
        property real edgeL: target ? 10 + target.x : 10
        property real edgeR: target ? 10 + target.x + target.width : 10
        Behavior on edgeL { NumberAnimation { duration: win.tabDir > 0 ? 420 : 240; easing.type: Easing.OutCubic } }
        Behavior on edgeR { NumberAnimation { duration: win.tabDir > 0 ? 240 : 420; easing.type: Easing.OutCubic } }
        Rectangle {
            x: tabs.edgeL; width: tabs.edgeR - tabs.edgeL
            y: 10; height: 56; radius: 28
            color: win.inTabs ? "#f2ffffff" : "#2effffff"
            Behavior on color { ColorAnimation { duration: 200 } }
        }
        Row {
            id: tabRow; x: 10; height: parent.height
            Repeater {
                model: ["Home", "Movies", "Series", "Library", ""]
                Item {
                    width: modelData ? tabText.implicitWidth + 52 : 76; height: tabRow.height
                    property bool active: win.tab === index
                    Text {
                        id: tabText; visible: modelData !== ""; anchors.centerIn: parent; text: modelData
                        color: win.inTabs && parent.active ? "#111" : "white"
                        font.family: win.face; font.pixelSize: 26; font.weight: parent.active ? Font.DemiBold : Font.Medium
                        Behavior on color { ColorAnimation { duration: 200 } }
                    }
                    Icon { visible: modelData === ""; name: "search"; anchors.centerIn: parent; color: win.inTabs && parent.active ? "#111" : "white" }
                }
            }
        }
    }

    // detail sheet; its contents arrive one after another
    Glass {
        id: sheet
        source: scene
        x: 80; width: 1760; height: 430; radius: 44
        y: win.mode === "detail" ? 570 : 1120
        sy: y
        tint: Qt.rgba(0.05, 0.05, 0.07, 0.3)
        Behavior on y { NumberAnimation { duration: 520; easing.type: Easing.OutCubic } }
        Row {
            x: 56; y: 52; spacing: 20
            Repeater {
                model: [{ label: "Play", icon: "play" }, { label: "Add to library", icon: "plus" }, { label: "Mark watched", icon: "check" }]
                Rectangle {
                    id: btn
                    property bool on: win.mode === "detail" && win.button === index
                    property real enter: 1
                    width: btnText.implicitWidth + 96; height: 76; radius: 38
                    color: on ? "white" : "#2effffff"
                    scale: on ? 1.06 : 1
                    opacity: enter
                    transform: Translate { y: (1 - btn.enter) * 24 }
                    Behavior on scale { NumberAnimation { duration: 240; easing.type: Easing.OutBack; easing.overshoot: 1.6 } }
                    Behavior on color { ColorAnimation { duration: 180 } }
                    Icon { name: modelData.icon; x: 30; anchors.verticalCenter: parent.verticalCenter; color: btn.on ? "#111" : "white" }
                    Text { id: btnText; x: 70; anchors.verticalCenter: parent.verticalCenter; text: modelData.label; color: btn.on ? "#111" : "white"; font.family: win.face; font.pixelSize: 28; font.weight: Font.DemiBold }
                    Connections { target: win; onModeChanged: if (win.mode === "detail") { btn.enter = 0; stagger.restart() } }
                    SequentialAnimation {
                        id: stagger
                        PauseAnimation { duration: 140 + index * 70 }
                        NumberAnimation { target: btn; property: "enter"; to: 1; duration: 380; easing.type: Easing.OutCubic }
                    }
                }
            }
        }
        Text { x: 56; y: 170; text: "More like this"; color: "white"; font.family: win.face; font.pixelSize: 28; font.weight: Font.DemiBold }
        Row {
            x: 56; y: 222; spacing: 24
            Repeater {
                model: win.rows.length > 1 ? win.rows[1].items.slice(0, 11) : []
                Card { width: 120; height: 180; radius: 12; art: modelData.art; showTitle: false; face: win.face }
            }
        }
    }

    // quick actions beside the focused card (long-press OK)
    Glass {
        id: pop
        source: scene
        width: 440; height: 270; radius: 32
        x: 120 + (win.rows.length ? win.cardW(win.row) * 1.1 : 0) + 44
        y: win.rowsTop + 56 - 10
        tint: Qt.rgba(0.08, 0.08, 0.1, 0.25)
        opacity: win.popover ? 1 : 0
        scale: win.popover ? 1 : 0.86
        transformOrigin: Item.Left
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: 200 } }
        Behavior on scale { NumberAnimation { duration: 380; easing.type: Easing.OutBack; easing.overshoot: 1.5 } }
        Column {
            x: 16; y: 16; spacing: 8
            Repeater {
                model: [{ label: "Play", icon: "play" }, { label: "Add to library", icon: "plus" }, { label: "Mark watched", icon: "check" }]
                Rectangle {
                    id: item
                    property real enter: 1
                    width: 408; height: 70; radius: 22; color: index === 0 ? "#38ffffff" : "transparent"
                    opacity: enter
                    transform: Translate { x: (1 - item.enter) * -18 }
                    Icon { name: modelData.icon; x: 24; anchors.verticalCenter: parent.verticalCenter }
                    Text { x: 68; anchors.verticalCenter: parent.verticalCenter; text: modelData.label; color: "white"; font.family: win.face; font.pixelSize: 27; font.weight: Font.Medium }
                    Connections { target: win; onPopoverChanged: if (win.popover) { item.enter = 0; itemIn.restart() } }
                    SequentialAnimation {
                        id: itemIn
                        PauseAnimation { duration: 60 + index * 55 }
                        NumberAnimation { target: item; property: "enter"; to: 1; duration: 300; easing.type: Easing.OutCubic }
                    }
                }
            }
        }
    }

    // ---- remote ----
    Item {
        id: keys
        focus: true
        // OK: a tap opens detail, holding opens quick actions (Apple TV's long press). LG's remote
        // doesn't send the usual auto-repeat while OK is held, so a hold is timed: OK starts a
        // 500 ms timer; letting go before it fires is a tap. A release followed by a press within
        // 90 ms is treated as still holding, in case the remote repeats as release/press pairs.
        property bool holding: false
        property bool longFired: false
        function isOk(k) { return k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Select }
        Timer { id: holdTimer; interval: 500; onTriggered: if (keys.holding && win.mode === "home" && !win.inTabs && !win.popover) { keys.longFired = true; win.openPopover() } }
        Timer {
            id: releaseTimer; interval: 90
            onTriggered: {
                keys.holding = false; holdTimer.stop();
                if (!keys.longFired && win.mode === "home" && !win.inTabs && !win.popover) win.openDetail();
                keys.longFired = false;
            }
        }
        Keys.onReleased: {
            win.keysSeen.push("up " + event.key.toString(16) + (event.isAutoRepeat ? " auto" : "") + " " + (Date.now() % 100000));
            if (!isOk(event.key) || event.isAutoRepeat) return;
            event.accepted = true;
            if (keys.holding) releaseTimer.restart();
        }
        Keys.onPressed: {
            var k = event.key;
            win.keysSeen.push("down " + k.toString(16) + (event.isAutoRepeat ? " auto" : "") + " " + (Date.now() % 100000));
            // LG's remote sends its own code for Back (0x1200003)
            var back = k === Qt.Key_Escape || k === Qt.Key_Back || k === 0x1200003;
            if (!win.rows.length) return;
            event.accepted = true;
            if (isOk(k)) {
                if (releaseTimer.running) { releaseTimer.stop(); return }   // a repeat pair: still holding
                if (!keys.holding) { keys.holding = true; keys.longFired = false; holdTimer.restart() }
                return;
            }
            if (win.popover) { if (back) { win.popover = false; win.act("popover") } return }
            if (win.mode === "series") {
                if (back) { win.mode = "home"; win.act("series close") }
                else if (seriesPage.key(k)) win.act("series " + ["actions", "seasons", "episodes"][seriesPage.zone]);
                return;
            }
            if (win.mode === "detail") {
                if (k === Qt.Key_Left) { win.button = Math.max(0, win.button - 1); win.act("detail buttons") }
                else if (k === Qt.Key_Right) { win.button = Math.min(2, win.button + 1); win.act("detail buttons") }
                else if (back) { win.mode = "home"; win.act("detail close") }
                return;
            }
            if (win.inTabs) {
                if (k === Qt.Key_Left && win.tab > 0) { win.tabDir = -1; win.tab--; win.act("tabs") }
                else if (k === Qt.Key_Right && win.tab < 4) { win.tabDir = 1; win.tab++; win.act("tabs") }
                else if (k === Qt.Key_Down || back) { win.inTabs = false; win.act("tabs") }
                return;
            }
            var c = win.cols.slice();
            if (k === Qt.Key_Right && c[win.row] < win.rows[win.row].items.length - 1) { win.moveDir = 1; c[win.row]++; win.cols = c; win.act("row move") }
            else if (k === Qt.Key_Left && c[win.row] > 0) { win.moveDir = -1; c[win.row]--; win.cols = c; win.act("row move") }
            else if (k === Qt.Key_Down && win.row < win.rows.length - 1) { win.row++; win.act("row change") }
            else if (k === Qt.Key_Up) { if (win.row > 0) { win.row--; win.act("row change") } else { win.inTabs = true; win.act("tabs") } }
        }
    }
}
