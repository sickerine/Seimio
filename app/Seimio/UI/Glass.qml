// Liquid glass: a panel that blurs whatever of `source` sits under it and bends it near the edges like
// a lens, with a saturation boost, a tint, a rim light brightest along the top, and rounded corners.
// White labels sit on it, so where the backdrop under it is bright the glass tones it down, pixel by
// pixel from the blurred backdrop's own brightness (`legible`); over dark art it is left as it is.
// Children sit on the glass. `sx`/`sy` are the panel's position in `source` coordinates; the defaults
// assume the panel's parent lines up with the source. The blur runs only while the panel is on screen.
import QtQuick 2.12

Item {
    id: glass
    property Item source
    property real radius: 28
    property color tint: Qt.rgba(1, 1, 1, 0.06)
    property real saturation: 1.6
    property real refraction: 1.0      // 0 = flat glass
    property real rim: 1.0             // 0 = no rim light
    property real legible: 1.0         // 0 = never toned down
    property real sx: x
    property real sy: y
    readonly property real pad: 32     // margin captured around the panel for the refraction to pull from
    // the source is already blurred (a Frost): the panel samples it directly instead of blurring it again
    property bool preblurred: false
    readonly property bool onScreen: visible && opacity > 0 && sy < (source ? source.height : 0) && sy + height > 0

    readonly property rect captured: Qt.rect(sx - pad, sy - pad, width + 2 * pad, height + 2 * pad)
    BlurChain {
        id: blur
        source: glass.source
        sourceRect: glass.captured
        active: glass.onScreen && !glass.preblurred
    }
    ShaderEffectSource {
        id: direct
        sourceItem: glass.preblurred ? glass.source : null
        sourceRect: glass.captured
        textureSize: blur.quarterSize
        live: glass.onScreen && glass.preblurred
        hideSource: false; visible: false; smooth: true
    }
    ShaderEffect {
        anchors.fill: parent
        property var tex: glass.preblurred ? direct : blur.output
        property size box: Qt.size(width, height)
        property size inset: Qt.size(glass.pad / (glass.width + 2 * glass.pad), glass.pad / (glass.height + 2 * glass.pad))
        property real radius: glass.radius
        property color tint: glass.tint
        property real saturation: glass.saturation
        property real refraction: glass.refraction
        property real rimLight: glass.rim
        property real legible: glass.legible
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
            uniform lowp float legible;
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
                c.rgb *= 1.0 - 0.52 * legible * smoothstep(0.36, 0.78, l);      // a bright backdrop, toned down for the labels
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
