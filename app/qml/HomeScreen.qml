// Home: rows of cards. Each row (a CardStrip) handles Left/Right and OK itself; Home moves between rows
// with Up/Down. The first row sits under the hero info; below it the info steps aside (`scrolled`) and
// the focused row moves up. Up from the first row leaves through `exitTop`. Each row keeps its position.
import QtQuick 2.12
import Seimio.UI 1.0

FocusScope {
    id: home
    property var rows: []               // [{ title, kind: "landscape" | "portrait", items: [...] }]
    property bool shown: true           // false sinks the rows away (a page or sheet is open)
    // keeps the focused card drawn focused while something over Home has the remote (quick actions)
    property bool holdFocus: false
    property int row: 0
    property var cols: []
    readonly property var focusItem: rows[row] && cols.length ? rows[row].items[cols[row]] || null : null
    readonly property bool scrolled: row > 0
    // the focused card's rectangle once lifted, for keeping it clear of a frost
    readonly property rect focusRect: rows[row]
        ? Qt.rect(Theme.margin - cardW(row) * 0.05, column.y + rowY(row) + 56 - cardH(row) * 0.05, cardW(row) * 1.1, cardH(row) * 1.1)
        : Qt.rect(0, 0, 0, 0)
    readonly property real focusCardWidth: rows[row] ? cardW(row) : 0
    signal activated(var item)
    signal held(var item)
    signal exitTop()

    function cardW(r) { return rows[r].kind === "landscape" ? 400 : 220 }
    function cardH(r) { return rows[r].kind === "landscape" ? 225 : 330 }
    function rowH(r) { return 56 + cardH(r) + 84 }
    function rowY(r) { var y = 0; for (var i = 0; i < r; i++) y += rowH(i); return y }
    function setCol(r, c) { if (cols[r] === c) return; var next = cols.slice(); next[r] = c; cols = next }
    // new rows keep each row's position where it still exists
    onRowsChanged: {
        cols = rows.map(function (r, i) { return Math.max(0, Math.min(cols[i] || 0, r.items.length - 1)) });
        row = Math.max(0, Math.min(row, rows.length - 1));
    }

    Item {
        id: column
        width: home.width; height: home.rows.length ? home.rowY(home.rows.length) : 0
        y: (home.shown ? (home.row > 0 ? 380 : 610) : 1200) - (home.rows.length ? home.rowY(home.row) : 0)
        opacity: home.shown ? 1 : 0
        visible: opacity > 0
        Behavior on y { NumberAnimation { duration: 480; easing.type: Theme.ease } }
        Behavior on opacity { NumberAnimation { duration: 320 } }
        Repeater {
            model: home.rows.length
            Item {
                readonly property var r: home.rows[index]
                y: home.rowY(index); width: home.width; height: home.rowH(index)
                opacity: home.row === index ? 1 : 0.6
                Behavior on opacity { NumberAnimation { duration: 300 } }
                Text {
                    x: Theme.margin; text: parent.r.title; color: Theme.ink
                    font.family: Theme.face; font.pixelSize: 30; font.weight: Font.DemiBold
                }
                CardStrip {
                    y: 56; width: home.width
                    model: parent.r.items
                    cardWidth: home.cardW(index); cardHeight: home.cardH(index)
                    spacing: parent.r.kind === "landscape" ? 40 : 36
                    focus: home.row === index
                    showFocus: activeFocus || (home.holdFocus && home.row === index)
                    onCurrentIndexChanged: home.setCol(index, currentIndex)
                    onActivated: home.activated(parent.r.items[cardIndex])
                    onHeld: home.held(parent.r.items[cardIndex])
                }
            }
        }
    }
    Keys.onUpPressed: if (row > 0) row--; else exitTop()
    Keys.onDownPressed: if (row < rows.length - 1) row++
}
