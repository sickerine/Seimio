// A show's page: title, actions (resume with progress, library, watched), a season switcher and the
// episodes, with details of the focused episode. Inputs: `item` (the title, from displayItem) and
// `show` (its seasons and episodes with watch state). Focus is a zone (actions, seasons, episodes)
// plus an index in each; `key()` moves it and returns false for keys the page doesn't use.
// The episode row shows `shownSeason`, which follows `seasonIdx` through a short slide, so a season
// change never flashes the old season's episodes at the new position.
import QtQuick 2.12

Item {
    id: page
    property var item: null
    property var show: null
    property string face
    property bool active: false
    property Item source                // what the glass blurs (the backdrop)
    width: 1920; height: 1080

    readonly property var seasons: show ? show.seasons : []
    readonly property bool multiSeason: seasons.length > 1
    property int zone: 0                // 0 actions, 1 seasons, 2 episodes
    property int actionIdx: 0
    property int seasonIdx: 0
    property int shownSeason: 0
    property int epIdx: 0
    property int moveDir: 1
    readonly property var episodes: seasons.length ? seasons[shownSeason].episodes : []
    readonly property var focusEp: episodes.length ? episodes[Math.min(epIdx, episodes.length - 1)] : null
    readonly property int stepW: 384 + 32

    // where you are in the show: the episode Stremio has as current, else the first unwatched
    function currentPos() {
        if (!show) return { s: 0, e: 0 };
        for (var s = 0; s < seasons.length; s++)
            for (var e = 0; e < seasons[s].episodes.length; e++)
                if (seasons[s].episodes[e].id === show.current) return { s: s, e: e };
        for (s = 0; s < seasons.length; s++)
            for (e = 0; e < seasons[s].episodes.length; e++)
                if (!seasons[s].episodes[e].watched) return { s: s, e: e };
        return { s: 0, e: 0 };
    }
    readonly property var resumeEp: { var p = currentPos(); return seasons.length ? seasons[p.s].episodes[p.e] : null }
    function epLabel(ep, s) { return ep ? (multiSeason ? "S" + seasons[s].season + " E" + ep.episode : "E" + ep.episode) : "" }
    readonly property string resumeLabel: resumeEp ? (resumeEp.progress > 0 ? "Resume " : "Play ") + epLabel(resumeEp, currentPos().s) : "Play"

    function open() {
        var p = currentPos();
        zone = 0; actionIdx = 0; seasonIdx = p.s; shownSeason = p.s; epIdx = p.e;
        enterAnim.restart();
    }
    function key(k) {
        if (k === Qt.Key_Down) { if (zone < 2) zone++; return true }
        if (k === Qt.Key_Up) { if (zone > 0) zone--; return true }
        if (k === Qt.Key_Left || k === Qt.Key_Right) {
            var d = k === Qt.Key_Right ? 1 : -1;
            if (zone === 0) actionIdx = Math.max(0, Math.min(2, actionIdx + d));
            else if (zone === 1) { var s = Math.max(0, Math.min(seasons.length - 1, seasonIdx + d)); if (s !== seasonIdx) { tabDir = d; seasonIdx = s } }
            else { moveDir = d; epIdx = Math.max(0, Math.min(episodes.length - 1, epIdx + d)) }
            return true;
        }
        return false;
    }

    // season change: slide the old episodes out, swap, slide the new ones in from the side moved toward
    property int tabDir: 1
    property real rowShift: 0
    property real rowFade: 1
    onSeasonIdxChanged: if (active && seasonIdx !== shownSeason) seasonSwap.restart()
    SequentialAnimation {
        id: seasonSwap
        ParallelAnimation {
            NumberAnimation { target: page; property: "rowFade"; to: 0; duration: 140; easing.type: Easing.InQuad }
            NumberAnimation { target: page; property: "rowShift"; to: -60 * page.tabDir; duration: 140; easing.type: Easing.InQuad }
        }
        ScriptAction { script: { page.shownSeason = page.seasonIdx; page.epIdx = page.seasonIdx === page.currentPos().s ? page.currentPos().e : 0; page.rowShift = 60 * page.tabDir } }
        ParallelAnimation {
            NumberAnimation { target: page; property: "rowFade"; to: 1; duration: 300; easing.type: Easing.OutCubic }
            NumberAnimation { target: page; property: "rowShift"; to: 0; duration: 380; easing.type: Easing.OutCubic }
        }
    }

    // entrance: sections arrive one after another
    property real e0: 0
    property real e1: 0
    property real e2: 0
    property real e3: 0
    SequentialAnimation {
        id: enterAnim
        ScriptAction { script: { page.e0 = 0; page.e1 = 0; page.e2 = 0; page.e3 = 0 } }
        PauseAnimation { duration: 120 }
        ParallelAnimation {
            NumberAnimation { target: page; property: "e0"; to: 1; duration: 420; easing.type: Easing.OutCubic }
            SequentialAnimation { PauseAnimation { duration: 70 }
                NumberAnimation { target: page; property: "e1"; to: 1; duration: 420; easing.type: Easing.OutCubic } }
            SequentialAnimation { PauseAnimation { duration: 140 }
                NumberAnimation { target: page; property: "e2"; to: 1; duration: 440; easing.type: Easing.OutCubic } }
            SequentialAnimation { PauseAnimation { duration: 210 }
                NumberAnimation { target: page; property: "e3"; to: 1; duration: 460; easing.type: Easing.OutCubic } }
        }
    }
    opacity: active ? 1 : 0
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: active ? 200 : 260 } }

    // ---- title ----
    Item {
        x: 120; y: 96; width: 1000; height: 330
        opacity: page.e0; transform: Translate { y: (1 - page.e0) * 24 }
        Image {
            id: logo; width: 560; height: 150; fillMode: Image.PreserveAspectFit; horizontalAlignment: Image.AlignLeft; verticalAlignment: Image.AlignBottom
            asynchronous: true; sourceSize.width: 780
            source: page.item && page.item.logo ? page.item.logo : ""
            visible: status === Image.Ready
        }
        Text {
            visible: logo.status !== Image.Ready
            anchors.bottom: logo.bottom; width: 900; wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight
            text: page.item ? page.item.name : ""; color: "white"; font.family: page.face; font.pixelSize: 64; font.weight: Font.Bold
        }
        Row {
            y: 172; spacing: 10
            Repeater {
                model: page.show ? [page.show.year].concat(page.show.genres).filter(function (x) { return x }) : (page.item ? page.item.chips : [])
                Rectangle {
                    height: 40; radius: 20; width: chipText.implicitWidth + 32; color: "#29ffffff"; border.width: 1; border.color: "#1fffffff"
                    Text { id: chipText; anchors.centerIn: parent; text: modelData; color: "#f2ffffff"; font.family: page.face; font.pixelSize: 21; font.weight: Font.Medium }
                }
            }
            Rectangle {
                visible: !!(page.show && page.show.rating)
                height: 40; radius: 20; width: ratingText.implicitWidth + 60; color: "#f5c518"
                Icon { name: "star"; color: "#1a1a1a"; width: 21; height: 21; x: 14; anchors.verticalCenter: parent.verticalCenter }
                Text { id: ratingText; x: 40; anchors.verticalCenter: parent.verticalCenter; text: page.show ? page.show.rating : ""; color: "#1a1a1a"; font.family: page.face; font.pixelSize: 21; font.weight: Font.Bold }
            }
            Rectangle {
                height: 40; radius: 20; width: seasonsText.implicitWidth + 32; color: "#29ffffff"; border.width: 1; border.color: "#1fffffff"
                visible: page.seasons.length > 0
                Text { id: seasonsText; anchors.centerIn: parent; text: page.seasons.length + (page.seasons.length === 1 ? " season" : " seasons"); color: "#f2ffffff"; font.family: page.face; font.pixelSize: 21; font.weight: Font.Medium }
            }
        }
        Text {
            y: 230; width: 860; wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight
            text: page.show && page.show.description ? page.show.description : (page.item ? page.item.description : ""); color: "#d9ffffff"; font.family: page.face; font.pixelSize: 25; lineHeight: 1.2
        }
    }

    // ---- actions ----
    Row {
        x: 120; y: 418; spacing: 22
        opacity: page.e1; transform: Translate { y: (1 - page.e1) * 24 }
        // resume: the bar inside the button shows how far into the episode you are
        Rectangle {
            id: resume
            property bool on: page.active && page.zone === 0 && page.actionIdx === 0
            width: resumeText.implicitWidth + 104; height: 76; radius: 38
            color: on ? "white" : "#e6ffffff"
            scale: on ? 1.06 : 1
            Behavior on scale { NumberAnimation { duration: 240; easing.type: Easing.OutBack; easing.overshoot: 1.6 } }
            Icon { name: "play"; color: "#111"; x: 32; anchors.verticalCenter: parent.verticalCenter }
            Text { id: resumeText; x: 72; anchors.verticalCenter: parent.verticalCenter; text: page.resumeLabel; color: "#111"; font.family: page.face; font.pixelSize: 28; font.weight: Font.DemiBold }
            Rectangle {
                visible: page.resumeEp && page.resumeEp.progress > 0
                x: 34; y: parent.height - 14; width: parent.width - 68; height: 4; radius: 2; color: "#26000000"
                Rectangle { width: parent.width * (page.resumeEp ? page.resumeEp.progress / 100 : 0); height: parent.height; radius: 2; color: "#111" }
            }
        }
        Repeater {
            model: [{ icon: "plus", label: "Add to library" }, { icon: "check", label: "Mark watched" }]
            Item {
                width: 76; height: 76
                property bool on: page.active && page.zone === 0 && page.actionIdx === index + 1
                Rectangle {
                    anchors.fill: parent; radius: 38
                    color: parent.on ? "white" : "#33ffffff"; border.width: 1; border.color: "#26ffffff"
                    scale: parent.on ? 1.08 : 1
                    Behavior on scale { NumberAnimation { duration: 240; easing.type: Easing.OutBack; easing.overshoot: 1.6 } }
                    Behavior on color { ColorAnimation { duration: 180 } }
                    Icon { name: modelData.icon; anchors.centerIn: parent; color: parent.parent.on ? "#111" : "white" }
                }
                // icon-only button: its name shows under it while focused
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter; y: 90
                    text: modelData.label; color: "white"; font.family: page.face; font.pixelSize: 21; font.weight: Font.Medium
                    opacity: parent.on ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 180 } }
                }
            }
        }
    }

    // ---- seasons: a glass switcher; the highlight stretches like the tab bar's ----
    Glass {
        id: seasonBar
        source: page.source
        x: 120; y: 548; width: seasonRow.width + 16; height: 64; radius: 32
        opacity: page.e2; transform: Translate { y: (1 - page.e2) * 24 }
        property Item target: seasonRow.children[page.seasonIdx] || null
        property real edgeL: target ? 8 + target.x : 8
        property real edgeR: target ? 8 + target.x + target.width : 8
        Behavior on edgeL { NumberAnimation { duration: page.tabDir > 0 ? 420 : 240; easing.type: Easing.OutCubic } }
        Behavior on edgeR { NumberAnimation { duration: page.tabDir > 0 ? 240 : 420; easing.type: Easing.OutCubic } }
        Rectangle {
            x: seasonBar.edgeL; width: seasonBar.edgeR - seasonBar.edgeL; y: 8; height: 48; radius: 24
            color: page.zone === 1 ? "#f2ffffff" : "#2effffff"
            Behavior on color { ColorAnimation { duration: 200 } }
        }
        Row {
            id: seasonRow; x: 8; height: parent.height
            Repeater {
                model: page.seasons
                Item {
                    width: sText.implicitWidth + 44; height: seasonRow.height
                    Text {
                        id: sText; anchors.centerIn: parent; text: "Season " + modelData.season
                        color: page.zone === 1 && page.seasonIdx === index ? "#111" : "white"
                        font.family: page.face; font.pixelSize: 24; font.weight: page.seasonIdx === index ? Font.DemiBold : Font.Medium
                    }
                }
            }
        }
    }

    // ---- episodes ----
    Item {
        id: epArea
        y: 640; width: page.width; height: 440
        opacity: page.e3 * page.rowFade
        transform: Translate { x: page.rowShift; y: (1 - page.e3) * 30 }
        Row {
            spacing: 32
            x: 120 - page.epIdx * page.stepW
            Behavior on x { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
            Repeater {
                model: page.episodes
                Card {
                    width: 384; height: 216
                    art: modelData.thumb ? "art/" + modelData.thumb : ""
                    episode: "E" + modelData.episode
                    progress: modelData.progress > 0 ? modelData.progress : -1
                    nextLabel: false
                    watched: modelData.watched && !(modelData.progress > 0)
                    upcoming: modelData.released > new Date().toISOString().slice(0, 10) ? new Date(modelData.released + "T12:00:00").toLocaleDateString(Qt.locale(), "d MMM") : ""
                    showTitle: false
                    face: page.face
                    focused: page.active && page.zone === 2 && page.epIdx === index
                    moveDir: page.moveDir
                }
            }
        }
        // the focused episode (or the resume episode while focus is above the row)
        Item {
            id: epInfo
            x: 120; y: 246; width: 1100; height: 180
            property var ep: page.zone === 2 ? page.focusEp : (page.episodes.length ? page.episodes[page.epIdx] : null)
            Text {
                id: epTitle
                width: 1100; elide: Text.ElideRight
                text: epInfo.ep ? epInfo.ep.episode + "   " + (epInfo.ep.title || "Episode " + epInfo.ep.episode) : ""
                color: "white"; font.family: page.face; font.pixelSize: 30; font.weight: Font.DemiBold
            }
            Row {
                y: 48; spacing: 10
                Repeater {
                    model: epInfo.ep ? [epInfo.ep.runtime, epInfo.ep.released ? new Date(epInfo.ep.released + "T12:00:00").toLocaleDateString(Qt.locale(), "d MMM yyyy") : ""].filter(function (s) { return s }) : []
                    Rectangle {
                        height: 34; radius: 17; width: t.implicitWidth + 26; color: "#24ffffff"
                        Text { id: t; anchors.centerIn: parent; text: modelData; color: "#e6ffffff"; font.family: page.face; font.pixelSize: 19; font.weight: Font.Medium }
                    }
                }
            }
            Text {
                y: 96; width: 1000; wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight
                text: epInfo.ep ? epInfo.ep.overview : ""; color: "#ccffffff"; font.family: page.face; font.pixelSize: 23; lineHeight: 1.2
            }
        }
    }
}
