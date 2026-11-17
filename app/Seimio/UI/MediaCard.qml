// A card for a title or an episode: portrait poster or landscape tile. Rounded corners, the border,
// the dimming and the sheen are all drawn in one shader over the art, so nothing separate sits on the
// card to drift out of line when it tilts. `focused` lifts it with a slight overshoot, tilts it toward
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
        opacity: card.focused ? 1 : 0
        Behavior on drop { NumberAnimation { duration: Theme.base; easing.type: Theme.ease } }
        Behavior on opacity { NumberAnimation { duration: 240 } }
    }
    Item {
        id: face
        anchors.fill: parent
        scale: card.lift
        transform: Rotation { origin.x: card.width / 2; origin.y: card.height / 2; axis { x: 0; y: 1; z: 0 } angle: card.tilt }
        Image {
            id: img; anchors.fill: parent; visible: false
            // the art, or the fallback once the art has failed to load
            property bool failed: false
            source: (failed || !card.art) && card.fallback ? card.fallback : card.art
            onStatusChanged: if (status === Image.Error && !failed) failed = true
            Connections { target: card; onArtChanged: img.failed = false }
            asynchronous: true; fillMode: Image.PreserveAspectCrop
            sourceSize: Qt.size(card.width * 1.15, card.height * 1.15)
        }
        ShaderEffect {
            // drawn 3px larger than the card: the rounded edge is antialiased inside this rectangle,
            // so no hard rectangle edge is left to step when the card tilts
            anchors.fill: parent; anchors.margins: -3
            property var tex: img
            // the art covers the card and is cropped to its shape (the texture is the whole image, so
            // the crop happens here: uv scale per axis from the image's and the card's aspect ratios)
            readonly property real imageAspect: img.implicitHeight > 0 ? img.implicitWidth / img.implicitHeight : 1
            readonly property real cardAspect: card.width / Math.max(1, card.height)
            property size crop: imageAspect > cardAspect ? Qt.size(cardAspect / imageAspect, 1) : Qt.size(1, imageAspect / cardAspect)
            property real pad: 3
            property size box: Qt.size(width, height)
            property real radius: card.radius
            // sheen: a soft diagonal band of light that crosses the card when it takes focus; computed
            // per pixel here so the band can enter and leave the card cleanly
            property real sheen: card.sheen
            // the border and the light along the top edge are drawn here too, from the same rounded
            // shape, so nothing separate can drift out of line while the card tilts
            property real focusAmt: card.focused ? 1 : 0
            // darkening, also in the shader so no separate layer sits on the tilting card:
            // dim for watched or upcoming episodes, and a bottom shade under the chip and progress bar
            property real dim: Math.max(card.fade, card.upcoming ? 0.55 : (card.watched ? 0.25 : 0))
            property real bottomShade: card.caption !== "" ? Math.max(card.shade, 0.85) : card.shade
            // where the shade starts, as a fraction of the height: higher for a caption over the art
            property real shadeTop: card.caption !== "" ? 0.25 : 0.5
            Behavior on focusAmt { NumberAnimation { duration: 220 } }
            // fade the art in once decoded instead of popping
            opacity: img.status === Image.Ready ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 260 } }
            fragmentShader: "
                varying highp vec2 qt_TexCoord0;
                uniform sampler2D tex;
                uniform highp vec2 crop;
                uniform highp vec2 box;
                uniform highp float pad;
                uniform highp float radius;
                uniform highp float sheen;
                uniform lowp float focusAmt;
                uniform lowp float dim;
                uniform lowp float bottomShade;
                uniform highp float shadeTop;
                uniform lowp float qt_Opacity;
                void main() {
                    highp vec2 size = box - vec2(2.0 * pad);
                    highp vec2 p = qt_TexCoord0 * box - vec2(pad);        // card pixels; outside the card near the rim
                    highp vec2 q = abs(p - size * 0.5) - (size * 0.5 - vec2(radius));
                    highp float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
                    lowp vec4 c = texture2D(tex, clamp(0.5 + (p / size - 0.5) * crop, 0.0, 1.0));
                    // band position along a diagonal in pixels, so it has the same slant on any card shape
                    highp float along = (p.x + p.y * 0.35) / (size.x + size.y * 0.35);
                    highp float b = (along - sheen) / 0.16;
                    c.rgb *= (1.0 - dim) * (1.0 - bottomShade * smoothstep(shadeTop, 1.0, p.y / size.y));
                    c.rgb += vec3(0.13 * exp(-b * b)) * c.a;
                    // border: a 1.5px ring just inside the edge, brighter when focused
                    highp float ring = smoothstep(-2.0, -0.5, d);
                    c.rgb = mix(c.rgb, vec3(1.0), ring * (0.10 + 0.12 * focusAmt));
                    // light along the top edge when focused, fading toward the sides
                    highp float topBand = smoothstep(-2.5, -0.5, d) * (1.0 - smoothstep(0.0, 6.0, p.y));
                    highp float mid = 1.0 - abs(p.x / size.x - 0.5) * 2.0;
                    c.rgb = mix(c.rgb, vec3(1.0), topBand * mid * 0.55 * focusAmt);
                    gl_FragColor = c * clamp(0.5 - d, 0.0, 1.0) * qt_Opacity;
                }"
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
        // a placeholder of the card's exact shape while the art decodes, so nothing shifts
        // (also the whole card when it has no art, so it brightens when focused)
        Rectangle {
            anchors.fill: parent; radius: card.radius; visible: img.status !== Image.Ready
            color: card.focused ? "#40ffffff" : "#1affffff"
            border.width: card.focused ? 2 : 0; border.color: "#59ffffff"
            Behavior on color { ColorAnimation { duration: Theme.fast } }
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
        opacity: card.focused ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 220 } }
        Behavior on y { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }
    }
}
