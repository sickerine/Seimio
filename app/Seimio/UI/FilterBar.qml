// One filter as a bar ({ key, options: [names], current }): its options as segments when they are few,
// else its choice with chevrons. OK on a segment chooses it (`chosen`); OK on the choice asks for the
// list to drop (`dropped`), which is the owner's (a DropMenu by the bar).
import QtQuick 2.12

SegmentedBar {
    id: bar
    property var filter: null
    readonly property bool drops: !!filter && filter.options.length > 4
    signal chosen(int option)
    signal dropped()
    selectOnOk: true
    visible: !!filter
    model: !filter ? [] : drops ? [{ label: filter.options[filter.current] || "", trailing: "chevrons" }] : filter.options
    onFilterChanged: currentIndex = filter && !drops ? filter.current : 0
    onTriggered: if (drops) dropped(); else chosen(index)
}
