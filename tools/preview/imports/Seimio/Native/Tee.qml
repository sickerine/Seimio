// Mac stand-in for the TV plugin's Tee: plays streams directly, and reports the tracks and chapters of a
// real anime Blu-ray release ([Salieri] Demon Slayer S3E9) so the player's menus can be previewed.
import QtQuick 2.12
QtObject {
    id: tee
    property int port: 0
    signal tracksRead(var tracks, bool matroska)
    signal chapter(double startMs, double endMs, string title)
    function open(url) { report.start(); return url }
    function stats() { return "mac" }
    property Timer report: Timer {
        interval: 50
        onTriggered: {
            tee.tracksRead([
                { number: 2, type: 2, codec: "A_FLAC", lang: "en", title: "ENG", default: true },
                { number: 3, type: 2, codec: "A_FLAC", lang: "ja", title: "JPN", default: false },
                { number: 4, type: 17, codec: "S_TEXT/ASS", lang: "en", title: "Signs & Songs 01", default: true, forced: true },
                { number: 5, type: 17, codec: "S_TEXT/ASS", lang: "en", title: "Dialogue 01", default: false },
                { number: 6, type: 17, codec: "S_HDMV/PGS", lang: "en", title: "Signs 02", default: false },
                { number: 9, type: 17, codec: "S_TEXT/ASS", lang: "en", title: "Dialog - ENG", default: true },
                { number: 10, type: 17, codec: "S_TEXT/ASS", lang: "en", title: "[Tenrai-Sensei] No Honorifics", default: false }
            ], true);
            var c = [[0, "Intro"], [37050, "OP"], [127050, "Part A"], [702050, "Part B"], [1291050, "ED"], [1381050, "Outro"]];
            for (var i = 0; i < c.length; i++) tee.chapter(c[i][0], -1, c[i][1]);
        }
    }
}
