// Shared look: type, colours, layout and motion. Components read these instead of literals, so the
// whole app changes together.
pragma Singleton
import QtQuick 2.12

QtObject {
    // type: Instrument Sans, bundled as static weights (Qt 5.12 handles variable fonts poorly)
    readonly property FontLoader regular: FontLoader { source: "assets/InstrumentSans-400.ttf" }
    readonly property FontLoader medium: FontLoader { source: "assets/InstrumentSans-500.ttf" }
    readonly property FontLoader semibold: FontLoader { source: "assets/InstrumentSans-600.ttf" }
    readonly property FontLoader bold: FontLoader { source: "assets/InstrumentSans-700.ttf" }
    readonly property string face: "Instrument Sans"

    // layout
    readonly property int margin: 120                 // left edge of content on every screen
    readonly property int screenWidth: 1920
    readonly property int screenHeight: 1080
    // a card's art is decoded this much larger than the card, so its focus lift stays sharp; anything
    // keeping a card's image decoded (a cover pool) asks for the same size and crop, to share the decode
    readonly property real cardDecode: 1.15

    // colours
    readonly property color ink: "white"
    readonly property color inkSoft: "#d9ffffff"       // body text
    readonly property color inkDim: "#ccffffff"        // secondary body text
    readonly property color inkOnLight: "#111111"      // text on white (focused controls)
    readonly property color fill: "#29ffffff"          // chips and resting controls
    readonly property color fillStrong: "#33ffffff"
    readonly property color hairline: "#1fffffff"
    readonly property color focusFill: "white"
    readonly property color rating: "#f5c518"

    // motion
    readonly property int fast: 180
    readonly property int base: 280
    readonly property int slow: 420
    readonly property int ease: Easing.OutCubic
    readonly property int spring: Easing.OutBack
}
