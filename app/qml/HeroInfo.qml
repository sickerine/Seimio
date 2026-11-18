// Title, facts and description over the backdrop. `item` is its only input; internal state:
//   m        the title on screen
//   pending  the title to show next, waiting for the old one to fade out and its logo to load
// - A new item fades the current one out, preloads the new logo, then swaps and rises back in, so the
//   name never flashes in before the logo.
// - An item equal to `m` cancels the pending swap and fades straight back in. One that shows the same
//   (the Anime tab's show once it's made playable) takes its place without a fade.
// - Another change mid-swap replaces `pending`.
// `busy` is true until the panel shows `item` fully.
import QtQuick 2.12
import Seimio.UI 1.0

Item {
    id: info
    property var item: null
    width: 900; height: 400
    // the layout, Home's by default; the show page sets its own (a smaller title, two lines of description)
    property size logoSize: Qt.size(640, 180)
    property int nameSize: 72
    property int chipsY: 206
    property int chipSize: 22
    property int textY: 272
    property int textWidth: 780
    property int textSize: 26
    property int textLines: 3
    // where the description ends, for placing things under the info
    readonly property real contentHeight: description.y + description.height

    property var m: null
    property var pending: null
    property real fadeIn: 1
    property real rise: 0
    readonly property bool busy: item !== m || fadeOut.running || fadeInAnim.running
    transform: Translate { y: info.rise }

    onItemChanged: {
        if (item === m || (!pending && same(item, m))) { m = item; pending = null; fadeOut.stop(); if (fadeIn < 1) fadeInAnim.restart(); return }
        pending = item;
        // start the fade-out before touching the preload: a cached logo reports Ready synchronously and
        // calls apply() from inside this handler
        if (m && !fadeOut.running) { fadeInAnim.stop(); if (fadeIn > 0) fadeOut.restart() }
        preload.source = item && item.logo ? item.logo : "";
        apply();
    }
    function same(a, b) {
        return !!(a && b) && a.name === b.name && (a.logo || "") === (b.logo || "") && a.description === b.description
            && a.rating === b.rating && a.episode === b.episode && String(a.chips) === String(b.chips);
    }
    Image { id: preload; visible: false; asynchronous: true; sourceSize.width: 780; onStatusChanged: info.apply() }
    NumberAnimation { id: fadeOut; target: info; property: "fadeIn"; to: 0; duration: 140; easing.type: Easing.InQuad; onFinished: info.apply() }
    function apply() {
        if (!pending || fadeOut.running || (m && fadeIn > 0)) return;
        if (preload.source.toString() !== "" && preload.status === Image.Loading) return;
        m = pending; pending = null; rise = 18;
        fadeInAnim.restart();
    }
    ParallelAnimation {
        id: fadeInAnim
        NumberAnimation { target: info; property: "fadeIn"; to: 1; duration: 380; easing.type: Theme.ease }
        NumberAnimation { target: info; property: "rise"; to: 0; duration: 480; easing.type: Theme.ease }
    }

    Item {
        anchors.fill: parent
        opacity: info.fadeIn
        TitleArt {
            width: info.logoSize.width; height: info.logoSize.height; nameSize: info.nameSize
            logo: info.m && info.m.logo ? info.m.logo : ""; name: info.m ? info.m.name : ""
        }
        Row {
            y: info.chipsY; spacing: 10
            Chip { visible: !!(info.m && info.m.episode); kind: "solid"; icon: "play"; size: info.chipSize; text: info.m && info.m.episode ? info.m.episode : "" }
            Chip { visible: !!(info.m && info.m.rating); kind: "rating"; icon: "star"; size: info.chipSize; text: info.m ? info.m.rating || "" : "" }
            ChipRow { model: info.m ? info.m.chips || [] : []; stagger: 50; size: info.chipSize }
        }
        Text {
            id: description
            y: info.textY; width: info.textWidth; wrapMode: Text.WordWrap; maximumLineCount: info.textLines; elide: Text.ElideRight
            text: info.m ? info.m.description || "" : ""; color: Theme.inkSoft
            font.family: Theme.face; font.pixelSize: info.textSize; lineHeight: 1.22
        }
    }
}
