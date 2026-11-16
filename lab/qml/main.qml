// Motion lab, native side: runs each scenario for 10 s, records the time between swapped frames,
// and posts the gaps to the Mac. Scenarios loop with no pauses so every gap is an animated frame.
import QtQuick 2.12
import QtQuick.Window 2.12
import QtGraphicalEffects 1.12

Window {
    id: win
    visible: true
    width: 1920; height: 1080
    color: "#101014"

    property string report: "http://192.168.1.47:8091/qml"
    property var scenarios: ["focusbakedshadow", "focusdropshadowcached", "focusscaleshadow", "tinybox"]
    property int index: -1
    property string current: ""
    property var gaps: []
    property double last: 0
    property bool recording: false
    property var results: ({})
    property int ticks: 0
    property var ticksBy: ({})
    onAfterAnimating: if (recording) ticks++

    onFrameSwapped: {
        var t = Date.now();
        if (recording && last > 0) gaps.push(t - last);
        last = t;
    }
    function on(name) { return current === name }
    function next() {
        if (current !== "") { results[current] = gaps; ticksBy[current] = ticks }
        index += 1;
        if (index >= scenarios.length) { send(); return; }
        current = scenarios[index];
        gaps = []; last = 0; ticks = 0;
        status.text = current;
        settle.restart();
    }
    function send() {
        status.text = "done";
        current = "";
        var x = new XMLHttpRequest();
        x.open("POST", report);
        x.send(JSON.stringify({ screen: Screen.width + "x" + Screen.height, results: results, ticks: ticksBy }));
    }
    Timer { id: settle; interval: 800; onTriggered: { recording = true; stop.restart() } }
    Timer { id: stop; interval: 10000; onTriggered: { recording = false; win.next() } }
    Timer { running: true; interval: 2000; onTriggered: win.next() }

    // A "page": hero art plus a poster row. Two of them crossfade with scale for the page transition.
    Component {
        id: pageC
        Item {
            width: 1920; height: 1080
            property alias art: hero.source
            Image { id: hero; anchors.fill: parent }
            Row {
                y: 620; x: 80; spacing: 40
                Repeater { model: 7; Image { source: "poster.jpg"; width: 240; height: 360 } }
            }
        }
    }
    Item {
        anchors.fill: parent; visible: on("pagecrossfadescale")
        Loader { id: pa; sourceComponent: pageC; onLoaded: item.art = "hero1.jpg" }
        Loader { id: pb; sourceComponent: pageC; onLoaded: item.art = "hero2.jpg" }
        SequentialAnimation {
            running: on("pagecrossfadescale"); loops: Animation.Infinite
            ParallelAnimation {
                NumberAnimation { target: pb; property: "opacity"; from: 0; to: 1; duration: 450; easing.type: Easing.OutCubic }
                NumberAnimation { target: pb; property: "scale"; from: 1.04; to: 1; duration: 450; easing.type: Easing.OutCubic }
                NumberAnimation { target: pa; property: "scale"; from: 1; to: 0.96; duration: 450; easing.type: Easing.OutCubic }
            }
            ParallelAnimation {
                NumberAnimation { target: pb; property: "opacity"; from: 1; to: 0; duration: 450; easing.type: Easing.OutCubic }
                NumberAnimation { target: pb; property: "scale"; from: 1; to: 1.04; duration: 450; easing.type: Easing.OutCubic }
                NumberAnimation { target: pa; property: "scale"; from: 0.96; to: 1; duration: 450; easing.type: Easing.OutCubic }
            }
        }
    }

    // Ken Burns hero: slow zoom with a crossfade between two images.
    Item {
        anchors.fill: parent; visible: on("herokenburns"); clip: true
        Image { id: kb1; anchors.fill: parent; source: "hero1.jpg" }
        Image { id: kb2; anchors.fill: parent; source: "hero2.jpg" }
        NumberAnimation { target: kb1; property: "scale"; running: on("herokenburns"); from: 1; to: 1.15; duration: 10000 }
        SequentialAnimation {
            running: on("herokenburns"); loops: Animation.Infinite
            NumberAnimation { target: kb2; property: "opacity"; from: 0; to: 1; duration: 1500; easing.type: Easing.InOutQuad }
            NumberAnimation { target: kb2; property: "opacity"; from: 1; to: 0; duration: 1500; easing.type: Easing.InOutQuad }
        }
    }

    // Moving posters, used alone and under live glass.
    Item {
        id: scene; anchors.fill: parent
        visible: on("rowcontinuous") || on("liveglassfastblur") || on("liveglassgaussian") || on("liveglasslowres")
        Image { anchors.fill: parent; source: "hero1.jpg" }
        Row {
            y: 300; spacing: 40
            Repeater { model: 14; Image { source: "poster.jpg"; width: 280; height: 420 } }
            SequentialAnimation on x {
                running: scene.visible; loops: Animation.Infinite
                NumberAnimation { from: 100; to: -900; duration: 1500; easing.type: Easing.InOutCubic }
                NumberAnimation { from: -900; to: 100; duration: 1500; easing.type: Easing.InOutCubic }
            }
        }
    }
    // Live glass: a side panel blurring whatever moves under it, every frame.
    ShaderEffectSource {
        id: glassSrc; sourceItem: scene; sourceRect: Qt.rect(1320, 0, 600, 1080)
        live: true; hideSource: false; visible: false
        width: 600; height: 1080
    }
    FastBlur {
        x: 1320; width: 600; height: 1080; source: glassSrc; radius: 64
        visible: on("liveglassfastblur")
        Rectangle { anchors.fill: parent; color: "#33ffffff" }
    }
    GaussianBlur {
        x: 1320; width: 600; height: 1080; source: glassSrc; radius: 32; samples: 33
        visible: on("liveglassgaussian")
        Rectangle { anchors.fill: parent; color: "#33ffffff" }
    }

    // Focus: a poster scaling up with a soft shadow, the Apple TV lift. Focus moves every 300 ms.
    // focusscaleshadow: live DropShadow; focusdropshadowcached: DropShadow cached and scaled as a whole;
    // focusbakedshadow: a pre-blurred shadow image scaled with the poster.
    Item {
        id: focusScene
        anchors.fill: parent; visible: on("focusscaleshadow") || on("focusdropshadowcached") || on("focusbakedshadow")
        property int focusIndex: 0
        Image { anchors.fill: parent; source: "hero2.jpg" }
        Row {
            x: 120; y: 330; spacing: 60
            Repeater {
                model: 6
                Item {
                    id: tile
                    width: 260; height: 390
                    property real lift: index === focusScene.focusIndex % 6 ? 1.12 : 1
                    Behavior on lift { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
                    DropShadow {
                        visible: on("focusscaleshadow"); anchors.fill: img; source: img
                        radius: 32; samples: 33; verticalOffset: 18; color: "#aa000000"; scale: tile.lift
                    }
                    Item {
                        // cached: the shadow and poster render once into a texture; only the transform animates
                        visible: on("focusdropshadowcached"); anchors.fill: parent; scale: tile.lift
                        DropShadow { anchors.fill: src; source: src; radius: 32; samples: 33; verticalOffset: 18; color: "#aa000000"; cached: true }
                        Image { id: src; anchors.fill: parent; source: "poster.jpg" }
                    }
                    Image {
                        visible: on("focusbakedshadow"); source: "shadow.png"
                        x: -60; y: -60; width: 380; height: 510; scale: tile.lift
                    }
                    Image {
                        id: img; anchors.fill: parent; source: "poster.jpg"
                        visible: !on("focusdropshadowcached"); scale: tile.lift
                    }
                }
            }
        }
        Timer { running: focusScene.visible; interval: 240; repeat: true; onTriggered: focusScene.focusIndex++ }
    }

    // Low-resolution live glass: blur a quarter-size copy of what's under the panel, then stretch it.
    ShaderEffectSource {
        id: glassSmall; sourceItem: scene; sourceRect: Qt.rect(1320, 0, 600, 1080)
        live: true; hideSource: false; visible: false
        width: 150; height: 270; textureSize: Qt.size(150, 270)
    }
    FastBlur {
        x: 1320; width: 150; height: 270; source: glassSmall; radius: 16
        transformOrigin: Item.TopLeft; scale: 4
        visible: on("liveglasslowres")
        Rectangle { anchors.fill: parent; color: "#33ffffff" }
    }

    Rectangle {
        x: 200; y: 200; width: 100; height: 100; color: "white"; visible: on("tinybox")
        SequentialAnimation on opacity {
            running: on("tinybox"); loops: Animation.Infinite
            NumberAnimation { from: 0; to: 1; duration: 1000 }
            NumberAnimation { from: 1; to: 0; duration: 1000 }
        }
    }
    Text { id: status; x: 60; y: 60; color: "white"; font.pixelSize: 40; text: "starting"; style: Text.Outline }
}
