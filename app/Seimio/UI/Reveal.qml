// Fades and slides its content in each time `shown` turns true, after `delay` ms, so groups of items can
// arrive one after another. Turning `shown` off leaves it as it is, so it leaves with its container;
// the next entrance starts from hidden. A Reveal created with `shown` already true plays its entrance
// once, or with `entrance` false (a row scrolled into a list that's already in) is simply there.
import QtQuick 2.12

Item {
    id: reveal
    property bool shown: true
    property bool entrance: true
    property int delay: 0
    property real dx: 0
    property real dy: 24
    property int duration: Theme.slow
    property real t: 0
    implicitWidth: childrenRect.width
    implicitHeight: childrenRect.height
    opacity: t
    transform: Translate { x: (1 - reveal.t) * reveal.dx; y: (1 - reveal.t) * reveal.dy }

    function play() { t = 0; anim.restart() }
    onShownChanged: if (shown) play(); else anim.stop()
    Component.onCompleted: if (shown && entrance) play(); else if (shown) t = 1
    SequentialAnimation {
        id: anim
        PauseAnimation { duration: reveal.delay }
        NumberAnimation { target: reveal; property: "t"; to: 1; duration: reveal.duration; easing.type: Theme.ease }
    }
}
