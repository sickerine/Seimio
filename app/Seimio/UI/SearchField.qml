// A search field that opens out of a tab bar's search icon: a glass pill with the icon and what is typed.
// `open` grows it from `iconX` (where the icon sits, in its parent) to the middle of its parent. Given the
// remote (`focus`), its text has it, which brings up the TV's keyboard; opening takes nothing (it opens
// again over results that have the remote). Enter on that keyboard is `accepted`. Left at the start of the
// text, Up and Down pass on.
import QtQuick 2.12

FocusScope {
    id: field
    property bool open: false
    property alias text: input.text
    signal accepted()
    property Item source
    property bool preblurred: false
    property real sy: y
    property real iconX: 0
    property int openWidth: 900
    property int barHeight: 76
    // 0 the icon, 1 the field
    property real t: 0
    states: State { when: field.open; PropertyChanges { target: field; t: 1 } }
    transitions: Transition { NumberAnimation { property: "t"; duration: Theme.slow; easing.type: Theme.ease } }
    readonly property real openX: (parent ? parent.width - openWidth : 0) / 2
    x: iconX + (openX - iconX) * t
    width: barHeight + (openWidth - barHeight) * t; height: barHeight
    opacity: Math.min(1, t * 2.5)
    visible: t > 0

    Glass { anchors.fill: parent; radius: height / 2; source: field.source; preblurred: field.preblurred; sx: field.x; sy: field.sy }
    Icon { id: glyph; name: "search"; width: 30; height: 30; x: (field.barHeight - width) / 2; anchors.verticalCenter: parent.verticalCenter; color: Theme.ink }
    Item {
        x: field.barHeight - 6; width: parent.width - x - 34; height: parent.height
        clip: true
        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: input.text === "" && input.preeditText === ""
            text: "Search"; color: Theme.inkDim; font: input.font
        }
        TextInput {
            id: input
            focus: true
            width: parent.width; anchors.verticalCenter: parent.verticalCenter
            color: Theme.ink; selectionColor: Theme.fillStrong; selectedTextColor: Theme.ink
            font.family: Theme.face; font.pixelSize: 30; font.weight: Font.Medium
            inputMethodHints: Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase
            onAccepted: field.accepted()
        }
    }
}
