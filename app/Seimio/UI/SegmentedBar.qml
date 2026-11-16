// A glass bar of segments (tabs, seasons) walked with Left/Right. The highlight stretches like liquid:
// its leading edge moves first and the trailing edge follows. It's white while the bar has focus.
// `model` entries are strings, or { label, icon } for icon-only segments; a new model of the same
// length relabels the segments in place. Other keys pass on to the
// parent. `source` is what the glass blurs; `sx`/`sy` the bar's position in it (see Glass).
import QtQuick 2.12

FocusScope {
    id: bar
    property var model: []
    property int currentIndex: 0
    property Item source
    property real sx: x
    property real sy: y
    property int fontSize: 26
    property int barHeight: 76
    property int segmentPad: 52
    property real shadow: 0          // opacity of a drop shadow under the bar, 0 for none
    property int moveDir: 1
    property bool showFocus: activeFocus  // draws the focused look; previews set it directly
    width: glass.width
    height: barHeight

    Shadow { opacity: bar.shadow; drop: 8 }
    Glass {
        id: glass
        source: bar.source
        sx: bar.sx; sy: bar.sy
        width: segments.width + 2 * inset; height: bar.barHeight; radius: height / 2
        readonly property int inset: Math.round(bar.barHeight * 0.13)
        property Item target: segments.children[bar.currentIndex] || null
        property real edgeL: target ? inset + target.x : inset
        property real edgeR: target ? inset + target.x + target.width : inset
        Behavior on edgeL { NumberAnimation { duration: bar.moveDir > 0 ? 420 : 240; easing.type: Theme.ease } }
        Behavior on edgeR { NumberAnimation { duration: bar.moveDir > 0 ? 240 : 420; easing.type: Theme.ease } }
        Rectangle {
            x: glass.edgeL; width: glass.edgeR - glass.edgeL
            y: glass.inset; height: glass.height - 2 * glass.inset; radius: height / 2
            color: bar.showFocus ? Theme.focusFill : "#2effffff"
            Behavior on color { ColorAnimation { duration: 200 } }
        }
        Row {
            id: segments
            x: glass.inset; height: parent.height
            Repeater {
                model: bar.model.length
                Item {
                    readonly property var m: bar.model[index]
                    readonly property string label: typeof m === "string" ? m : (m && m.label || "")
                    readonly property string icon: typeof m === "string" ? "" : (m && m.icon || "")
                    readonly property bool current: bar.currentIndex === index
                    readonly property color ink: bar.showFocus && current ? Theme.inkOnLight : Theme.ink
                    width: icon !== "" ? bar.barHeight : text.implicitWidth + bar.segmentPad
                    height: segments.height
                    Text {
                        id: text
                        visible: parent.icon === ""
                        anchors.centerIn: parent
                        text: parent.label; color: parent.ink
                        font.family: Theme.face; font.pixelSize: bar.fontSize; font.weight: parent.current ? Font.DemiBold : Font.Medium
                        Behavior on color { ColorAnimation { duration: 200 } }
                    }
                    Icon { visible: parent.icon !== ""; name: parent.icon; anchors.centerIn: parent; color: parent.ink }
                }
            }
        }
    }
    Keys.onLeftPressed: if (currentIndex > 0) { moveDir = -1; currentIndex-- }
    Keys.onRightPressed: if (currentIndex < model.length - 1) { moveDir = 1; currentIndex++ }
}
