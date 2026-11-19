// The way things come and go. Its content is in while `value` is something and fades out when it is
// nothing, and `current` is what the content shows: `value` while it's in, and the last one it had all the
// way out. The end of the fade is the end: nothing in it changes or empties when the fade starts. So
// content never reads the state that hides it, only `current`:
//   Fade { value: page.notice; Chip { text: parent.current || "" } }
// `shown` says so separately when what it shows isn't what decides (a button for the segment playing,
// hidden while a menu is open). `dx`/`dy`: it slides in from that far off, and back out to it.
// In a Row its place goes with it when `gap` is the row's spacing: it fades out in the first half of
// its time and its place closes in the second, the row's own gap with it, so what follows it in the row
// slides over; coming in, its place opens first. A Row lays out what is visible, so one that only
// faded moved everything after it by its width and the spacing in the frame it turned invisible.
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
    property real gap: -1                    // in a Row, its spacing: the fade's place closes and opens with it
    implicitWidth: childrenRect.width
    implicitHeight: childrenRect.height
    opacity: gap < 0 ? t : Math.max(0, t * 2 - 1)      // holds: the fade itself (what is in it reads `current`); with a place to close, it has faded by half its time
    visible: t > 0
    // (closed, it is the row's spacing narrower than nothing: the row's gap after it is taken back, and
    // what follows is where it will be once this is out of the row. Its place opens and closes on a
    // curve of its own half of the time, slow at both ends; with one curve over the whole time the
    // place closed slowly and opened in a few frames.)
    readonly property real open: { var u = Math.min(1, t * 2); return u * u * (3 - 2 * u) }
    Binding { target: fade; property: "width"; when: fade.gap >= 0; value: fade.open * (fade.implicitWidth + fade.gap) - fade.gap }
    transform: Translate { x: (1 - fade.t) * fade.dx; y: (1 - fade.t) * fade.dy }
    Behavior on t { enabled: fade.ready; NumberAnimation { duration: fade.duration; easing.type: fade.gap < 0 ? Theme.ease : Easing.Linear } }
    property bool ready: false
    // `value` and `shown` often follow one property and bindings update in no set order, so a change is
    // taken once they have all run (as Latch does): a value emptied in the same breath as `shown` is never seen
    function take() { if (shown) current = value; t = shown ? 1 : 0 }
    onValueChanged: Qt.callLater(fade.take)
    onShownChanged: Qt.callLater(fade.take)
    Component.onCompleted: { take(); ready = true }
}
