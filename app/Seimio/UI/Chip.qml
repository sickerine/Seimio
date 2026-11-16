// A rounded label. kind "glass" (translucent, the default), "solid" (white with dark text) or "rating"
// (gold with dark text). `icon` adds a leading icon; `size` is the font size and the chip scales with it.
// The padding is measured from the drawn icon, so both ends look equal.
import QtQuick 2.12

Rectangle {
    id: chip
    property string text
    property string icon
    property string kind: "glass"
    property int size: 22
    readonly property bool glass: kind === "glass"
    readonly property color ink: glass ? "#f2ffffff" : "#1a1a1a"
    readonly property int padX: Math.round(size * 0.75)

    height: Math.round(size * 1.9)
    radius: height / 2
    width: label.x + label.implicitWidth + padX
    color: kind === "solid" ? Theme.focusFill : kind === "rating" ? Theme.rating : Theme.fill
    border.width: glass ? 1 : 0
    border.color: Theme.hairline

    Icon {
        id: glyph
        visible: chip.icon !== ""
        name: chip.icon; color: chip.ink
        width: chip.size; height: chip.size
        x: chip.padX - inkLeft; anchors.verticalCenter: parent.verticalCenter
    }
    Text {
        id: label
        x: chip.icon !== "" ? glyph.x + glyph.inkRight + Math.round(chip.size * 0.35) : chip.padX
        anchors.verticalCenter: parent.verticalCenter
        text: chip.text; color: chip.ink
        font.family: Theme.face; font.pixelSize: chip.size; font.weight: chip.glass ? Font.Medium : Font.Bold
    }
}
