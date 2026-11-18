// A full-size frosted, darkened copy of `source`, for backgrounds under sheets and menus. An optional
// rounded `hole` (in this item's pixels) stays clear, for something that should stay sharp above the
// frost. `frozen`/`sourceBusy` work as in BlurChain. A frost that is about to be needed can be drawn
// once at a tiny opacity ("warmed") so its shaders compile before first real use; at opacity 0 Qt
// doesn't draw it at all. Fully faded in and without a hole it's opaque (`covering`); with
// `hideCovered` its source then isn't drawn under it, only captured.
import QtQuick 2.12

Item {
    id: frost
    property Item source
    property real darken: 0.78
    property rect hole: Qt.rect(0, 0, 0, 0)
    property real holeRadius: 18
    property bool frozen: false
    property bool sourceBusy: false
    property bool sourceMoving: false
    property bool hideCovered: false
    readonly property bool covering: opacity >= 1 && hole.width <= 0
    visible: opacity > 0
    // something reads its blur (a Glass over it) though it doesn't show itself: the blur is kept up
    property bool needed: false
    function refresh() { blur.refresh() }

    BlurChain {
        id: blur
        source: frost.source
        sourceRect: Qt.rect(0, 0, frost.width, frost.height)
        active: frost.visible || frost.needed
        frozen: frost.frozen
        sourceBusy: frost.sourceBusy
        sourceMoving: frost.sourceMoving
        hideSource: frost.hideCovered && frost.covering
    }
    ShaderEffect {
        anchors.fill: parent
        property var tex: blur.output
        property size texel: Qt.size(1 / blur.outputSize.width, 1 / blur.outputSize.height)
        property size box: Qt.size(width, height)
        property rect holeRect: frost.hole
        property real holeR: frost.holeRadius
        property real dark: frost.darken
        fragmentShader: "
            varying highp vec2 qt_TexCoord0;
            uniform sampler2D tex;
            uniform highp vec2 texel;
            uniform highp vec2 box;
            uniform highp vec4 holeRect;
            uniform highp float holeR;
            uniform lowp float dark;
            uniform lowp float qt_Opacity;
            void main() {
                // four bilinear reads smooth the upscale of the small blurred texture
                highp vec2 h = texel * 0.5;
                lowp vec4 c = (texture2D(tex, qt_TexCoord0 + vec2(h.x, h.y)) + texture2D(tex, qt_TexCoord0 + vec2(-h.x, h.y))
                             + texture2D(tex, qt_TexCoord0 + vec2(h.x, -h.y)) + texture2D(tex, qt_TexCoord0 + vec2(-h.x, -h.y))) * 0.25;
                lowp float a = 1.0;
                if (holeRect.z > 0.0) {
                    highp vec2 p = qt_TexCoord0 * box;
                    highp vec2 q = abs(p - (holeRect.xy + holeRect.zw * 0.5)) - (holeRect.zw * 0.5 - vec2(holeR));
                    highp float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - holeR;
                    a = smoothstep(-2.0, 6.0, d);
                }
                gl_FragColor = vec4(c.rgb * dark, 1.0) * a * qt_Opacity;
            }"
    }
}
