// A full-size frosted copy of `source`, blurred in two cheap passes so detail like text can't alias
// into a pattern: capture at 1/4 size and blur (13 taps), shrink that to 1/8 and blur again, then
// darken. Both captures run only while the frost is visible. An optional rounded `hole` (in this
// item's pixels) is left clear, for something that should stay sharp above the frost.
import QtQuick 2.12

Item {
    id: frost
    property Item source
    property real darken: 0.78
    property real spread: 1.6          // ring radius in texels, per pass
    property rect hole: Qt.rect(0, 0, 0, 0)
    property real holeRadius: 18
    // frozen: capture the source once when the frost appears instead of every frame (Apple freezes
    // the background under menus too); the expensive part is re-rendering the whole source
    property bool frozen: false
    // sourceBusy: the source is still changing (a crossfade, a panel swap); keep capturing until it
    // settles, then take one last capture of the final state, so a frozen frost is never stale
    property bool sourceBusy: false
    onSourceBusyChanged: if (!sourceBusy && visible && frozen) quarter.scheduleUpdate()
    // warm: render invisibly so shaders compile and buffers exist before first real use
    property bool warm: false
    visible: opacity > 0 || warm
    onVisibleChanged: if (visible && frozen) quarter.scheduleUpdate()

    readonly property string blur13: "
        lowp vec4 blur13(sampler2D tex, highp vec2 uv, highp vec2 t) {
            lowp vec4 c = texture2D(tex, uv) * 0.16;
            c += (texture2D(tex, uv + t * vec2(1.0, 0.0)) + texture2D(tex, uv + t * vec2(0.5, 0.866))
                + texture2D(tex, uv + t * vec2(-0.5, 0.866)) + texture2D(tex, uv + t * vec2(-1.0, 0.0))
                + texture2D(tex, uv + t * vec2(-0.5, -0.866)) + texture2D(tex, uv + t * vec2(0.5, -0.866))) * 0.09;
            c += (texture2D(tex, uv + t * vec2(1.732, 1.0)) + texture2D(tex, uv + t * vec2(0.0, 2.0))
                + texture2D(tex, uv + t * vec2(-1.732, 1.0)) + texture2D(tex, uv + t * vec2(-1.732, -1.0))
                + texture2D(tex, uv + t * vec2(0.0, -2.0)) + texture2D(tex, uv + t * vec2(1.732, -1.0))) * 0.05;
            return c;
        }"

    ShaderEffectSource {
        id: quarter
        sourceItem: frost.source
        textureSize: Qt.size(Math.round(frost.width / 4), Math.round(frost.height / 4))
        live: frost.visible && (!frost.frozen || frost.sourceBusy); hideSource: false; visible: false; smooth: true
    }
    // pass 1, drawn only into the 1/8 capture below
    ShaderEffect {
        id: pass1
        width: quarter.textureSize.width; height: quarter.textureSize.height
        property var tex: quarter
        property size texel: Qt.size(frost.spread / quarter.textureSize.width, frost.spread / quarter.textureSize.height)
        fragmentShader: "
            varying highp vec2 qt_TexCoord0;
            uniform sampler2D tex;
            uniform highp vec2 texel;
            uniform lowp float qt_Opacity;" + frost.blur13 + "
            void main() { gl_FragColor = blur13(tex, qt_TexCoord0, texel) * qt_Opacity; }"
    }
    ShaderEffectSource {
        id: eighth
        sourceItem: pass1
        textureSize: Qt.size(Math.round(frost.width / 8), Math.round(frost.height / 8))
        live: frost.visible; hideSource: true; visible: false; smooth: true
    }
    // pass 2, full size on screen
    ShaderEffect {
        anchors.fill: parent
        property var tex: eighth
        property size texel: Qt.size(frost.spread / eighth.textureSize.width, frost.spread / eighth.textureSize.height)
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
                gl_FragColor = vec4(c.rgb * dark, 1.0) * a * max(qt_Opacity, 0.0);
            }"
    }
}
