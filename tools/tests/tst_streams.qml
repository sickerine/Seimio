// Streams reads release names exactly as the patched Stremio app does. streams-fixture.json holds that
// app's answers (stremio-webos stream-filters.js and its badge code) for its test titles and its saved
// Torrentio lists, made once by running them through that code.
import QtQuick 2.12
import QtTest 1.2
import Seimio.Data 1.0

TestCase {
    name: "Streams"
    Streams { id: streams }
    function test_matchesThePatchedApp() {
        var x = new XMLHttpRequest();
        x.open("GET", Qt.resolvedUrl("streams-fixture.json"), false); x.send();
        var cases = JSON.parse(x.responseText), wrong = [];
        verify(cases.length > 500);
        for (var i = 0; i < cases.length; i++) {
            var c = cases[i], got = streams.read(c.name, c.title, c.anime);
            for (var k in c.want) if (JSON.stringify(got[k]) !== JSON.stringify(c.want[k]))
                wrong.push(k + ": want " + JSON.stringify(c.want[k]) + " got " + JSON.stringify(got[k]) + " | " + c.title.split("\n")[0]);
        }
        compare(wrong.length, 0, wrong.slice(0, 15).join("\n"));
    }
}
