// Where an episode list rests (Episodes.resting): the first episode of a fresh show, the unfinished
// one you were in, the one after a finished one (once it has aired).
import QtQuick 2.12
import QtTest 1.2
import "../../app/qml/Episodes.js" as Episodes

TestCase {
    name: "Episodes"
    function ep(id, watched, progress, released) { return { id: id, watched: watched, progress: progress || 0, released: released || "2026-01-01" } }
    function show(current, seasons) { return { current: current, seasons: seasons } }
    readonly property string today: "2026-11-17"

    function test_freshShowStartsAtTheFirstNumberedSeason() {
        var sh = show("", [{ season: 0, episodes: [ep("sp1", false)] }, { season: 1, episodes: [ep("a1", false), ep("a2", false)] }]);
        compare(Episodes.resting(sh, today), { s: 1, e: 0 });
    }
    function test_unfinishedCurrentIsWhereYouAre() {
        // watched before and being rewatched: the progress wins
        var sh = show("a2", [{ season: 1, episodes: [ep("a1", true), ep("a2", true, 71.4), ep("a3", false)] }]);
        compare(Episodes.resting(sh, today), { s: 0, e: 1 });
    }
    function test_finishedCurrentMovesToTheNextAcrossSeasons() {
        var sh = show("a2", [{ season: 1, episodes: [ep("a1", true), ep("a2", true)] }, { season: 2, episodes: [ep("b1", false)] }]);
        compare(Episodes.resting(sh, today), { s: 1, e: 0 });
    }
    function test_finishedLastAiredStaysWhenTheNextHasNotAired() {
        var sh = show("a2", [{ season: 1, episodes: [ep("a1", true), ep("a2", true), ep("a3", false, 0, "2026-11-20")] }]);
        compare(Episodes.resting(sh, today), { s: 0, e: 1 });
    }
    function test_currentNotYetAiredFallsBackToTheLastAired() {
        var sh = show("a3", [{ season: 1, episodes: [ep("a1", true), ep("a2", true), ep("a3", false, 0, "2026-11-22")] }]);
        compare(Episodes.resting(sh, today), { s: 0, e: 1 });
    }
    function test_currentStremioMovedOnToIsWhereYouAre() {
        var sh = show("a3", [{ season: 1, episodes: [ep("a1", true), ep("a2", true), ep("a3", false), ep("a4", false)] }]);
        compare(Episodes.resting(sh, today), { s: 0, e: 2 });
    }
    function test_withoutCurrentTheLastWatchedAnchors() {
        var sh = show("", [{ season: 1, episodes: [ep("a1", true), ep("a2", true), ep("a3", false)] }]);
        compare(Episodes.resting(sh, today), { s: 0, e: 2 });
    }
    function test_nextEpisodeCrossesSeasonsAndWaitsForAiring() {
        var sh = show("", [{ season: 1, episodes: [ep("a1", true), ep("a2", false)] }, { season: 2, episodes: [ep("b1", false), ep("b2", false, 0, "2026-11-22")] }]);
        compare(Episodes.after(sh, "a1", today).id, "a2");
        compare(Episodes.after(sh, "a2", today).id, "b1", "the last of a season goes on to the next season");
        compare(Episodes.after(sh, "b1", today), null, "the next one hasn't aired");
        compare(Episodes.after(sh, "b2", today), null, "the last one has nothing after it");
    }
    function test_findsAnEpisode() {
        var sh = show("", [{ season: 1, episodes: [ep("a1", false)] }, { season: 2, episodes: [ep("b1", false), ep("b2", false)] }]);
        compare(Episodes.find(sh, "b2"), { s: 1, e: 1 });
        compare(Episodes.find(sh, "zz"), null);
    }
}
