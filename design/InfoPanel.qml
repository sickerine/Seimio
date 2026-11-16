// Title, facts and description of one title. `item` is its only input; the rest is internal state:
//   m        the title on screen
//   pending  the title to show next, waiting for the old one to fade out and its logo to load
// - A new item fades the current one out, preloads the new logo, then swaps and rises back in, so
//   the fallback text title never flashes in before the logo.
// - An item equal to `m` cancels the pending swap and fades straight back in.
// - Another change mid-swap replaces `pending`; the panel never shows a title that isn't `item`
//   once it settles.
// `busy` is true until the panel shows `item` fully.
import QtQuick 2.12

Item {
    id: info
    property var item: null
    property string face
    width: 900; height: 400

    property var m: null
    property var pending: null
    property bool hasLogo: false
    property string logoSrc: ""
    property real fadeIn: 1
    property real rise: 0
    readonly property bool busy: item !== m || fadeOut.running || fadeInAnim.running
    transform: Translate { y: info.rise }

    onItemChanged: {
        if (item === m) { pending = null; fadeOut.stop(); if (fadeIn < 1) fadeInAnim.restart(); return }
        pending = item;
        logoPreload.source = item && item.logo ? item.logo : "";
        if (!m) { apply(); return }
        if (!fadeOut.running) { fadeInAnim.stop(); fadeOut.restart() }
    }
    Image { id: logoPreload; visible: false; asynchronous: true; sourceSize.width: 780; onStatusChanged: info.apply() }
    NumberAnimation { id: fadeOut; target: info; property: "fadeIn"; to: 0; duration: 140; easing.type: Easing.InQuad; onFinished: info.apply() }
    function apply() {
        if (!pending || fadeOut.running || (m && fadeIn > 0)) return;
        if (logoPreload.source.toString() !== "" && logoPreload.status === Image.Loading) return;
        hasLogo = logoPreload.status === Image.Ready;
        logoSrc = hasLogo ? pending.logo : "";
        m = pending; pending = null; rise = 18;
        fadeInAnim.restart();
    }
    ParallelAnimation {
        id: fadeInAnim
        NumberAnimation { target: info; property: "fadeIn"; to: 1; duration: 380; easing.type: Easing.OutCubic }
        NumberAnimation { target: info; property: "rise"; to: 0; duration: 480; easing.type: Easing.OutCubic }
    }

    Item {
        anchors.fill: parent
        opacity: info.fadeIn
        Image {
            id: logo; width: 640; height: 180; fillMode: Image.PreserveAspectFit; horizontalAlignment: Image.AlignLeft; verticalAlignment: Image.AlignBottom
            asynchronous: true; sourceSize.width: 780
            source: info.logoSrc
            visible: info.hasLogo
        }
        Text {
            visible: !info.hasLogo
            anchors.bottom: logo.bottom; width: 820; wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight
            text: info.m ? info.m.name : ""; color: "white"; font.family: info.face; font.pixelSize: 72; font.weight: Font.Bold; lineHeight: 0.95
        }
        Row {
            y: 206; spacing: 10
            Rectangle {
                visible: !!(info.m && info.m.episode)
                height: 42; radius: 21; width: epLabel.implicitWidth + 64; color: "white"
                Icon { name: "play"; color: "#111"; width: 20; height: 20; x: 16; anchors.verticalCenter: parent.verticalCenter }
                Text { id: epLabel; x: 42; anchors.verticalCenter: parent.verticalCenter; text: info.m && info.m.episode ? info.m.episode : ""; color: "#111"; font.family: info.face; font.pixelSize: 22; font.weight: Font.Bold }
            }
            Rectangle {
                visible: !!(info.m && info.m.rating)
                height: 42; radius: 21; width: rating.implicitWidth + 62; color: "#f5c518"
                Icon { name: "star"; color: "#1a1a1a"; width: 22; height: 22; x: 15; anchors.verticalCenter: parent.verticalCenter }
                Text { id: rating; x: 42; anchors.verticalCenter: parent.verticalCenter; text: info.m ? info.m.rating : ""; color: "#1a1a1a"; font.family: info.face; font.pixelSize: 22; font.weight: Font.Bold }
            }
            Repeater {
                model: info.m ? info.m.chips : []
                Rectangle {
                    id: chip
                    height: 42; radius: 21; width: label.implicitWidth + 34; color: "#29ffffff"
                    border.width: 1; border.color: "#1fffffff"
                    Text { id: label; anchors.centerIn: parent; text: modelData; color: "#f2ffffff"; font.family: info.face; font.pixelSize: 22; font.weight: Font.Medium }
                    // chips arrive one after another
                    opacity: 0
                    Component.onCompleted: chipIn.start()
                    SequentialAnimation {
                        id: chipIn
                        PauseAnimation { duration: 60 + index * 50 }
                        NumberAnimation { target: chip; property: "opacity"; to: 1; duration: 260; easing.type: Easing.OutCubic }
                    }
                }
            }
        }
        Text {
            y: 272; width: 780; wrapMode: Text.WordWrap; maximumLineCount: 3; elide: Text.ElideRight
            text: info.m ? info.m.description : ""; color: "#d9ffffff"; font.family: info.face; font.pixelSize: 26; lineHeight: 1.22
        }
    }
}
