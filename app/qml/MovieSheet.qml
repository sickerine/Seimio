// A glass sheet for a movie: actions and more titles like it. It rises when `open`; its buttons arrive
// one after another. The ButtonRow handles Left/Right/OK; Back passes on to the app.
import QtQuick 2.12
import Seimio.UI 1.0

FocusScope {
    id: sheet
    property bool open: false
    property Item source
    property var related: []
    x: 80; width: 1760; height: 430
    y: open ? 570 : 1120
    Behavior on y { NumberAnimation { duration: 520; easing.type: Theme.ease } }
    onOpenChanged: if (open) actions.currentIndex = 0

    Glass {
        anchors.fill: parent
        source: sheet.source
        sx: sheet.x; sy: sheet.y
        radius: 44
        tint: Qt.rgba(0.05, 0.05, 0.07, 0.3)
        Row {
            x: 56; y: 52; spacing: 20
            Reveal {
                shown: sheet.open; delay: 140
                ButtonRow {
                    id: actions
                    focus: true
                    model: [{ label: "Play", icon: "play", primary: true }, { label: "Add to library", icon: "plus" }, { label: "Mark watched", icon: "check" }]
                }
            }
        }
        Text {
            x: 56; y: 170; text: "More like this"; color: Theme.ink
            font.family: Theme.face; font.pixelSize: 28; font.weight: Font.DemiBold
        }
        CardStrip {
            x: 0; y: 222; width: parent.width
            inset: 56; cardWidth: 120; cardHeight: 180; spacing: 24; cardRadius: 12
            showTitles: false
            model: sheet.related
        }
    }
}
