// A pill button with an icon and a label, or a round icon-only button whose name appears under it while
// focused. Focus turns it white with dark ink and lifts it with a small overshoot. `primary` keeps it
// white at rest. `progress` (0 to 100) draws a thin bar under the label, for "Resume" buttons. The
// padding is measured from the drawn icon and text, equal on both sides, and the label and bar are
// centred together as one block, with the bar spanning exactly the icon and label above it. `trailing`
// is a small icon after the label: a chevron on a button that opens a menu, pointing where it opens.
// Given more width than it needs (a row's stretched button), the content stays centred. `fill` (0 to
// 1, < 0 for none) sweeps a tint across the button from the left, for a countdown, leaving the label
// where it is.
import QtQuick 2.12

Item {
    id: btn
    property string label
    property string icon
    property string trailing
    property bool round: false
    property bool focused: false
    property bool primary: false
    property real progress: -1
    property real fill: -1
    readonly property bool light: focused || primary
    readonly property color inkColor: light ? Theme.inkOnLight : Theme.ink

    readonly property int padX: 34
    readonly property int gap: 16                  // between the drawn icon and the label
    readonly property bool hasBar: !round && progress > 0
    // what's drawn, from the icon's ink to the label's end or the trailing icon's ink
    readonly property real contentWidth: (icon ? glyph.inkRight - glyph.inkLeft + gap : 0) + text.implicitWidth + (trailing ? 10 + tail.inkRight - tail.inkLeft : 0)
    implicitWidth: round ? 76 : contentWidth + 2 * padX
    implicitHeight: 76
    width: implicitWidth; height: implicitHeight

    Rectangle {
        id: body
        anchors.fill: parent
        radius: height / 2
        color: btn.focused ? Theme.focusFill : btn.primary ? "#e6ffffff" : Theme.fillStrong
        border.width: btn.light ? 0 : 1
        border.color: "#26ffffff"
        // the lift is 6%, at most 8 px a side, so a stretched button stays inside what it's lined up with
        scale: btn.focused ? (btn.round ? 1.08 : Math.min(1.06, 1 + 16 / Math.max(1, width))) : 1
        Behavior on scale { NumberAnimation { duration: 240; easing.type: Theme.spring; easing.overshoot: 1.6 } }
        Behavior on color { ColorAnimation { duration: Theme.fast } }

        // with a bar, the label rises so the block from the top of its capitals to the bottom of the bar
        // is centred (measured on the render: the line box has room above the capitals, so centring
        // the box would sit the block low)
        readonly property real labelY: parent.height / 2 - (btn.hasBar ? 9.5 : 0)
        // the sweep: the button's own shape, cut off at `fill`
        Item {
            visible: btn.fill > 0
            width: parent.width * Math.min(1, btn.fill); height: parent.height; clip: true
            Rectangle { width: body.width; height: body.height; radius: body.radius; color: btn.light ? "#24000000" : "#33ffffff" }
        }
        Icon {
            id: glyph
            visible: btn.icon !== ""
            name: btn.icon; color: btn.inkColor
            x: btn.round ? (parent.width - width) / 2 : (parent.width - btn.contentWidth) / 2 - inkLeft
            y: (btn.round ? parent.height / 2 : body.labelY) - height / 2
        }
        Text {
            id: text
            visible: !btn.round
            x: btn.icon !== "" ? glyph.x + glyph.inkRight + btn.gap : (parent.width - btn.contentWidth) / 2
            y: body.labelY - height / 2
            text: btn.label; color: btn.inkColor
            font.family: Theme.face; font.pixelSize: 28; font.weight: Font.DemiBold
        }
        Icon {
            id: tail
            visible: btn.trailing !== "" && !btn.round
            name: btn.trailing; color: btn.inkColor; width: 22; height: 22
            x: text.x + text.implicitWidth + 10 - inkLeft
            y: body.labelY - height / 2
        }
        Rectangle {
            visible: btn.hasBar
            x: (parent.width - btn.contentWidth) / 2; width: btn.contentWidth
            y: body.labelY + 17 + 9; height: 4; radius: 2
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
