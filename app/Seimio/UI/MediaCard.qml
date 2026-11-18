// A card for a title or an episode: portrait poster or landscape tile. Its picture, with the rounded
// corners, the border, the dimming and the sheen, is CardArt. `focused` lifts it with a slight overshoot, tilts it toward
// `moveDir`, sweeps a sheen across, drops a shadow and fades the title in underneath. Landscape cards
// carry an episode chip and a progress bar that fills in when the card appears.
import QtQuick 2.12

Item {
    id: card
    property string art
    property string fallback: ""        // shown when `art` can't be had (a new episode has no still yet)
    property string title
    property string episode
    property real progress: -1          // percent; < 0 hides the bar
    property bool nextLabel: true       // Home's Continue Watching marks unstarted next episodes "Next"
    property bool watched: false        // a check badge, and the art dims a little
    property string upcoming: ""        // air date of an episode that isn't out yet; dims the card
    property string caption: ""         // a name on the card itself, above the episode chip (always shown)
    property string label: ""           // a pill above the card (an air time); white while focused
    // darkens the art (0 to 1) without making the card see-through, for cards that overlap others
    property real fade: 0
    property bool focused: false
    property int moveDir: 0             // -1 left, 1 right: the tilt leans into the move
    property bool showTitle: true
    property real radius: 16
    readonly property bool artReady: picture.artReady
    // darkens the bottom half for text over the art; on by default when there's a chip or progress bar
    property real shade: progress >= 0 || episode ? 0.7 : 0
    // children go on the card face, so they lift and tilt with it (a calendar day's date, for example)
    default property alias content: overlay.data
    width: 220; height: 330

    property real lift: focused ? 1.1 : 1
    Behavior on lift { NumberAnimation { duration: 280; easing.type: Easing.OutBack; easing.overshoot: 1.3 } }
    property real tilt: 0
    property real sheen: -0.3
    onFocusedChanged: if (focused) { tiltAnim.restart(); sheenAnim.restart() }
    SequentialAnimation {
        id: tiltAnim
        NumberAnimation { target: card; property: "tilt"; to: 4 * card.moveDir; duration: 110; easing.type: Easing.OutQuad }
        NumberAnimation { target: card; property: "tilt"; to: 0; duration: 560; easing.type: Easing.OutBack; easing.overshoot: 2.2 }
    }
    NumberAnimation { id: sheenAnim; target: card; property: "sheen"; from: -0.3; to: 1.3; duration: 900; easing.type: Easing.OutCubic }

    // the shadow appears only under the focused card: on the dark background an unfocused card's
    // shadow is invisible but would still blend a large quad every frame
    Shadow {
        drop: card.focused ? 18 : 6
        scale: card.lift
        opacity: card.focused ? 1 : 0      // holds: a focus ring: nothing in it
        Behavior on drop { NumberAnimation { duration: Theme.base; easing.type: Theme.ease } }
        Behavior on opacity { NumberAnimation { duration: 240 } }
    }
    Item {
        id: face
        anchors.fill: parent
        scale: card.lift
        transform: Rotation { origin.x: card.width / 2; origin.y: card.height / 2; axis { x: 0; y: 1; z: 0 } angle: card.tilt }
        CardArt {
            id: picture
            anchors.fill: parent
            art: card.art; fallback: card.fallback; title: card.title; radius: card.radius
            focused: card.focused; sheen: card.sheen
            // dim for watched or upcoming episodes, and a bottom shade under the chip and progress bar,
            // starting higher for a caption over the art
            dim: Math.max(card.fade, card.upcoming ? 0.55 : (card.watched ? 0.25 : 0))
            shade: card.caption !== "" ? Math.max(card.shade, 0.85) : card.shade
            shadeTop: card.caption !== "" ? 0.25 : 0.5
        }
        // watched: dim slightly; upcoming: dim more and show the air date
        Rectangle {
            visible: card.watched
            anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 14
            width: 38; height: 38; radius: 19; color: "#e6ffffff"
            Icon { name: "check"; color: "#111"; width: 22; height: 22; anchors.centerIn: parent }
        }
        Rectangle {
            visible: card.upcoming !== ""
            anchors.centerIn: parent; height: 40; radius: 20; width: upText.implicitWidth + 32; color: "#33ffffff"
            Text { id: upText; anchors.centerIn: parent; text: card.upcoming; color: "white"; font.family: Theme.face; font.pixelSize: 20; font.weight: Font.DemiBold }
        }
        Text {
            visible: card.caption !== ""
            x: 18; width: parent.width - 36; elide: Text.ElideRight
            y: parent.height - (card.progress > 0 ? 62 : 48) - (card.episode !== "" ? 40 : 0)
            text: card.caption; color: "white"; font.family: Theme.face; font.pixelSize: 22; font.weight: Font.DemiBold
        }
        Rectangle {
            visible: card.episode !== ""
            x: 18; y: parent.height - (card.progress > 0 ? 62 : 48); height: 30; radius: 15; width: epText.implicitWidth + 22; color: "#40ffffff"
            Text { id: epText; anchors.centerIn: parent; text: card.progress > 0 || !card.nextLabel ? card.episode : "Next  " + card.episode; color: "white"; font.family: Theme.face; font.pixelSize: 18; font.weight: Font.DemiBold }
        }
        Item {
            visible: card.progress > 0
            x: 18; width: parent.width - 36; height: 6; y: parent.height - 22
            Rectangle { anchors.fill: parent; radius: 3; color: "#4dffffff" }
            Rectangle {
                id: fill; height: parent.height; radius: 3; color: "white"
                width: 0
                Component.onCompleted: fillAnim.start()
                // a card a strip reuses for another title fills in again
                Connections { target: card; onProgressChanged: { fill.width = 0; fillAnim.restart() } }
                NumberAnimation { id: fillAnim; target: fill; property: "width"; to: Math.max(6, fill.parent.width * Math.min(100, card.progress) / 100); duration: 900; easing.type: Easing.OutCubic }
            }
        }
        Item { id: overlay; anchors.fill: parent }
    }
    // the pill above the card; it stays put while the card lifts
    Rectangle {
        visible: card.label !== ""
        y: -54; height: 34; radius: 17; width: labelText.implicitWidth + 28
        color: card.focused ? Theme.focusFill : "#40000000"
        border.width: card.focused ? 0 : 1; border.color: "#33ffffff"
        Behavior on color { ColorAnimation { duration: Theme.fast } }
        Text {
            id: labelText
            anchors.centerIn: parent
            text: card.label; color: card.focused ? Theme.inkOnLight : Theme.ink
            font.family: Theme.face; font.pixelSize: 19; font.weight: Font.DemiBold
        }
    }
    // title under the focused card
    Text {
        visible: card.showTitle && opacity > 0
        y: card.height + 22 + (card.focused ? 0 : -8)
        x: (card.width - width) / 2
        width: card.width * 1.15; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
        text: card.title; color: "white"; font.family: Theme.face; font.pixelSize: 22; font.weight: Font.Medium
        opacity: card.focused ? 1 : 0      // holds: a focus ring: nothing in it
        Behavior on opacity { NumberAnimation { duration: 220 } }
        Behavior on y { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }
    }
}
