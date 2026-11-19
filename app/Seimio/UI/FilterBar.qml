// One filter as a bar ({ key, options: [names], current }): its options as segments when there are three
// or fewer (all in sight, nothing to open), else its choice with chevrons. OK on a segment chooses it
// (`chosen`); OK on the choice asks for the list to drop (`dropped`), which is the owner's (a DropMenu
// by the bar).
import QtQuick 2.12

SegmentedBar {
    id: bar
    property var filter: null
    readonly property bool drops: !!filter && filter.options.length > 3
    signal chosen(int option)
    signal dropped()
    selectOnOk: true
    visible: !!filter
    model: !filter ? [] : drops ? [{ label: filter.options[filter.current] || "", trailing: "chevrons" }] : filter.options
    // The bar is on what its filter has chosen, at once (`put`: another filter is another bar's worth of
    // segments, and nothing glides across them). On either change: with a new filter, whether `drops`
    // has been worked out again when this is told of it is not given, and a bar going from a list to
    // segments stood on its first whatever was chosen.
    function settle() { put(filter && !drops ? filter.current : 0) }
    onFilterChanged: settle()
    onDropsChanged: settle()
    onTriggered: if (drops) dropped(); else chosen(index)
}
