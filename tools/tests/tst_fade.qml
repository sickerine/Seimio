// Fade: what leaves keeps showing what it showed until it has gone. A chip whose words were bound to the
// state that hid it ("Loading Summer 2026") emptied the moment its fade began.
import QtQuick 2.12
import QtTest 1.2
import Seimio.UI 1.0

// (the root is an Item that shows: TestCase is not visible itself, and a Row under something invisible
// isn't told when one of its children comes or goes, so it lays out nothing again)
Item {
    id: root
    width: 400; height: 100
    property string notice: ""
    Fade { id: fade; value: root.notice; duration: 120; Text { text: parent.current || "" } }
    // a row of three, the one in the middle coming and going with its place
    property bool middle: true
    property var steps: []                   // where the one after it was at each move, and how much of the middle one showed
    Row {
        y: 40; spacing: 20
        Rectangle { width: 100; height: 20 }
        Fade { id: place; value: root.middle; gap: 20; duration: 300; Rectangle { width: 80; height: 20 } }
        Rectangle { id: after; width: 60; height: 20; onXChanged: root.steps.push([x, place.opacity]) }
    }

    TestCase {
        name: "Fade"
        when: windowShown
        // In a row, what follows slides over as the one before it leaves, and is never moved at a stroke: a
        // Row lays out what is visible, so a bar that only faded took its width and the gap out of the row in
        // the frame it turned invisible. And the two never cross: it has faded before its place closes.
        function test_inARowItsPlaceClosesAfterItHasFaded() {
            tryCompare(after, "x", 220); tryCompare(place, "opacity", 1);
            root.steps = []; root.middle = false;
            tryVerify(function () { return place.gone });
            tryCompare(after, "x", 120);        // where it is with the middle one out of the row
            var steps = root.steps, at = 220;
            verify(steps.length >= 4, "it slid: " + steps.length + " moves");
            for (var i = 0; i < steps.length; i++) {
                verify(at - steps[i][0] < 50, "no move of " + (at - steps[i][0]) + " at a stroke");
                compare(steps[i][1], 0, "the middle one had faded before the next moved");
                at = steps[i][0];
            }
            root.steps = []; root.middle = true;
            tryCompare(place, "opacity", 1);
            compare(after.x, 220);
            // (it may begin to show in the frame its place comes fully open, and not before)
            steps = root.steps;
            for (i = 0; i < steps.length; i++) verify(steps[i][1] === 0 || steps[i][0] === 220, "coming in, its place opened before it showed");
        }
        function test_holdsItsWordsUntilGone() {
            verify(fade.gone, "nothing to show: not there");
            root.notice = "Loading Summer 2026";
            tryCompare(fade, "t", 1);
            compare(fade.current, "Loading Summer 2026");
            root.notice = "";                                   // the season is in: the chip leaves
            wait(40);
            verify(!fade.gone && fade.t < 1, "on its way out");
            compare(fade.current, "Loading Summer 2026", "still saying what it said");
            tryVerify(function () { return fade.gone });
            root.notice = "Couldn't load Winter 2027";
            tryCompare(fade, "current", "Couldn't load Winter 2027");
        }
    }
}
