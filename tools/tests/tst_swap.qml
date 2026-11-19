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
    function cleanup() {
        for (var i = 0; i < watchers.length; i++) watchers[i].destroy();
        watchers = [];
        swap.outMs = 60; swap.inMs = 120; swap.appearMs = Qt.binding(function () { return swap.inMs });
    }
    function rested(on) { tryVerify(function () { return swap.phase === "rest" && swap.shown === on && swap.level === 1 }, 2000, "at rest on " + (on ? on.name : on)) }
    // what the Swap went through from here on: the lowest `level`, each `phase`, how often `shown` was told of
    property var watchers: []
    function watch() {
        var w = Qt.createQmlObject('import QtQuick 2.12; Connections { property real low: 1; property var phases: []; property int shownTold: 0; '
                                   + 'onLevelChanged: low = Math.min(low, target.level); onPhaseChanged: phases.push(target.phase); onShownChanged: shownTold++ }', swap);
        w.low = swap.level; w.target = swap;
        watchers.push(w);
        return w;
    }

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
        swap.outMs = 600;                                   // (slow enough to catch it on its way)
        want = b; tryVerify(function () { return swap.phase === "leaving" && swap.level < 0.9 && swap.level > 0.2 });
        want = c;                                           // c's content isn't in
        tryVerify(function () { return swap.shown === a && swap.level === 1 && swap.phase === "waiting" }, 2000, "a is back, fully in, and waits");
        compare(switches, 1);
        load("c"); rested(c);
    }
    function test_oneThatHadOnlyBegunToGoOutNeverLeaves() {
        var a = thing("a"), b = thing("b"), c = thing("c"); load("a"); load("b"); want = a; rested(a);
        var seen = watch();
        want = b; swap.step();                              // it begins to go out for b: nothing has moved yet
        compare(swap.phase, "leaving"); compare(swap.level, 1);
        want = c; swap.step();                              // c's content isn't in
        compare(swap.phase, "waiting"); compare(swap.level, 1);
        wait(200);
        compare(seen.low, 1, "a stayed whole"); compare(swap.shown, a); compare(switches, 1);
        load("c"); rested(c);
    }
    function test_wantedAgainBeforeItHasMovedItStaysWholeAndSettlesOnce() {
        var a = thing("a"), b = thing("b"); load("a"); load("b"); want = a; rested(a);
        var seen = watch(), settled = settles;
        want = b; swap.step();                              // it begins to go out: nothing has moved yet
        compare(swap.phase, "leaving"); compare(swap.level, 1);
        want = a; swap.step();
        compare(swap.phase, "rest");
        wait(200);
        compare(seen.low, 1, "the fade that had begun was stopped");
        compare(swap.shown, a); compare(switches, 1); compare(settles, settled + 1, "settled, once");
    }
    function test_whatIsOnShowIsToldOfOnlyWhenItBecomesAnother() {
        var a = thing("a"), b = thing("b"); load("a");
        var seen = watch();
        want = a; rested(a);
        compare(seen.shownTold, 1);
        want = b; wait(100);                                // looked at while b's content is on its way
        load("b"); rested(b);                               // its content came, one fade went out, another came in and ended
        compare(seen.shownTold, 2, "once for each that came on show");
        want = b; swap.step(); swap.step(); wait(50);       // looked at again with nothing changed
        compare(seen.shownTold, 2);
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
        var seen = watch(), settled = settles;
        want = b;
        tryCompare(swap, "shown", b);
        compare(swap.level, 1); compare(swap.phase, "rest"); compare(seen.low, 1, "never out of sight on the way");
        compare(settles, settled + 1, "and it says it has settled, though nothing was animated");
        // replaced while it was still appearing: the other is there whole, and the fade that was running stops
        want = null; tryVerify(function () { return swap.level === 0 && swap.phase === "rest" });
        want = a; tryCompare(swap, "phase", "entering");
        want = b; swap.step();
        compare(swap.shown, b); compare(swap.level, 1); compare(swap.phase, "rest");
        wait(260);
        compare(swap.level, 1, "nothing went on fading under it");
    }
    function test_withNoTimeToComeInItIsThereAtTheSwitch() {
        var a = thing("a"), b = thing("b"); load("a"); load("b"); want = a; rested(a);
        swap.inMs = 0;
        var seen = watch();
        want = b; rested(b);
        compare(seen.phases.indexOf("entering"), -1, "no fade of no length to wait a frame for");
        compare(switches, 2);
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
