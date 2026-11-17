// Mac stand-in for the TV plugin's SubtitleLayer (libass): draws nothing.
import QtQuick 2.12
Item {
    property QtObject source
    property int track: -1
    property real position: 0
    property bool playing: false
    property int delay: 0
    function reset() {}
    function info() { return "mac" }
}
