// The way things come and go. Its content is in while `value` is something and fades out when it is
// nothing, and `current` is what the content shows: `value` while it's in, and the last one it had all the
// way out. The end of the fade is the end: nothing in it changes or empties when the fade starts. So
// content never reads the state that hides it, only `current`:
//   Fade { value: page.notice; Chip { text: parent.current || "" } }
// `shown` says so separately when what it shows isn't what decides (a button for the segment playing,
// hidden while a menu is open). `dx`/`dy`: it slides in from that far off, and back out to it.
// tools/check.sh fails on an `opacity` that a condition switches, in a screen or a component, unless its
// line says why what it shows can't change under it (`// holds: ...`).
import QtQuick 2.12

Item {
    id: fade
    property var value: true
    property bool shown: !!value
    property var current
    property int duration: Theme.base
    property real dx: 0
    property real dy: 0
    property real t: 0                       // 0 gone, 1 in
    readonly property bool gone: t === 0
    implicitWidth: childrenRect.width
    implicitHeight: childrenRect.height
    opacity: t
    visible: t > 0
    transform: Translate { x: (1 - fade.t) * fade.dx; y: (1 - fade.t) * fade.dy }
    Behavior on t { enabled: fade.ready; NumberAnimation { duration: fade.duration; easing.type: Theme.ease } }
    property bool ready: false
    // `value` and `shown` often follow one property and bindings update in no set order, so a change is
    // taken once they have all run (as Latch does): a value emptied in the same breath as `shown` is never seen
    function take() { if (shown) current = value; t = shown ? 1 : 0 }
    onValueChanged: Qt.callLater(fade.take)
    onShownChanged: Qt.callLater(fade.take)
    Component.onCompleted: { take(); ready = true }
}
