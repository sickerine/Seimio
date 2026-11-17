// A vertical list of { label, icon, detail, value, badge, checked } rows (`badge`: an icon at the right,
// before the check) walked with Up/Down; OK triggers the
// focused row; Left and Right pass on to the parent (a row can be a value the parent steps). The
// highlight slides between rows. Rows arrive one after another each time the list is `shown`. With
// `maxRows`, a longer list shows that many and scrolls to keep the focused row and one either side in
// view; only the rows on screen exist (ListView).
import QtQuick 2.12

FocusScope {
    id: menu
    clip: scrolls
    property var model: []
    property int currentIndex: 0
    property bool shown: true
    property int rowHeight: 70
    property int rowSpacing: 8
    property int maxRows: 0                       // 0: every row shows
    signal triggered(int rowIndex)
    signal held(int rowIndex)                  // a long OK
    readonly property int stride: rowHeight + rowSpacing
    // where the focused row is drawn, for placing something beside it
    readonly property real currentY: currentIndex * stride - view.contentY
    readonly property bool scrolls: maxRows > 0 && model.length > maxRows
    implicitWidth: 408
    implicitHeight: (scrolls ? maxRows : model.length) * stride - rowSpacing

    // rows made while the list comes in play their entrance; rows scrolled to later are just there
    property bool entering: false
    onShownChanged: { entering = shown; if (shown) { enterDone.restart(); follow(true) } }
    Timer { id: enterDone; interval: 900; onTriggered: menu.entering = false }
    onCurrentIndexChanged: follow(false)
    onModelChanged: follow(true)
    // keeps the focused row and one either side in view; `jump` without the slide (opening)
    function follow(jump) {
        if (!scrolls) { slide.enabled = false; view.contentY = 0; return }
        var y = currentIndex * stride, top = view.contentY, want = top;
        if (y - stride < top) want = y - stride;
        else if (y + rowHeight + stride > top + view.height) want = y + rowHeight + stride - view.height;
        want = Math.max(0, Math.min(model.length * stride - rowSpacing - view.height, want));
        slide.enabled = !jump; view.contentY = want; slide.enabled = true;
    }

    // the highlight slides to its row (`at`) and moves with the scroll: two animations, one binding
    Rectangle {
        property real at: menu.currentIndex * menu.stride
        Behavior on at { NumberAnimation { duration: 260; easing.type: Theme.spring; easing.overshoot: 1.2 } }
        width: menu.width; height: menu.rowHeight; radius: 22
        y: at - view.contentY
        color: menu.activeFocus ? "#4dffffff" : "#26ffffff"
        Behavior on color { ColorAnimation { duration: Theme.fast } }
    }
    ListView {
        id: view
        width: menu.width; height: menu.implicitHeight
        interactive: false
        spacing: menu.rowSpacing
        model: menu.model.length
        Behavior on contentY { id: slide; NumberAnimation { duration: 260; easing.type: Theme.spring; easing.overshoot: 1.2 } }
        delegate: Reveal {
            readonly property var m: menu.model[index] || {}
            shown: menu.shown
            entrance: menu.entering
            delay: 60 + Math.max(0, index - Math.floor(view.contentY / menu.stride)) * 55
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
                width: parent.width - x - (parent.m.badge ? 118 : 76); elide: Text.ElideRight
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
                name: parent.m.badge || ""; visible: !!parent.m.badge
                anchors.right: parent.right; anchors.rightMargin: 24 + 28 + 14 - inkLeft; anchors.verticalCenter: parent.verticalCenter
                color: Theme.inkDim
            }
            Icon {
                name: "check"; visible: !!parent.m.checked
                anchors.right: parent.right; anchors.rightMargin: 24 - inkLeft; anchors.verticalCenter: parent.verticalCenter
            }
        }
    }
    Keys.onUpPressed: if (currentIndex > 0) currentIndex--
    Keys.onDownPressed: if (currentIndex < model.length - 1) currentIndex++
    OkPress { id: ok; onTapped: menu.triggered(menu.currentIndex); onHeld: menu.held(menu.currentIndex) }
    Keys.forwardTo: [ok]
}
