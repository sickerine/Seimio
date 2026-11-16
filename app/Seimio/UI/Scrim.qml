// Darkens the screen so text stays readable over any art: a shade from the left edge and a shade from
// the bottom, in one full-screen pass (two gradient rectangles would blend the screen twice).
// `side` and `foot` set how dark each side gets; animate them to change the look per screen.
import QtQuick 2.12

ShaderEffect {
    property real side: 0.85       // darkness at the left edge
    property real sideMid: 0.15    // darkness halfway across
    property real foot: 0.97     // darkness at the bottom edge
    property real footMid: 0.55  // darkness at the top of the bottom shade
    property real footReach: 0.65 // how far up the bottom shade reaches, as a fraction of the height
    Behavior on side { NumberAnimation { duration: Theme.slow } }
    Behavior on sideMid { NumberAnimation { duration: Theme.slow } }
    Behavior on footMid { NumberAnimation { duration: Theme.slow } }
    fragmentShader: "
        varying highp vec2 qt_TexCoord0;
        uniform lowp float side;
        uniform lowp float sideMid;
        uniform lowp float foot;
        uniform lowp float footMid;
        uniform lowp float footReach;
        uniform lowp float qt_Opacity;
        void main() {
            highp float x = qt_TexCoord0.x;
            lowp float a1 = x < 0.5 ? mix(side, sideMid, x / 0.5) : mix(sideMid, 0.0, (x - 0.5) / 0.5);
            highp float y = (qt_TexCoord0.y - (1.0 - footReach)) / footReach;   // 0 at the top of the shade, 1 at the bottom
            lowp float a2 = y <= 0.0 ? 0.0 : y < 0.3 ? mix(0.0, footMid, y / 0.3)
                         : y < 0.55 ? mix(footMid, 0.88, (y - 0.3) / 0.25) : mix(0.88, foot, (y - 0.55) / 0.45);
            lowp float a = 1.0 - (1.0 - a1) * (1.0 - a2);    // the two shades combined, as if blended in turn
            gl_FragColor = vec4(0.0, 0.0, 0.0, a) * qt_Opacity;
        }"
}
