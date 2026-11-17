// Holds a value while what shows it leaves. `current` follows `value` while `live`, and keeps the last
// live value once `live` turns false, so a panel fading out goes on showing what it showed instead of
// changing (or emptying) the moment its fade starts. When `live` turns true again it takes `value`.
//   Latch { id: kind; value: page.zone; live: panel.open }   ...   visible: kind.current === "subs"
// `value` and `live` usually follow one property (the zone), and bindings update in no set order, so a
// change is taken once they have all run (Qt.callLater, before the next frame), not mid-update.
import QtQuick 2.12

QtObject {
    id: latch
    property var value
    property bool live: true
    property var current
    function take() { if (live) current = value }
    onValueChanged: Qt.callLater(latch.take)
    onLiveChanged: Qt.callLater(latch.take)
    Component.onCompleted: current = value
}
