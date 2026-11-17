// Mac stand-in for the TV plugin's Tee: plays streams directly and reads nothing from them.
import QtQuick 2.12
QtObject {
    property int port: 0
    signal tracksRead(var tracks, bool matroska)
    signal chapter(double startMs, double endMs, string title)
    function open(url) { return url }
}
