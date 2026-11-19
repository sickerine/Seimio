// Swap: the one way what is on show becomes another (app/Seimio/UI/Swap.qml). A test a rule.
import QtQuick 2.12
import QtTest 1.2
import Seimio.UI 1.0

TestCase {
    id: tc
    name: "Swap"
    when: windowShown
    width: 200; height: 100

    // what an owner does: what it wants, and whether that one's content is loaded
    property var want: null
    property var loaded: ({})                // by name: its content is in
    property int switches: 0
    property int settles: 0
    property int cuts: 0
    Swap {
        id: swap
        want: tc.want
        ready: !tc.want || !!tc.loaded[tc.want.name]
        outMs: 60; inMs: 120
        same: function (a, b) { return a.name === b.name }
        onSwitched: tc.switches++
        onSettled: tc.settles++
        onCut: tc.cuts++
    }
    // (each test's things have names of their own: what the one before left on show is another thing)
    property int run: 0
    function thing(name) { return { name: name + run } }
    function load(name) { var l = {}; for (var k in loaded) l[k] = true; l[name + run] = true; loaded = l }
    function init() {
        run++; want = null; loaded = ({}); over = null; have = ({}); broken = ({});
        tryVerify(function () { return swap.phase === "rest" && swap.level === 0 && cross.phase === "rest" });
        switches = settles = cuts = 0;
    }
    function rested(on) { tryVerify(function () { return swap.phase === "rest" && swap.shown === on && swap.level === 1 }, 2000, "at rest on " + (on ? on.name : on)) }

    function test_theFirstOneComesIn() {
        var a = thing("a"); load("a"); want = a;
        verify(swap.shown !== a && swap.phase === "rest", "nothing is decided inside the assignment");
        rested(a);
        compare(switches, 1); compare(settles, 1); verify(!swap.busy);
    }
    function test_whatIsOnShowStaysUntilTheNextIsReady() {
        var a = thing("a"), b = thing("b"); load("a"); want = a; rested(a);
        want = b;                                           // its content isn't in
        wait(150);
        compare(swap.shown, a); compare(swap.level, 1, "fully in, nothing emptied"); compare(swap.phase, "waiting"); verify(swap.busy);
        load("b");
        tryCompare(swap, "phase", "leaving");
        compare(swap.shown, a, "still the old one while it goes out");
        rested(b);
        compare(switches, 2);
    }
    function test_itBecomesTheOtherWhenNothingIsSeen() {
        var a = thing("a"), b = thing("b"); load("a"); load("b"); want = a; rested(a);
        var levels = [];
        var c = Qt.createQmlObject('import QtQuick 2.12; Connections { property var seen: []; onSwitched: seen.push(target.level) }', swap);
        c.target = swap;
        want = b; rested(b);
        compare(c.seen.length, 1); compare(c.seen[0], 0, "switched with the old one all the way out");
        c.destroy();
    }
    function test_wantedAgainItComesBackFromWhereItIs() {
        var a = thing("a"), b = thing("b"); load("a"); load("b"); want = a; rested(a);
        want = b;
        tryVerify(function () { return swap.phase === "leaving" && swap.level < 0.8 && swap.level > 0.1 });
        var at = swap.level;
        want = a;                                           // changed its mind half way out
        tryCompare(swap, "phase", "entering");
        verify(swap.level >= at - 0.05, "from where it was, not from nothing");
        rested(a);
        compare(switches, 1, "it never became another");
    }
    function test_aWantThatShowsTheSameTakesItsPlaceWithNothingMoving() {
        var a = thing("a"), again = thing("a"); load("a"); want = a; rested(a);
        var settled = settles;
        want = again;
        tryCompare(swap, "shown", again);
        compare(swap.level, 1); compare(swap.phase, "rest"); compare(switches, 1);
        compare(settles, settled, "nothing happened to settle from");
    }
    function test_theLastWantIsTheOneThatShows() {
        var a = thing("a"), b = thing("b"), c = thing("c"); load("a"); load("b"); load("c"); want = a; rested(a);
        want = b; tryCompare(swap, "phase", "leaving");
        want = c;                                           // before b was ever on show
        rested(c);
        compare(switches, 2, "a, then c: b never showed");
    }
    function test_goingOutForOneReplacedByOneNotReadyItComesBack() {
        var a = thing("a"), b = thing("b"), c = thing("c"); load("a"); load("b"); want = a; rested(a);
        want = b; tryVerify(function () { return swap.phase === "leaving" && swap.level < 0.9 });
        want = c;                                           // c's content isn't in
        tryVerify(function () { return swap.shown === a && swap.level === 1 && swap.phase === "waiting" }, 2000, "a is back, fully in, and waits");
        compare(switches, 1);
        load("c"); rested(c);
    }
    function test_nothingWantedGoesOutAtOnceAndComesStraightBack() {
        var a = thing("a"), b = thing("b"); load("a"); want = a; rested(a);
        var settled = settles;
        want = null;
        tryVerify(function () { return swap.level === 0 && swap.phase === "rest" });
        compare(swap.shown, a, "still what it shows, out of sight"); compare(settles, settled + 1); verify(!swap.busy);
        want = a;
        tryCompare(swap, "phase", "entering"); compare(switches, 1);
        rested(a);
        // and with another wanted while it is out, that one comes in when it is ready, with no going out first
        want = null; tryVerify(function () { return swap.level === 0 && swap.phase === "rest" });
        want = b; wait(100);
        compare(swap.level, 0, "nothing to bring back: it waits out of sight");
        load("b"); rested(b);
    }
    function test_comingInWhereNothingWasCanTakeItsOwnTime() {
        var a = thing("a"), b = thing("b"); load("a"); load("b");
        swap.appearMs = 400;
        want = a; tryCompare(swap, "phase", "entering");
        compare(swap.fadeIn.duration, 400, "from nothing");
        rested(a);
        want = b; tryVerify(function () { return swap.shown === b && swap.phase === "entering" });
        compare(swap.fadeIn.duration, 120, "after another");
        rested(b);
        swap.appearMs = Qt.binding(function () { return swap.inMs });
    }
    function test_withNoTimeToGoOutOrComeInOneTakesTheOthersPlaceAtOnce() {
        var a = thing("a"), b = thing("b"); load("a"); load("b");
        swap.outMs = 0; swap.inMs = 0; swap.appearMs = 200;
        want = a; tryCompare(swap, "phase", "entering");    // where nothing was, it still fades in
        rested(a);
        var low = 1, c = Qt.createQmlObject('import QtQuick 2.12; Connections { property real low: 1; onLevelChanged: low = Math.min(low, target.level) }', swap);
        c.target = swap;
        want = b;
        tryCompare(swap, "shown", b);
        compare(swap.level, 1); compare(swap.phase, "rest"); compare(c.low, 1, "never out of sight on the way");
        c.destroy();
        swap.outMs = 60; swap.inMs = 120; swap.appearMs = Qt.binding(function () { return swap.inMs });
    }
    function test_replacedWhileComingInIsACut() {
        var a = thing("a"), b = thing("b"); load("a"); load("b");
        want = a; tryCompare(swap, "phase", "entering");
        want = b;
        compare(cuts, 1);
        rested(b);
        want = a; rested(a);
        compare(cuts, 1, "one at rest replaced is no cut");
    }
    function test_aFadeTakesAsMuchOfItsTimeAsItHasFarToGo() {
        var a = thing("a"), b = thing("b"); load("a"); load("b"); want = a; rested(a);
        swap.outMs = 600; swap.inMs = 600;                  // (slow enough to catch it on its way)
        want = b; tryVerify(function () { return swap.phase === "leaving" && swap.level < 0.8 && swap.level > 0.3 });
        want = a;                                           // back in from most of the way in: a part of the time
        tryCompare(swap, "phase", "entering");
        verify(swap.fadeIn.duration < 600 * 0.75, "took " + swap.fadeIn.duration + " of 600 to come back from " + swap.level.toFixed(2));
        rested(a);
        swap.outMs = 60; swap.inMs = 120;
    }

    // ---- crossing: the new one comes in over the old
    property var over: null
    property var have: ({})
    property var broken: ({})
    Swap {
        id: cross
        cross: true; inMs: 100
        want: tc.over
        ready: !!coming && !!tc.have[coming]
        failed: !!coming && !!tc.broken[coming]
    }
    function test_crossingTheNewComesInOverTheOld() {
        have = ({ x: true, y: true });
        over = "x";
        tryCompare(cross, "shown", "x");
        over = "y";
        tryCompare(cross, "coming", "y"); compare(cross.shown, "x", "both there while it crosses");
        tryCompare(cross, "shown", "y"); compare(cross.coming, null); verify(!cross.busy);
        over = null; wait(150);
        compare(cross.shown, "y", "nothing wanted keeps what is shown");
    }
    function test_aCrossfadeThatStartedFinishes() {
        have = ({ x: true, y: true, z: true });
        over = "x"; tryCompare(cross, "shown", "x");
        over = "y"; tryCompare(cross, "phase", "entering");
        over = "z";
        tryCompare(cross, "shown", "y");                    // y's crossfade ends first
        tryCompare(cross, "shown", "z");                    // then the newest
    }
    function test_crossingItWaitsForTheContentAndLetsGoOfOneThatCantBeHad() {
        have = ({ x: true });
        over = "x"; tryCompare(cross, "shown", "x");
        over = "y"; wait(150);
        compare(cross.shown, "x"); compare(cross.coming, "y"); compare(cross.phase, "waiting");
        broken = ({ y: true });
        tryCompare(cross, "phase", "rest");
        compare(cross.shown, "x", "what is shown stays"); compare(cross.coming, null); verify(!cross.busy);
        wait(100); compare(cross.phase, "rest", "and it isn't asked for again by itself");
        have = ({ x: true, z: true }); over = "z";
        tryCompare(cross, "shown", "z");
    }
}
