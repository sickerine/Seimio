// A search field that opens out of a tab bar's search icon: a glass pill with the icon and what is typed.
// `open` grows it from `iconX` (where the icon sits, in its parent) to the middle of its parent. Given the
// remote (`focus`), its text has it, which brings up the TV's keyboard; opening takes nothing (it opens
// again over results that have the remote). Enter on that keyboard is `accepted`: the field takes the key,
// puts the keyboard away and says so, in that order. Left at the start of the text, Right at its end, Up
// and Down pass on.
// Back with the keyboard up goes to the keyboard, which closes: the field never sees that key. A keyboard
// that goes away while the field still has the remote was that Back (after Enter it isn't): `dismissed`.
// With the keyboard away, OK brings it back.
import QtQuick 2.12

FocusScope {
    id: field
    property bool open: false
    property alias text: input.text
    signal accepted()
    signal dismissed()
    property bool entered: false             // Enter closed the keyboard, not Back
    property var keyboard: Qt.inputMethod    // (`visible`, `show()`, `hide()`, `commit()`: a test gives its own)
    Connections {
        target: field.keyboard
        onVisibleChanged: {
            if (field.keyboard.visible) field.entered = false;       // up again: the next time it goes, it's Back unless Enter says so
            else if (input.activeFocus && !field.entered) field.dismissed();
        }
    }
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
            onTextChanged: field.entered = false
            onActiveFocusChanged: if (activeFocus) field.entered = false
            // OK. With the keyboard up it is the keyboard's Enter (the remote's own OK goes to the keyboard
            // then), and the field does what the text would have, in the order that works: what is being
            // typed is taken, the keyboard goes, then `accepted`. Left to the text, Qt put the keyboard
            // away first and said `accepted` after, so the keyboard going read as Back: the bar was
            // cleared the moment before its search was made. (The TV, 2026-11-19, as logged in one press:
            // the key, the keyboard away, the text cleared, `accepted` with nothing.) With the keyboard
            // away, OK brings it back.
            Keys.onPressed: {
                if (!Remote.isOk(event.key)) return;
                event.accepted = true;
                if (!field.keyboard.visible) { field.keyboard.show(); return }
                field.keyboard.commit(); field.entered = true; field.keyboard.hide(); field.accepted();
            }
        }
    }
}
