// A card's picture in its rounded shape: the art cropped to the card, with the rim, the dimming, the
// bottom shade and the sheen all drawn in one shader over it, so nothing separate sits on the card to
// drift out of line when it tilts. MediaCard is this plus what a title or an episode carries (focus, chips,
// progress); a calendar day stacks three of these bare, since a full card is about 45 objects and a month
// of days held 126 of them, a quarter of everything the JavaScript engine walks at each collection.
import QtQuick 2.12

Item {
    id: face
    property string art
    property string fallback: ""        // shown when `art` can't be had (a new episode has no still yet)
    property string title: ""           // a title with no art at all carries its name
    property real radius: 16
    property bool focused: false
    property real sheen: -0.3           // where the band of light is across the card (MediaCard sweeps it on focus)
    property real dim: 0                // darkens the art (0 to 1) without making the card see-through
    property real shade: 0              // darkens the bottom for text over the art
    property real shadeTop: 0.5         // where the shade starts, as a fraction of the height
    readonly property bool artReady: img.status === Image.Ready
    onArtChanged: img.failed = false

    Image {
        id: img; anchors.fill: parent; visible: false
        // the art, or the fallback once the art has failed to load
        property bool failed: false
        source: (failed || !face.art) && face.fallback ? face.fallback : face.art
        // ArtCache holds it decoded from here on, so a card that comes back to it finds it ready; art
        // that loads although it is held ready there means the two decode differently
        onSourceChanged: ArtCache.hold(source, sourceSize.width, sourceSize.height)
        onStatusChanged: {
            if (status === Image.Error && !failed) failed = true;
            else if (status === Image.Ready) ArtCache.hold(source, sourceSize.width, sourceSize.height);
            else if (status === Image.Loading) {
                ArtCache.loads++;
                if (ArtCache.ready(source, sourceSize.width, sourceSize.height)) { ArtCache.reloads++; console.warn("card art decoded again though it is held: " + source) }
            }
        }
        asynchronous: true; fillMode: Image.PreserveAspectCrop
        sourceSize: Theme.cardDecodeSize(face.width, face.height)
    }
    ShaderEffect {
        // drawn 3px larger than the card: the rounded edge is antialiased inside this rectangle,
        // so no hard rectangle edge is left to step when the card tilts
        anchors.fill: parent; anchors.margins: -3
        property var tex: img
        // the art covers the card and is cropped to its shape (the texture is the whole image, so
        // the crop happens here: uv scale per axis from the image's and the card's aspect ratios)
        readonly property real imageAspect: img.implicitHeight > 0 ? img.implicitWidth / img.implicitHeight : 1
        readonly property real cardAspect: face.width / Math.max(1, face.height)
        property size crop: imageAspect > cardAspect ? Qt.size(cardAspect / imageAspect, 1) : Qt.size(1, imageAspect / cardAspect)
        property real pad: 3
        property size box: Qt.size(width, height)
        property real radius: face.radius
        // sheen: a soft diagonal band of light that crosses the card when it takes focus; computed
        // per pixel here so the band can enter and leave the card cleanly
        property real sheen: face.sheen
        // the border and the light along the top edge are drawn here too, from the same rounded
        // shape, so nothing separate can drift out of line while the card tilts
        property real focusAmt: face.focused ? 1 : 0
        // darkening, also in the shader so no separate layer sits on the tilting card
        property real dim: face.dim
        property real bottomShade: face.shade
        property real shadeTop: face.shadeTop
        Behavior on focusAmt { NumberAnimation { duration: 220 } }
        // fade the art in once decoded instead of popping
        opacity: img.status === Image.Ready ? 1 : 0      // holds: only ever fades in, once decoded
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
    // a placeholder of the card's exact shape while the art decodes, so nothing shifts
    // (also the whole card when it has no art, so it brightens when focused)
    Rectangle {
        anchors.fill: parent; radius: face.radius; visible: img.status !== Image.Ready
        color: face.focused ? "#40ffffff" : "#1affffff"
        border.width: face.focused ? 2 : 0; border.color: "#59ffffff"
        Behavior on color { ColorAnimation { duration: Theme.fast } }
        // (never while art is on its way: it would be a name that a picture then replaces)
        Text {
            visible: face.title !== "" && (face.art === "" || (img.status === Image.Error && img.failed))
            anchors.centerIn: parent; width: parent.width - 36
            horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; maximumLineCount: 4; elide: Text.ElideRight
            text: face.title; color: Theme.inkSoft; font.family: Theme.face; font.pixelSize: 22; font.weight: Font.DemiBold
        }
    }
}
