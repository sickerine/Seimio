// An account's round picture, or a person glyph when it has none, on a disc of glass: the tab bar's
// glass, which it stands beside (`glassSource`, `preblurred`, `sx`/`sy` and `shadow` are a
// SegmentedBar's `source`, `preblurred`, `sx`/`sy` and `shadow`). On a flat fill it read as a hole next
// to the bar. `focused` turns it white and lifts it, as a button does.
import QtQuick 2.12

Item {
    id: avatar
    property string source
    property bool focused: false
    property Item glassSource
    property bool preblurred: false
    property real sx: x
    property real sy: y
    property real shadow: 0
    width: 68; height: 68
    scale: focused ? 1.12 : 1
    Behavior on scale { NumberAnimation { duration: Theme.base; easing.type: Theme.spring; easing.overshoot: 1.3 } }
    Shadow { opacity: avatar.shadow; drop: 8 }
    Glass { anchors.fill: parent; radius: width / 2; source: avatar.glassSource; preblurred: avatar.preblurred; sx: avatar.sx; sy: avatar.sy }
    Rectangle {
        anchors.fill: parent; radius: width / 2
        color: Theme.focusFill
        opacity: avatar.focused ? 1 : 0      // holds: the focus's white disc: nothing in it
        Behavior on opacity { NumberAnimation { duration: Theme.fast } }
    }
    Icon { name: "user"; anchors.centerIn: parent; width: 38; height: 38; color: avatar.focused ? Theme.inkOnLight : Theme.ink; visible: !picture.artReady }
    // the picture, inside the ring the focus draws
    MediaCard {
        id: picture
        anchors.fill: parent; anchors.margins: 4
        radius: width / 2; showTitle: false; art: avatar.source; visible: avatar.source !== ""
    }
}
