// The hero backdrop, with a slow Ken Burns drift. `target` is its only input; the rest is internal
// state with fixed rules:
//   shown     the url fully visible now
//   incoming  the url being loaded or crossfaded in, "" when idle
// - A new target replaces an incoming one that hasn't started crossfading.
// - A target equal to `shown` cancels the incoming one.
// - A crossfade that has started always finishes; then the latest target is applied.
// - A failed load drops the incoming one and keeps what is shown.
// `busy` is true from a target change until the screen shows that target, so anything that
// captures the backdrop (frost) knows when its copy would be stale.
//
// Both images are drawn by one opaque shader that crops, zooms, pans and crossfades them, so the
// backdrop costs one full-screen pass with no blending, even mid-crossfade. `pan` shifts the picture
// left by that many pixels (parallax).
import QtQuick 2.12

Item {
    id: root
    property string target
    property size decodeSize: Qt.size(960, 540)
    property real pan: 0
    property real radius: 0                   // rounded corners for a framed backdrop (blends then)
    property string shown: ""
    property string incoming: ""
    readonly property bool busy: target !== shown
    signal crossfadeStarted()

    property int front: 0                     // which image is on screen; the other one loads and fades in
    property real fadeIn: 0                   // how far the back image has faded in over the front one
    function img(i) { return i ? l1 : l0 }
    onTargetChanged: apply()

    function apply() {
        if (fade.running) return;              // finishes first, then calls apply() again
        if (!target || target === shown) { incoming = ""; return }
        incoming = target;
        var back = img(1 - front);
        if (back.url === target && back.status === Image.Ready) { startFade(); return }
        back.url = target;                     // starts a load; loaded() continues from there
    }
    function loaded(i, ok) {
        if (i !== 1 - front || img(i).url !== incoming || fade.running) return;
        if (!ok) { incoming = ""; return }
        startFade();
    }
    function startFade() { fade.restart(); crossfadeStarted() }
    NumberAnimation {
        id: fade; target: root; property: "fadeIn"; from: 0; to: 1; duration: 700; easing.type: Easing.InOutQuad
        onFinished: {
            root.front = 1 - root.front;
            root.fadeIn = 0;
            root.shown = root.incoming;
            root.incoming = "";
            root.apply();
        }
    }
    Image {
        id: l0; property string url
        source: url; visible: false; asynchronous: true; sourceSize: root.decodeSize
        onStatusChanged: if (status === Image.Ready || status === Image.Error) root.loaded(0, status === Image.Ready)
    }
    Image {
        id: l1; property string url
        source: url; visible: false; asynchronous: true; sourceSize: root.decodeSize
        onStatusChanged: if (status === Image.Ready || status === Image.Error) root.loaded(1, status === Image.Ready)
    }
    property real zoom: 1
    // previews hold the zoom at rest, so a still captured at any moment is the same
    property bool still: false
    onStillChanged: if (still) zoom = 1
    SequentialAnimation on zoom {
        running: root.visible && !root.still
        loops: Animation.Infinite
        NumberAnimation { from: 1.0; to: 1.07; duration: 18000; easing.type: Easing.InOutSine }
        NumberAnimation { from: 1.07; to: 1.0; duration: 18000; easing.type: Easing.InOutSine }
    }

    ShaderEffect {
        anchors.fill: parent
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
        property real zoom: root.zoom
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
            uniform highp float zoom;
            uniform highp float pan;
            uniform highp vec2 box;
            uniform highp float radius;
            uniform lowp float qt_Opacity;
            void main() {
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
