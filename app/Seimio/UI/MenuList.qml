// A vertical list of { label, icon, detail, value, checked } rows walked with Up/Down; OK triggers the
// focused row; Left and Right pass on to the parent (a row can be a value the parent steps). The
// highlight slides between rows. Rows arrive one after another each time the list is `shown`.
import QtQuick 2.12

FocusScope {
    id: menu
    property var model: []
    property int currentIndex: 0
    property bool shown: true
    property int rowHeight: 70
    property int rowSpacing: 8
    signal triggered(int rowIndex)
    implicitWidth: 408
    implicitHeight: model.length * (rowHeight + rowSpacing) - rowSpacing

    Rectangle {
        width: menu.width; height: menu.rowHeight; radius: 22
        y: menu.currentIndex * (menu.rowHeight + menu.rowSpacing)
        color: menu.activeFocus ? "#4dffffff" : "#26ffffff"
        Behavior on y { NumberAnimation { duration: 260; easing.type: Theme.spring; easing.overshoot: 1.2 } }
        Behavior on color { ColorAnimation { duration: Theme.fast } }
    }
    Column {
        spacing: menu.rowSpacing
        Repeater {
            model: menu.model.length
            Reveal {
                readonly property var m: menu.model[index] || {}
                shown: menu.shown
                delay: 60 + index * 55
                dx: -18; dy: 0; duration: 300
                width: menu.width; height: menu.rowHeight
                Icon { name: parent.m.icon || ""; visible: !!parent.m.icon; x: 24; anchors.verticalCenter: parent.verticalCenter }
                Text {
                    id: label
                    x: parent.m.icon ? 68 : 24; anchors.verticalCenter: parent.verticalCenter
                    text: parent.m.label || ""; color: Theme.ink; textFormat: Text.PlainText
                    font.family: Theme.face; font.pixelSize: 27; font.weight: Font.Medium
                }
                // optional: dim words after the label, a value or a checkmark at the right edge
                Text {
                    visible: !!parent.m.detail
                    x: label.x + label.implicitWidth + 14; anchors.baseline: label.baseline
                    width: parent.width - x - 76; elide: Text.ElideRight
                    text: parent.m.detail || ""; color: Theme.inkDim; textFormat: Text.PlainText
                    font.family: Theme.face; font.pixelSize: 23
                }
                Text {
                    visible: parent.m.value !== undefined
                    anchors.right: parent.right; anchors.rightMargin: 24; anchors.baseline: label.baseline
                    text: parent.m.value !== undefined ? parent.m.value : ""; color: Theme.ink
                    font.family: Theme.face; font.pixelSize: 26; font.weight: Font.DemiBold
                }
                Icon {
                    name: "check"; visible: !!parent.m.checked
                    anchors.right: parent.right; anchors.rightMargin: 24 - inkLeft; anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }
    Keys.onUpPressed: if (currentIndex > 0) currentIndex--
    Keys.onDownPressed: if (currentIndex < model.length - 1) currentIndex++
    OkPress { id: ok; onTapped: menu.triggered(menu.currentIndex) }
    Keys.forwardTo: [ok]
}
