// A search field that opens out of a tab bar's search icon: a glass pill with the icon and what is typed.
// `open` grows it from `iconX` (where the icon sits, in its parent) to the middle of its parent. Given the
// remote (`focus`), its text has it, which brings up the TV's keyboard; opening takes nothing (it opens
// again over results that have the remote). Enter on that keyboard is `accepted`: the field takes the key,
// puts the keyboard away and says so, in that order. Left at the start of the text, Right at its end, Up
// and Down pass on.
// Back with the keyboard up goes to the keyboard, which closes: the field never sees that key, and what is
// typed stays (his rule, 2026-11-19: the Back after that, which the field's owner does see, is what
// clears it). With the keyboard away, OK brings it back.
import QtQuick 2.12

FocusScope {
    id: field
    property bool open: false
    property alias text: input.text
    signal accepted()
    property var keyboard: Qt.inputMethod    // (`visible`, `show()`, `hide()`, `commit()`: a test gives its own)
    readonly property bool typing: input.activeFocus && keyboard.visible      // the keyboard is up for this field
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
    property real openX: (parent ? parent.width - openWidth : 0) / 2       // where it is once open: the middle of its parent, unless something sits beside it
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
            // OK. With the keyboard up it is the keyboard's Enter (the remote's own OK goes to the keyboard
            // then), and the field does what the text would have, in its own order: what is being typed
            // is taken, the keyboard goes, then `accepted`. Left to the text, Qt puts the keyboard away
            // first and says `accepted` after, in the one press: the field once took a keyboard that
            // went without an Enter for Back and cleared the bar, so every Enter cleared the query the
            // moment before its search was made. With the keyboard away, OK brings it back.
            Keys.onPressed: {
                if (!Remote.isOk(event.key)) return;
                event.accepted = true;
                if (!field.keyboard.visible) { field.keyboard.show(); return }
                field.keyboard.commit(); field.keyboard.hide(); field.accepted();
            }
        }
    }
}
