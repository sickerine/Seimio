// Title, facts and description over the backdrop. `item` is its only input; what is on show (`m`) changes
// through a Swap, which has the rules (Seimio.UI's Swap.qml):
// - A new item's logo is loaded first, with the title on screen left as it is; then that one fades out
//   and the new one rises in. So the name never flashes in before the logo, and the panel is never
//   empty while a logo is fetched.
// - The swap, out and in, takes Theme.settle, the rest a title is taken after: the one taken is fully in
//   before the next can be, so moving on at any pace never cuts a fade-in short.
// - No item fades the panel out at once. An item equal to `m` fades straight back in, and one that
//   shows the same (the Anime tab's show once it's made playable) takes its place without a fade.
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

    readonly property var m: swap.shown                // the title on screen
    readonly property var pending: item !== m ? item : null     // lab: the one it is on its way to
    readonly property real fadeIn: swap.level
    property real rise: 0
    readonly property bool busy: swap.busy
    transform: Translate { y: info.rise }

    Swap {
        id: swap
        want: info.item
        // its logo is in, or it has none, or it can't be had
        ready: preload.source.toString() === "" || preload.status !== Image.Loading
        same: info.same
        onSwitched: { Remote.tally("info"); info.rise = 18; rising.restart() }
        onCut: Remote.tally("info cut")          // lab: a title replaced by another while it was still fading in, which is a flicker
    }
    // (the address, the size and the fit TitleArt's picture asks for: Qt keeps a picture by the three, and
    // one asked for with another fit is fetched again)
    Image {
        id: preload
        visible: false; asynchronous: true; sourceSize.width: 780; fillMode: Image.PreserveAspectFit
        source: info.item && info.item.logo ? info.item.logo : ""
    }
    NumberAnimation { id: rising; target: info; property: "rise"; to: 0; duration: 480; easing.type: Theme.ease }       // (the rise goes on a little past the fade)
    // lab: what it shows and what it waits for
    function labState() {
        return { m: m ? m.name : null, pending: item && item !== m ? item.name : null, fadeIn: fadeIn, phase: swap.phase, logo: m ? m.logo || "" : "",
                 preload: preload.status, art: art.labState() };
    }
    function same(a, b) {
        return !!(a && b) && a.name === b.name && (a.logo || "") === (b.logo || "") && a.description === b.description
            && a.rating === b.rating && a.episode === b.episode && String(a.chips) === String(b.chips);
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
