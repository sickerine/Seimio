// A poster with rounded corners (cut in a shader, no extra layer), an Apple TV focus lift: scale, a
// small tilt toward the last move, a sheen that slides across, and a pre-blurred shadow.
import QtQuick 2.12

Item {
    id: poster
    property string art
    property bool focused: false
    property int moveDir: 0          // -1 left, 1 right: the tilt leans into the move
    property real radius: 14
    property bool flair: true        // tilt and sheen; off for measuring their cost
    width: 220; height: 330

    property real lift: focused ? 1.12 : 1
    Behavior on lift { NumberAnimation { duration: 260; easing.type: Easing.OutBack; easing.overshoot: 1.2 } }
    property real tilt: 0
    onFocusedChanged: if (focused && flair) { tiltAnim.restart(); sheenAnim.restart() }
    SequentialAnimation {
        id: tiltAnim
        NumberAnimation { target: poster; property: "tilt"; to: 7 * poster.moveDir; duration: 120; easing.type: Easing.OutQuad }
        NumberAnimation { target: poster; property: "tilt"; to: 0; duration: 520; easing.type: Easing.OutBack; easing.overshoot: 2 }
    }
    property real sheen: -0.4
    NumberAnimation { id: sheenAnim; target: poster; property: "sheen"; from: -0.4; to: 1.4; duration: 700; easing.type: Easing.OutCubic }

    Image {
        source: "art/shadow.png"
        x: -poster.width * 0.2; y: -poster.height * 0.1
        width: poster.width * 1.4; height: poster.height * 1.3
        scale: poster.lift; opacity: poster.focused ? 0.95 : 0.35
        Behavior on opacity { NumberAnimation { duration: 220 } }
    }
    Item {
        anchors.fill: parent
        scale: poster.lift
        transform: Rotation { origin.x: poster.width / 2; origin.y: poster.height / 2; axis { x: 0; y: 1; z: 0 } angle: poster.tilt }
        Image {
            id: img; anchors.fill: parent; visible: false
            source: poster.art; asynchronous: true; sourceSize: Qt.size(poster.width * 1.15, poster.height * 1.15)
        }
        ShaderEffect {
            anchors.fill: parent
            property var tex: img
            property size box: Qt.size(width, height)
            property real radius: poster.radius
            fragmentShader: "
                varying highp vec2 qt_TexCoord0;
                uniform sampler2D tex;
                uniform highp vec2 box;
                uniform highp float radius;
                uniform lowp float qt_Opacity;
                void main() {
                    highp vec2 p = qt_TexCoord0 * box;
                    highp vec2 q = abs(p - box * 0.5) - (box * 0.5 - vec2(radius));
                    highp float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
                    gl_FragColor = texture2D(tex, qt_TexCoord0) * clamp(0.5 - d, 0.0, 1.0) * qt_Opacity;
                }"
        }
        // sheen: a soft band of light that crosses the poster when it takes focus
        Rectangle {
            anchors.fill: parent; radius: poster.radius
            visible: poster.sheen > -0.35 && poster.sheen < 1.35
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: Math.max(0, poster.sheen - 0.25); color: "#00ffffff" }
                GradientStop { position: Math.max(0, Math.min(1, poster.sheen)); color: "#38ffffff" }
                GradientStop { position: Math.min(1, poster.sheen + 0.25); color: "#00ffffff" }
            }
        }
        Rectangle {
            anchors.fill: parent; radius: poster.radius; color: "transparent"
            border.width: 2; border.color: poster.focused ? "#66ffffff" : "#14ffffff"
            Behavior on border.color { ColorAnimation { duration: 200 } }
        }
    }
}
