// A row of Buttons walked with Left/Right; OK triggers the focused one. Other keys (Up, Down, Back)
// pass on to the parent. `model` entries are { label, icon, round, primary, progress }.
import QtQuick 2.12

FocusScope {
    id: row
    property var model: []
    property int currentIndex: 0
    property int spacing: 22
    signal triggered(int buttonIndex)
    implicitWidth: buttons.width
    implicitHeight: 76

    Row {
        id: buttons
        spacing: row.spacing
        Repeater {
            model: row.model
            Button {
                label: modelData.label || ""
                icon: modelData.icon || ""
                round: !!modelData.round
                primary: !!modelData.primary
                progress: modelData.progress === undefined ? -1 : modelData.progress
                focused: row.activeFocus && row.currentIndex === index
            }
        }
    }
    Keys.onLeftPressed: if (currentIndex > 0) currentIndex--
    Keys.onRightPressed: if (currentIndex < model.length - 1) currentIndex++
    Keys.onPressed: if (Remote.isOk(event.key)) { event.accepted = true; if (!event.isAutoRepeat) triggered(currentIndex) }
}
