// A row of glass chips from an array of strings (empty strings are skipped by the caller). A new array
// of the same length retexts the chips in place instead of creating new ones. With `stagger` (ms) the
// chips arrive one after another each time `model` changes.
import QtQuick 2.12

Row {
    id: row
    property var model: []
    property int size: 22
    property int stagger: 0
    spacing: 10
    Repeater {
        model: row.model.length
        Reveal {
            id: reveal
            dy: 0
            delay: row.stagger > 0 ? 60 + index * row.stagger : 0
            duration: row.stagger > 0 ? 260 : 0
            Connections { target: row; enabled: row.stagger > 0; onModelChanged: reveal.play() }
            Chip { text: row.model[index] || ""; size: row.size }
        }
    }
}
