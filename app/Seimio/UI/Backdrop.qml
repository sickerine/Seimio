// The hero backdrop, with a slow Ken Burns drift. `target` is its only input; what is shown changes
// through a crossing Swap (Swap.qml), which has the rules:
//   shown     the address fully visible now
//   incoming  the address being loaded or crossfaded in, "" when idle
// - A new target replaces an incoming one that hasn't started crossfading.
// - A target equal to `shown` cancels the incoming one. No target keeps what is shown.
// - A crossfade that has started always finishes; then the latest target is applied.
// - A failed load drops the incoming one and keeps what is shown.
// `busy` is true from a target change until the screen shows that target, so anything that
// captures the backdrop (frost) knows when its copy would be stale.
//
// Both images are drawn by one opaque shader that crops, zooms, pans and crossfades them, so the
// backdrop costs one full-screen pass with no blending, even mid-crossfade; at rest only the shown one
// is loaded. `pan` shifts the picture left by that many pixels (parallax).
import QtQuick 2.12
import Seimio.Native 1.0

Item {
    id: root
    // (An address can list more than one place to get the picture from, and the picture loader shows the
    // first at hand: an anime's fanart comes from a host that takes most of a minute over it, and until
    // it was in, the title before stayed on screen. Seimio.Data's pictures.h.)
    property string target
    property size decodeSize: Qt.size(1920, 1080)          // the screen's own size: half of it looked soft
    property real pan: 0
    property real radius: 0                   // rounded corners for a framed backdrop (blends then)
    readonly property string shown: swap.shown || ""
    readonly property string incoming: swap.coming || ""
    readonly property bool busy: target !== shown
    readonly property bool fading: swap.phase === "entering"
    // Changing faster than its drift: a crossfade running, or the pan moving (a frozen blur of it follows).
    // Not the wait for a picture (`busy` without `fading`): while it loads nothing on screen has changed,
    // and a frost that followed through the wait took its five passes twenty times a second for nothing,
    // in the frames a tab's screen comes in (tools/tests/tst_backdrop.qml).
    readonly property bool settling: fading || panned.running
    onPanChanged: panned.restart()
    Timer { id: panned; interval: 120 }
    signal crossfadeStarted()

    property int front: 0                     // which image is on screen; the other one loads and fades in
    readonly property real fadeIn: swap.level // how far the back image has faded in over the front one
    function img(i) { return i ? l1 : l0 }
    // lab: what it wants, what it shows and what each of its two pictures is doing (status as Image's)
    function labState() {
        return { target: target.slice(-28), shown: shown.slice(-28), incoming: incoming.slice(-28), fadeIn: fadeIn, fading: fading, front: front,
                 pictures: [l0.url.slice(-28) + " " + l0.stage(), l1.url.slice(-28) + " " + l1.stage()] };
    }
    Swap {
        id: swap
        cross: true; inMs: 700; easing: Easing.InOutQuad
        want: root.target || null
        // the back image has it loaded, or couldn't
        ready: root.img(1 - root.front).url === swap.coming && root.img(1 - root.front).status === Image.Ready
        failed: root.img(1 - root.front).url === swap.coming && root.img(1 - root.front).status === Image.Error
        onComingChanged: if (coming) root.img(1 - root.front).url = coming      // starts its load
        onPhaseChanged: if (phase === "entering") { Remote.tally("backdrop"); root.crossfadeStarted() }
        onSwitched: {
            root.front = 1 - root.front;
            // the picture that faded out is let go: the shader samples both, and a second full-screen
            // texture nobody sees cost 2 to 3.5 ms of every frame on the TV
            root.img(1 - root.front).url = "";
        }
    }
    // (BandedImage: a picture this size reaches the GPU over eight frames before it is Ready, not in the
    // crossfade's first frame, which was late for it every time)
    BandedImage { id: l0; property string url; address: url; sourceSize: root.decodeSize }
    BandedImage { id: l1; property string url; address: url; sourceSize: root.decodeSize }
    // The drift: the picture zooms from 1 to 1.07 and back on a sine, 36 s the round (`drift` goes once
    // around and the shader makes the zoom of it). Under something opaque (`covered`, a covering frost) it
    // stops where it is, so nothing redraws for it, and goes on from there once it shows again.
    property bool covered: false
    property Ambient drifting: Ambient { effect: picture; uniform: "drift"; period: 36000; running: root.visible && !root.covered }

    ShaderEffect {
        id: picture
        anchors.fill: parent
        property real drift: 0
        blending: root.radius > 0
        property size box: Qt.size(width, height)
        property real radius: root.radius
        property var tex0: l0
        property var tex1: l1
        // uv scale for each image's aspect-fill crop
        property size crop0: root.crop(l0)
        property size crop1: root.crop(l1)
        property real front: root.front
        property real frontOn: root.shown ? 1 : 0
        property real fadeIn: root.fadeIn
        property real pan: root.pan / root.width
        fragmentShader: "
            varying highp vec2 qt_TexCoord0;
            uniform sampler2D tex0;
            uniform sampler2D tex1;
            uniform highp vec2 crop0;
            uniform highp vec2 crop1;
            uniform lowp float front;
            uniform lowp float frontOn;
            uniform lowp float fadeIn;
            uniform highp float drift;
            uniform highp float pan;
            uniform highp vec2 box;
            uniform highp float radius;
            uniform lowp float qt_Opacity;
            void main() {
                highp float zoom = 1.0 + 0.035 * (1.0 - cos(6.2831853 * drift));
                highp vec2 p = (qt_TexCoord0 - 0.5 + vec2(pan, 0.0)) / zoom;
                lowp vec3 a = texture2D(tex0, clamp(0.5 + p * crop0, 0.0, 1.0)).rgb;
                lowp vec3 b = texture2D(tex1, clamp(0.5 + p * crop1, 0.0, 1.0)).rgb;
                lowp vec3 f = mix(a, b, front);
                lowp vec3 k = mix(b, a, front);
                lowp float mask = 1.0;
                if (radius > 0.0) {
                    highp vec2 q = abs(qt_TexCoord0 * box - box * 0.5) - (box * 0.5 - vec2(radius));
                    mask = clamp(0.5 - (length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius), 0.0, 1.0);
                }
                gl_FragColor = vec4(mix(f * frontOn, k, fadeIn), 1.0) * mask * qt_Opacity;
            }"
    }
    function crop(i) {
        if (i.implicitWidth <= 0 || i.implicitHeight <= 0 || width <= 0 || height <= 0) return Qt.size(1, 1);
        var r = (i.implicitWidth / i.implicitHeight) / (width / height);
        return r > 1 ? Qt.size(1 / r, 1) : Qt.size(1, r);
    }
}
