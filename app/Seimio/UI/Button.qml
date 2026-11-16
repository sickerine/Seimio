// A pill button with an icon and a label, or a round icon-only button whose name appears under it while
// focused. Focus turns it white with dark ink and lifts it with a small overshoot. `primary` keeps it
// white at rest. `progress` (0 to 100) draws a thin bar inside, for "Resume" buttons.
import QtQuick 2.12

Item {
    id: btn
    property string label
    property string icon
    property bool round: false
    property bool focused: false
    property bool primary: false
    property real progress: -1
    readonly property bool light: focused || primary
    readonly property color inkColor: light ? Theme.inkOnLight : Theme.ink

    implicitWidth: round ? 76 : text.implicitWidth + (icon !== "" ? 104 : 64)
    implicitHeight: 76
    width: implicitWidth; height: implicitHeight

    Rectangle {
        id: body
        anchors.fill: parent
        radius: height / 2
        color: btn.focused ? Theme.focusFill : btn.primary ? "#e6ffffff" : Theme.fillStrong
        border.width: btn.light ? 0 : 1
        border.color: "#26ffffff"
        scale: btn.focused ? (btn.round ? 1.08 : 1.06) : 1
        Behavior on scale { NumberAnimation { duration: 240; easing.type: Theme.spring; easing.overshoot: 1.6 } }
        Behavior on color { ColorAnimation { duration: Theme.fast } }

        Icon {
            visible: btn.icon !== ""
            name: btn.icon; color: btn.inkColor
            x: btn.round ? (parent.width - width) / 2 : 32
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            id: text
            visible: !btn.round
            x: btn.icon !== "" ? 72 : 32
            anchors.verticalCenter: parent.verticalCenter
            text: btn.label; color: btn.inkColor
            font.family: Theme.face; font.pixelSize: 28; font.weight: Font.DemiBold
        }
        Rectangle {
            visible: btn.progress > 0
            x: 34; y: parent.height - 14; width: parent.width - 68; height: 4; radius: 2
            color: btn.light ? "#26000000" : "#33ffffff"
            Rectangle { width: parent.width * Math.min(100, btn.progress) / 100; height: parent.height; radius: 2; color: btn.inkColor }
        }
    }
    // an icon-only button's name, under it while focused
    Text {
        visible: btn.round && opacity > 0
        anchors.horizontalCenter: parent.horizontalCenter; y: btn.height + 14
        text: btn.label; color: Theme.ink
        font.family: Theme.face; font.pixelSize: 21; font.weight: Font.Medium
        opacity: btn.focused ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.fast } }
    }
}
