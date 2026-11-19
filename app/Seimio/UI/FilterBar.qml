// One filter as a bar ({ key, options: [names], current }): its options as segments when there are two or
// fewer (a switch: both in sight, nothing to open), else its choice with chevrons, as wide as its longest
// option (SegmentedBar's `room`). OK on a segment chooses it (`chosen`); OK on the choice asks for the
// list to drop (`dropped`), which is the owner's (a DropMenu by the bar).
import QtQuick 2.12

SegmentedBar {
    id: bar
    property var filter: null
    readonly property bool drops: !!filter && filter.options.length > 2
    signal chosen(int option)
    signal dropped()
    selectOnOk: true
    visible: !!filter
    model: !filter ? [] : drops ? [{ label: filter.options[filter.current] || "", trailing: "chevrons", room: filter.options }] : filter.options
    // (on either: with a new filter, whether `drops` has been worked out again when this is told of it is
    // not given, and a bar going from a list to a switch stood on its first segment whatever was chosen)
    function settle() { currentIndex = filter && !drops ? filter.current : 0 }
    onFilterChanged: settle()
    onDropsChanged: settle()
    onTriggered: if (drops) dropped(); else chosen(index)
}
