// Every library control in its states (rest, focused, primary, with progress, watched, upcoming), for
// the visual check. Focus is set directly, since the preview window never has keyboard focus.
import QtQuick 2.12
import Eos.Window 0.1
import Seimio.UI 1.0
import Seimio.Data 1.0

WebOSWindow {
    id: win
    visible: true
    Rectangle { width: 1920; height: 1080; color: "#202024" }   // the grab has no window colour behind it
    Catalog { id: catalog; base: Qt.resolvedUrl("../../app/stremio/") }
    readonly property var cw: catalog.continueWatching
    readonly property var pop: catalog.popular.length ? catalog.popular[0].items : []
    function art(list, i) { return list.length > i ? list[i].art : "" }

    Row {
        x: 80; y: 80; spacing: 48
        MediaCard { width: 400; height: 225; art: win.art(win.cw, 0); title: "Focused"; episode: "E7"; progress: 40; focused: true }
        MediaCard { width: 400; height: 225; art: win.art(win.cw, 1); episode: "E3"; watched: true }
        MediaCard { width: 400; height: 225; art: win.art(win.cw, 2); episode: "E9"; upcoming: "24 Nov" }
        MediaCard { width: 220; height: 330; art: win.art(win.pop, 0); title: "Portrait" }
    }
    Column {
        x: 80; y: 520; spacing: 28
        Row {
            spacing: 22
            Button { label: "Resume E24"; icon: "play"; primary: true; progress: 80 }
            Button { label: "Resume E24"; icon: "play"; focused: true; progress: 30 }
            Button { label: "Add to library"; icon: "plus" }
            Button { label: "Mark watched"; icon: "check"; focused: true }
            Button { label: "Add"; icon: "plus"; round: true }
            Button { label: "Watched"; icon: "check"; round: true; focused: true }
            Button { label: "Subtitles"; trailing: "chevrons" }
            Button { label: "Audio"; trailing: "chevrons"; focused: true }
        }
        Row {
            spacing: 10
            Chip { kind: "solid"; icon: "play"; text: "E7" }
            Chip { kind: "rating"; icon: "star"; text: "7.7" }
            ChipRow { model: ["2017", "Magic", "Supernatural"] }
            Chip { size: 19; text: "24 min" }
        }
        Row {
            spacing: 32
            Repeater { model: ["play", "plus", "check", "search", "info", "star", "pin", "chevrons"]; Icon { name: modelData; width: 40; height: 40 } }
        }
        Row {
            spacing: 32
            SegmentedBar { source: win.contentItem; sx: 80; sy: 0; model: ["Home", "Movies", "Series", { icon: "search" }]; showFocus: true; currentIndex: 1 }
            SegmentedBar { source: win.contentItem; barHeight: 64; fontSize: 24; segmentPad: 44; model: ["Season 1", "Season 2"] }
            // selectOnOk: the cursor (white) on Movies, the selection (soft) still on All
            SegmentedBar { source: win.contentItem; barHeight: 64; fontSize: 22; segmentPad: 38; model: ["All", "TV", "Movies"]; selectOnOk: true; showFocus: true; currentIndex: 0; cursor: 2 }
            SegmentedBar { source: win.contentItem; barHeight: 64; fontSize: 22; segmentPad: 38; model: [{ label: "All genres", trailing: "chevrons" }]; showFocus: true }
        }
        MenuList { width: 408; model: [{ label: "Play", icon: "play" }, { label: "Add to library", icon: "plus" }, { label: "Mark watched", icon: "check" }] }
    }
}
