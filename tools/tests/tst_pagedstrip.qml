// PagedStrip: a turn that is asked for while another is on its way out replaces it. The show page's season
// bar asks for one per tab it passes, so moving across two tabs quickly left the row a season behind the
// bar (and the row then set the bar back).
import QtQuick 2.12
import QtTest 1.2
import Seimio.UI 1.0

TestCase {
    name: "PagedStrip"
    when: windowShown
    width: 1920; height: 400
    property var turns: []
    PagedStrip {
        id: strip
        width: 1920
        content: ({ cards: [{ art: "", episode: "E1" }, { art: "", episode: "E2" }], next: { key: 1, art: "", upcoming: "Season 2" } })
        onTurn: { var t = turns.slice(); t.push(key); turns = t }
    }
    function test_theLastTurnAskedForWins() {
        strip.turnTo(1, 1, 0);
        strip.turnTo(1, 2, 0);                              // the bar moved on before the cards were out
        tryVerify(function () { return !strip.turningNow }, 3000);
        compare(turns[turns.length - 1], 2, "the row ends on the season the bar ended on");
        compare(turns.length, 1, "and swaps once");
        strip.turnTo(-1, 0, 0);
        tryVerify(function () { return turns.length === 2 }, 3000);     // swapped: the cards are on their way in
        strip.turnTo(1, 2, 0);                              // a turn asked for then starts over
        tryVerify(function () { return !strip.turningNow }, 3000);
        compare(turns[turns.length - 1], 2);
    }
}
