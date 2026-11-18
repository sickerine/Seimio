// An account's round picture, or a person glyph when it has none. `focused` turns it white and lifts it,
// as a button does.
import QtQuick 2.12

Item {
    id: avatar
    property string source
    property bool focused: false
    width: 68; height: 68
    scale: focused ? 1.12 : 1
    Behavior on scale { NumberAnimation { duration: Theme.base; easing.type: Theme.spring; easing.overshoot: 1.3 } }
    Rectangle {
        anchors.fill: parent; radius: width / 2
        color: avatar.focused ? Theme.focusFill : Theme.fill
        border.width: avatar.focused ? 0 : 1; border.color: Theme.hairline
        Behavior on color { ColorAnimation { duration: Theme.fast } }
    }
    Icon { name: "user"; anchors.centerIn: parent; width: 38; height: 38; color: avatar.focused ? Theme.inkOnLight : Theme.ink; visible: !picture.artReady }
    // the picture, inside the ring the focus draws
    MediaCard {
        id: picture
        anchors.fill: parent; anchors.margins: 4
        radius: width / 2; showTitle: false; art: avatar.source; visible: avatar.source !== ""
    }
}
