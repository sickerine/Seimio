// A rounded label. kind "glass" (translucent, the default), "solid" (white with dark text), "rating"
// (gold with dark text) or "tint" (`tint` with white text, for tags that need telling apart at a glance). `icon` adds a leading icon; `size` is the font size and the chip scales with it.
// The padding is measured from the drawn icon, so both ends look equal.
import QtQuick 2.12

Rectangle {
    id: chip
    property string text
    property string icon
    property string kind: "glass"
    property int size: 22
    property color tint: Theme.fill
    readonly property bool glass: kind === "glass"
    readonly property color ink: glass || kind === "tint" ? "#f2ffffff" : "#1a1a1a"
    readonly property int padX: Math.round(size * 0.75)

    height: Math.round(size * 1.9)
    radius: height / 2
    width: label.x + label.implicitWidth + padX
    color: kind === "solid" ? Theme.focusFill : kind === "rating" ? Theme.rating : kind === "tint" ? tint : Theme.fill
    border.width: glass ? 1 : 0
    border.color: Theme.hairline

    // the icon exists only when there is one: most chips have none, and lists create many chips
    Loader {
        id: glyph
        active: chip.icon !== ""
        width: chip.size; height: chip.size
        x: chip.padX - (item ? item.inkLeft : 0); anchors.verticalCenter: parent.verticalCenter
        sourceComponent: Icon { name: chip.icon; color: chip.ink; width: chip.size; height: chip.size }
    }
    Text {
        id: label
        x: glyph.item ? glyph.x + glyph.item.inkRight + Math.round(chip.size * 0.35) : chip.padX
        anchors.verticalCenter: parent.verticalCenter
        text: chip.text; color: chip.ink; textFormat: Text.PlainText
        font.family: Theme.face; font.pixelSize: chip.size; font.weight: chip.glass ? Font.Medium : Font.Bold
    }
}
