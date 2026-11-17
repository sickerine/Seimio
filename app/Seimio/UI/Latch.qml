// Holds a value while what shows it leaves. `current` follows `value` while `live`, and keeps the last
// live value once `live` turns false, so a panel fading out goes on showing what it showed instead of
// changing (or emptying) the moment its fade starts. When `live` turns true again it takes `value`.
//   Latch { id: kind; value: page.zone; live: panel.open }   ...   visible: kind.current === "subs"
import QtQuick 2.12

QtObject {
    property var value
    property bool live: true
    property var current
    onValueChanged: if (live) current = value
    onLiveChanged: if (live) current = value
    Component.onCompleted: current = value
}
