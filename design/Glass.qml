// Liquid glass: blurs whatever of `source` sits under this item, and bends it near the edges like a
// lens. The region (plus a margin for the refraction to pull from) is captured at 1/4 size and blurred
// with a separable Gaussian, twice: a horizontal and vertical pass at 1/4 size, then again at 1/8. A
// Gaussian leaves no gaps between taps, so thin bright lines behind the panel (a progress bar, text)
// turn into a smooth glow instead of stacked copies. The final pass reads that, bends the edges,
// boosts saturation, tints, adds a rim light brightest along the top, and cuts the rounded corners.
// `sx`/`sy` are this item's position in `source` coordinates; bind them when the panel moves.
import QtQuick 2.12

Item {
    id: glass
    property Item source
    property real radius: 28
    property color tint: Qt.rgba(1, 1, 1, 0.06)
    property real saturation: 1.6
    property real refraction: 1.0      // 0 = flat glass
    property real rim: 1.0             // 0 = no rim light
    property real sx: x
    property real sy: y
    // capture only while on screen: a hidden panel would otherwise re-render what's under it every frame
    readonly property bool shown: visible && opacity > 0 && sy < (source ? source.height : 0) && sy + height > 0
    readonly property real pad: 32
    readonly property size quarterSize: Qt.size(Math.max(1, Math.round((width + 2 * pad) / 4)), Math.max(1, Math.round((height + 2 * pad) / 4)))
    readonly property size eighthSize: Qt.size(Math.max(1, Math.round((width + 2 * pad) / 8)), Math.max(1, Math.round((height + 2 * pad) / 8)))

    ShaderEffectSource {
        id: quarter
        sourceItem: glass.source
        sourceRect: Qt.rect(glass.sx - glass.pad, glass.sy - glass.pad, glass.width + 2 * glass.pad, glass.height + 2 * glass.pad)
        textureSize: glass.quarterSize
        live: glass.shown; hideSource: false; visible: false; smooth: true
    }
    GaussPass { id: h1; input: quarter; inputSize: glass.quarterSize; live: glass.shown }
    GaussPass { id: v1; input: h1.output; inputSize: glass.quarterSize; outputSize: glass.eighthSize; vertical: true; live: glass.shown }
    GaussPass { id: h2; input: v1.output; inputSize: glass.eighthSize; step: 1.4; live: glass.shown }
    GaussPass { id: v2; input: h2.output; inputSize: glass.eighthSize; vertical: true; step: 1.4; live: glass.shown }

    ShaderEffect {
        anchors.fill: parent
        property var tex: v2.output
        property size box: Qt.size(width, height)
        property size inset: Qt.size(glass.pad / (glass.width + 2 * glass.pad), glass.pad / (glass.height + 2 * glass.pad))
        property real radius: glass.radius
        property color tint: glass.tint
        property real saturation: glass.saturation
        property real refraction: glass.refraction
        property real rimLight: glass.rim
        fragmentShader: "
            varying highp vec2 qt_TexCoord0;
            uniform sampler2D tex;
            uniform highp vec2 box;
            uniform highp vec2 inset;
            uniform highp float radius;
            uniform lowp vec4 tint;
            uniform lowp float saturation;
            uniform lowp float refraction;
            uniform lowp float rimLight;
            uniform lowp float qt_Opacity;
            void main() {
                highp vec2 p = qt_TexCoord0 * box;
                highp vec2 hb = box * 0.5;
                highp vec2 q = abs(p - hb) - (hb - vec2(radius));
                highp float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;   // < 0 inside
                // lens: within ~24px of the edge, sample further out, so the background bends inwards
                highp float edge = clamp(1.0 + d / 24.0, 0.0, 1.0);
                highp vec2 dir = normalize(p - hb + 0.0001) * edge * edge * 10.0 * refraction;
                highp vec2 uv = inset + (p + dir) / box * (1.0 - 2.0 * inset);
                lowp vec4 c = texture2D(tex, uv);
                lowp float l = dot(c.rgb, vec3(0.299, 0.587, 0.114));
                c.rgb = mix(vec3(l), c.rgb, saturation);
                c.rgb = mix(c.rgb, tint.rgb, tint.a);
                // rim light: a thin bright band just inside the edge, strongest at the top
                highp float band = smoothstep(-3.0, -0.5, d) * (1.0 - smoothstep(-0.5, 0.5, d));
                highp float top = 1.0 - qt_TexCoord0.y;
                c.rgb += vec3(band * (0.12 + 0.45 * top * top) * rimLight);
                // a soft sheen across the upper part of the panel
                c.rgb += vec3(0.05 * smoothstep(0.55, 0.0, qt_TexCoord0.y) * rimLight);
                gl_FragColor = vec4(c.rgb, 1.0) * clamp(0.5 - d, 0.0, 1.0) * qt_Opacity;
            }"
    }
}
