// A soft drop shadow under its parent's rounded rectangle. Put it first among the parent's children so
// it draws behind them. It's a 9-slice image whose shape sits 48px inside its edges, so it hugs any
// size; `drop` pushes it down as if lit from above.
import QtQuick 2.12

BorderImage {
    property real drop: 8
    source: "assets/shadow9.png"
    border { left: 79; right: 79; top: 79; bottom: 79 }
    x: -48; y: -48 + drop
    width: parent ? parent.width + 96 : 0
    height: parent ? parent.height + 96 : 0
    // a fully transparent shadow still costs a large blended quad; skip drawing it
    visible: opacity > 0
}
