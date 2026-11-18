// Card art that has been shown stays decoded: a row walked to its end and back shows its first cards'
// art at once, with nothing loading (the covers that came back empty and faded in, on the Anime tab and
// then on Continue Watching). Qt keeps ~2 MB of images nothing shows; 14 stills here are ~6 MB.
import QtQuick 2.12
import QtTest 1.12
import Seimio.UI 1.0

TestCase {
    name: "ArtCache"
    when: windowShown
    width: 1920; height: 400
    function art(i) {
        var c = ("0" + (16 + i * 16).toString(16)).slice(-2);
        return "data:image/svg+xml;base64," + Qt.btoa("<svg xmlns='http://www.w3.org/2000/svg' width='800' height='450'><rect width='800' height='450' fill='#" + c + "40" + c + "'/></svg>");
    }
    CardStrip {
        id: strip
        width: 1920; cardWidth: Theme.stillCard.width; cardHeight: Theme.stillCard.height; showTitles: false
        model: { var m = []; for (var i = 0; i < 14; i++) m.push({ art: art(i), episode: "E" + (i + 1) }); return m }
    }
    // the cards that have something to show (a TestCase is never visible, so not by that)
    function cards() { var out = []; for (var i = 0; i < strip.children.length; i++) { var c = strip.children[i]; if (c.artReady !== undefined && c.art) out.push(c) } return out }
    function allReady() { var c = cards(); for (var i = 0; i < c.length; i++) if (!c[i].artReady) return false; return c.length > 0 }

    function test_artStaysDecodedWhenARowComesBack() {
        tryVerify(allReady, 5000);
        strip.jumpTo(13);                                  // the first cards' art is let go by the cards
        tryVerify(allReady, 5000);
        strip.jumpTo(0);
        verify(allReady(), "the first cards' art is ready at once, not loading again");
        compare(ArtCache.reloads, 0);
    }
    function test_theBudgetHoldsTheMostRecentArt() {
        verify(ArtCache.held > 0 && ArtCache.held <= ArtCache.budget);
    }
}
