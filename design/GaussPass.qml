// One direction of a separable Gaussian blur: 9 taps folded into 5 bilinear reads (the standard
// linear-sampling weights), drawn into a capture of `outputSize`. Chain a horizontal and a vertical
// pass for a 2D blur; the result has no ring or ladder artifacts because the taps leave no gaps.
// `output` is the blurred texture.
import QtQuick 2.12

Item {
    id: pass
    property var input                  // a texture provider (ShaderEffectSource or another pass's output)
    property size inputSize
    property size outputSize: inputSize
    property bool vertical: false
    property real step: 1.0             // > 1 widens the blur a little; the input should already be smooth
    property bool live: true
    readonly property alias output: capture

    ShaderEffect {
        id: fx
        width: pass.inputSize.width; height: pass.inputSize.height
        property var tex: pass.input
        property size dir: pass.vertical ? Qt.size(0, pass.step / pass.inputSize.height) : Qt.size(pass.step / pass.inputSize.width, 0)
        fragmentShader: "
            varying highp vec2 qt_TexCoord0;
            uniform sampler2D tex;
            uniform highp vec2 dir;
            uniform lowp float qt_Opacity;
            void main() {
                highp vec2 uv = qt_TexCoord0;
                lowp vec4 c = texture2D(tex, uv) * 0.2270270270;
                c += (texture2D(tex, uv + dir * 1.3846153846) + texture2D(tex, uv - dir * 1.3846153846)) * 0.3162162162;
                c += (texture2D(tex, uv + dir * 3.2307692308) + texture2D(tex, uv - dir * 3.2307692308)) * 0.0702702703;
                gl_FragColor = c * qt_Opacity;
            }"
    }
    ShaderEffectSource {
        id: capture
        sourceItem: fx
        textureSize: pass.outputSize
        live: pass.live; hideSource: true; visible: false; smooth: true
    }
}
