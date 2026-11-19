// Draws the app's icon and its splash screen with the app's own face and colours, and writes them into
// app/ (tools/brand.sh runs it): icon.png (80 px), icon-large.png (130 px, the tile on the TV's home
// row) and splash.png (1920 x 1080).
// The mark is the control the app puts on what has the remote: a white pill with dark ink, here with
// the name's letter. The splash is black, as the app's window is, so nothing flashes as the app takes
// over from it. webOS shows `splashBackground` from appinfo.json until the app's first frame; with none
// it shows a grey screen and a spinner of its own.
import QtQuick 2.15
import QtQuick.Window 2.15
import Seimio.UI 1.0

Window {
    id: win
    width: 400; height: 300; visible: true; color: "black"
    readonly property string out: Qt.application.arguments[Qt.application.arguments.length - 1]

    // the mark in a square of `size`; `tile`: on the icon's black tile, with the faint light the app's glass has
    component Mark: Item {
        id: mark
        property real size: 130
        property bool tile: true
        readonly property real u: size / 130
        width: size; height: size
        Rectangle { anchors.fill: parent; color: "black"; visible: mark.tile }
        Rectangle {
            anchors.fill: parent; visible: mark.tile
            gradient: Gradient { GradientStop { position: 0; color: "#24ffffff" } GradientStop { position: 0.6; color: "#00ffffff" } }
        }
        Rectangle {
            anchors.centerIn: parent; width: 84 * mark.u; height: 84 * mark.u; radius: 27 * mark.u; color: Theme.focusFill
            Text { anchors.centerIn: parent; anchors.verticalCenterOffset: -1 * mark.u; text: "S"; color: Theme.inkOnLight; font.family: Theme.face; font.weight: Font.Bold; font.pixelSize: 62 * mark.u }
        }
    }

    Mark { id: small; size: 80 }
    Mark { id: large; size: 130; y: 90 }
    Rectangle {
        id: splash; width: 1920; height: 1080; color: "black"; x: 300
        Row {
            anchors.centerIn: parent; spacing: 44
            Mark { size: 168; tile: false; anchors.verticalCenter: parent.verticalCenter }
            Text { text: "Seimio"; color: Theme.ink; font.family: Theme.face; font.weight: Font.DemiBold; font.pixelSize: 104; anchors.verticalCenter: parent.verticalCenter }
        }
    }

    property int left: 3
    function wrote() { if (--left === 0) { console.log("saved"); Qt.quit() } }
    // (once the face has loaded and a frame has been drawn: macOS draws nothing for a window it hasn't shown)
    Timer {
        interval: 1200; running: true
        onTriggered: {
            small.grabToImage(function (r) { r.saveToFile(win.out + "/icon.png"); win.wrote() }, Qt.size(80, 80));
            large.grabToImage(function (r) { r.saveToFile(win.out + "/icon-large.png"); win.wrote() }, Qt.size(130, 130));
            splash.grabToImage(function (r) { r.saveToFile(win.out + "/splash.png"); win.wrote() }, Qt.size(1920, 1080));
        }
    }
}
