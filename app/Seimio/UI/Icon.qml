// Small vector icons: play, plus, check, search, info, star, up, down. Each is a distance field drawn by one
// shader, so an icon costs no painting, no texture and no upload when it's created or recoloured,
// and stays sharp at any size or scale. `inkLeft`/`inkRight` are where the drawn shape starts and ends
// in pixels, so a control can pad an icon by what you see rather than by its box.
import QtQuick 2.12

ShaderEffect {
    property string name
    property color color: "white"
    width: 28; height: 28
    property real kind: ["play", "plus", "check", "search", "info", "star", "up", "down"].indexOf(name)
    property real px: 1 / Math.max(1, width)        // one pixel in icon units, for antialiasing
    readonly property var ink: [[0.28, 0.84], [0.125, 0.875], [0.145, 0.875], [0.145, 0.895], [0.085, 0.915], [0.063, 0.937], [0.205, 0.795], [0.205, 0.795]][kind] || [0, 1]
    readonly property real inkLeft: ink[0] * width
    readonly property real inkRight: ink[1] * width
    fragmentShader: "
        varying highp vec2 qt_TexCoord0;
        uniform lowp vec4 color;                         // Qt passes colours premultiplied
        uniform highp float kind;
        uniform highp float px;
        uniform lowp float qt_Opacity;
        highp float seg(highp vec2 p, highp vec2 a, highp vec2 b) {
            highp vec2 pa = p - a, ba = b - a;
            return length(pa - ba * clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0));
        }
        highp float tri(highp vec2 p, highp vec2 p0, highp vec2 p1, highp vec2 p2) {
            highp vec2 e0 = p1 - p0, e1 = p2 - p1, e2 = p0 - p2;
            highp vec2 v0 = p - p0, v1 = p - p1, v2 = p - p2;
            highp vec2 q0 = v0 - e0 * clamp(dot(v0, e0) / dot(e0, e0), 0.0, 1.0);
            highp vec2 q1 = v1 - e1 * clamp(dot(v1, e1) / dot(e1, e1), 0.0, 1.0);
            highp vec2 q2 = v2 - e2 * clamp(dot(v2, e2) / dot(e2, e2), 0.0, 1.0);
            highp float s = sign(e0.x * e2.y - e0.y * e2.x);
            highp vec2 d = min(min(vec2(dot(q0, q0), s * (v0.x * e0.y - v0.y * e0.x)),
                                   vec2(dot(q1, q1), s * (v1.x * e1.y - v1.y * e1.x))),
                                   vec2(dot(q2, q2), s * (v2.x * e2.y - v2.y * e2.x)));
            return -sqrt(d.x) * sign(d.y);
        }
        highp float star(highp vec2 p, highp float r, highp float rf) {
            const highp vec2 k1 = vec2(0.809016994375, -0.587785252292);
            const highp vec2 k2 = vec2(-0.809016994375, -0.587785252292);
            p.x = abs(p.x);
            p -= 2.0 * max(dot(k1, p), 0.0) * k1;
            p -= 2.0 * max(dot(k2, p), 0.0) * k2;
            p.x = abs(p.x);
            p.y -= r;
            highp vec2 ba = rf * vec2(-k1.y, k1.x) - vec2(0.0, 1.0);
            highp float h = clamp(dot(p, ba) / dot(ba, ba), 0.0, r);
            return length(p - ba * h) * sign(p.y * ba.x - p.x * ba.y);
        }
        void main() {
            highp vec2 p = qt_TexCoord0;
            highp float t = 0.055;                       // half the stroke width
            highp float d = 1.0;
            if (kind < -0.5) d = 1.0;
            else if (kind < 0.5) d = tri(p, vec2(0.28, 0.18), vec2(0.84, 0.5), vec2(0.28, 0.82));
            else if (kind < 1.5) d = min(seg(p, vec2(0.5, 0.18), vec2(0.5, 0.82)), seg(p, vec2(0.18, 0.5), vec2(0.82, 0.5))) - t;
            else if (kind < 2.5) d = min(seg(p, vec2(0.2, 0.52), vec2(0.42, 0.74)), seg(p, vec2(0.42, 0.74), vec2(0.82, 0.28))) - t;
            else if (kind < 3.5) d = min(abs(length(p - vec2(0.44)) - 0.24), seg(p, vec2(0.62), vec2(0.84))) - t;
            else if (kind < 4.5) d = min(min(abs(length(p - vec2(0.5)) - 0.36), seg(p, vec2(0.5, 0.46), vec2(0.5, 0.68))) - t,
                                         length(p - vec2(0.5, 0.32)) - 0.06);
            else if (kind < 5.5) d = star(vec2(p.x - 0.5, 0.5 - p.y), 0.46, 0.2 / 0.46);
            else {
                if (kind > 6.5) p.y = 1.0 - p.y;         // down is up upside down
                d = min(seg(p, vec2(0.5, 0.82), vec2(0.5, 0.2)), min(seg(p, vec2(0.26, 0.44), vec2(0.5, 0.2)), seg(p, vec2(0.74, 0.44), vec2(0.5, 0.2)))) - t;
            }
            gl_FragColor = color * clamp(0.5 - d / px, 0.0, 1.0) * qt_Opacity;
        }"
}
