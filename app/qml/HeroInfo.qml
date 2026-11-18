// Title, facts and description over the backdrop. `item` is its only input; internal state:
//   m        the title on screen
//   pending  the title to show next, waiting for its logo to load and the old one to fade out
// - A new item's logo is loaded first, with the title on screen left as it is; then that one fades out
//   and the new one rises in. So the name never flashes in before the logo, and the panel is never
//   empty while a logo is fetched (it stood empty a second when it faded out first, a season's logo
//   fetched as its season was reached).
// - The swap, out and in, takes Theme.settle, the rest a title is taken after: the one taken is fully in
//   before the next can be, so moving on at any pace never cuts a fade-in short (the swap took 520 ms
//   against a rest of 280, and a title a press every 300 to 500 ms flickered in and out).
// - No item fades the panel out at once.
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
        if (item && m && fadeIn > 0 && fadeIn < 1) Remote.tally("info cut");      // lab: a title replaced by another while it was still fading in, which is a flicker
        pending = item;
        if (!item) { out(); return }
        preload.source = item.logo || "";
        apply();                                 // (a cached logo is Ready at once, with no change of status to say so)
    }
    function out() { if (m && !fadeOut.running && fadeIn > 0) { fadeInAnim.stop(); fadeOut.restart() } }
    // lab: what it shows and what it waits for
    function labState() {
        return { m: m ? m.name : null, pending: pending ? pending.name : null, fadeIn: fadeIn, logo: m ? m.logo || "" : "", preload: preload.status,
                 art: art.labState() };
    }
    function same(a, b) {
        return !!(a && b) && a.name === b.name && (a.logo || "") === (b.logo || "") && a.description === b.description
            && a.rating === b.rating && a.episode === b.episode && String(a.chips) === String(b.chips);
    }
    // (the size and the fit TitleArt's picture asks for: Qt keeps a picture by its address, size and fit,
    // and one asked for with another fit is fetched again)
    Image { id: preload; visible: false; asynchronous: true; sourceSize.width: 780; fillMode: Image.PreserveAspectFit; onStatusChanged: info.apply() }
    readonly property int outTime: Math.round(Theme.settle * 0.32)
    NumberAnimation { id: fadeOut; target: info; property: "fadeIn"; to: 0; duration: info.outTime; easing.type: Easing.InQuad; onFinished: info.apply() }
    // the pending title once its logo is in (or it has none, or it can't be had): the one on screen goes
    // out, and it comes in when that one has
    function apply() {
        if (!pending || fadeOut.running) return;
        if (preload.source.toString() !== "" && preload.status === Image.Loading) return;
        if (m && fadeIn > 0) { out(); return }
        m = pending; pending = null; rise = 18;
        Remote.tally("info");
        fadeInAnim.restart();
    }
    ParallelAnimation {
        id: fadeInAnim
        NumberAnimation { target: info; property: "fadeIn"; to: 1; duration: Theme.settle - info.outTime; easing.type: Theme.ease }
        NumberAnimation { target: info; property: "rise"; to: 0; duration: 480; easing.type: Theme.ease }       // (the rise goes on a little past the fade; out of sight when it starts again)
    }

    Item {
        anchors.fill: parent
        opacity: info.fadeIn
        TitleArt {
            id: art
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
