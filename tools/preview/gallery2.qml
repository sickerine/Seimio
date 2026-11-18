// The gallery's second sheet (see gallery.qml): what comes and goes, and rows made of pages.
import QtQuick 2.12
import Eos.Window 0.1
import Seimio.UI 1.0

WebOSWindow {
    id: win
    visible: true
    Rectangle { width: 1920; height: 1080; color: "#202024" }   // the grab has no window colour behind it
    Column {
        x: 80; y: 80; spacing: 56
        Row {
            spacing: 48
            // a list dropped from a control, on its chosen row
            DropMenu { open: true; currentIndex: 1; model: [{ label: "Winter 2027", detail: "Next" }, { label: "Fall 2026", detail: "Now", checked: true }, { label: "Summer 2026" }] }
            // a notice that comes and goes, saying what it said all the way out (Fade)
            Fade { value: "Loading Summer 2026"; Chip { kind: "solid"; size: 24; text: parent.current || "" } }
            // the bars' two pills: the selection (soft, on All) and the cursor (white, on Movies)
            SegmentedBar { source: win.contentItem; barHeight: 64; fontSize: 22; segmentPad: 38; model: ["All", "TV", "Movies"]; selectOnOk: true; showFocus: true; currentIndex: 0; cursor: 2 }
        }
        // one page of a longer run, with a tile for the page either side: stills, then posters
        PagedStrip {
            width: 1760; cardWidth: Theme.stillCard.width; cardHeight: Theme.stillCard.height; showTitles: false; nextLabels: false
            content: ({ cards: [{ art: "", episode: "E1", watched: true }, { art: "", episode: "E2", progress: 40 }],
                        prev: { key: 0, art: "", upcoming: "Season 1", episode: "26 episodes" }, next: { key: 2, art: "", upcoming: "Season 3", episode: "11 episodes" } })
        }
        PagedStrip {
            width: 1760; cardWidth: Theme.posterCard.width; cardHeight: Theme.posterCard.height; showTitles: false; nextLabels: false
            content: ({ cards: [{ art: "", episode: "2020" }, { art: "", episode: "2025" }],
                        prev: { key: 0, art: "", upcoming: "Season 5", episode: "8 episodes" }, next: { key: 2, art: "", upcoming: "Specials", episode: "7 specials" } })
        }
    }
}
