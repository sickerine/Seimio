// The people in the watch party's room, as pictures with no names (his rule, 2026-11-19: "generic profile
// pictures and show loading with an animation i dont care for text or names"). They stand in a row
// from the right, the first to come at the right end; more than `spread` of them overlap into a stack.
// One that can't play what the TV has yet wears a ring that turns. `viewers` is Party.viewers
// ([{ id, loading }]); up to eight are drawn. The row is as wide as eight would be, so it is placed by
// its right edge and nothing in it moves when someone comes or goes but the ones that close up.
import QtQuick 2.12

Item {
    id: room
    property var viewers: []
    property int size: 48
    property int spread: 3
    readonly property int shown: Math.min(viewers.length, places.count)
    readonly property real step: shown > spread ? Math.round(size * 0.58) : size + 10
    width: size + (places.count - 1) * (size + 10); height: size
    Repeater {
        id: places
        model: 8
        Item {
            id: place
            readonly property bool there: index < room.viewers.length
            readonly property bool loading: there && !!room.viewers[index].loading
            width: room.size; height: room.size
            x: room.width - room.size - index * room.step
            z: places.count - index              // (in a stack the earlier ones lie over the later)
            opacity: there ? 1 : 0      // holds: a picture, with nothing of its own in it
            scale: there ? 1 : 0.6
            visible: opacity > 0
            Behavior on x { NumberAnimation { duration: Theme.settle; easing.type: Theme.ease } }
            Behavior on opacity { NumberAnimation { duration: Theme.base } }
            Behavior on scale { NumberAnimation { duration: Theme.base; easing.type: Theme.ease } }
            Rectangle { anchors.fill: parent; radius: width / 2; color: "#e6181a20"; border.width: 2; border.color: "#3dffffff" }
            Icon { name: "user"; anchors.centerIn: parent; width: Math.round(room.size * 0.54); height: width; color: Theme.ink }
            // the ring: a bright head and a tail that thins out behind it, going round
            ShaderEffect {
                id: ring
                anchors.fill: parent; anchors.margins: -5
                property real turn: 0
                opacity: place.loading ? 1 : 0      // holds: nothing in it
                visible: opacity > 0
                Behavior on opacity { NumberAnimation { duration: Theme.base } }
                fragmentShader: "
                    varying highp vec2 qt_TexCoord0;
                    uniform lowp float qt_Opacity;
                    uniform highp float turn;
                    void main() {
                        highp vec2 p = qt_TexCoord0 * 2.0 - 1.0;
                        highp float r = length(p);
                        highp float along = fract(atan(p.y, p.x) / 6.2831853 - turn);
                        highp float band = smoothstep(0.86, 0.89, r) * (1.0 - smoothstep(0.97, 1.0, r));
                        gl_FragColor = vec4(1.0) * band * along * along * qt_Opacity;
                    }"
            }
            Ambient { effect: ring; uniform: "turn"; period: 900; running: ring.visible }
        }
    }
}
