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
    function test_kitsuUnknownDateIsNotAired() {
        var sh = show("a1", [{ season: 1, episodes: [ep("a1", true), ep("a2", false, 0, "1970-01-01")] }]);
        compare(Episodes.after(sh, "a1", today), null, "1970-01-01 is Kitsu's unknown date");
        compare(Episodes.resting(sh, today), { s: 0, e: 0 });
    }
    function test_nextEpisodeStopsBeforeSpecials() {
        var sh = show("", [{ season: 1, episodes: [ep("a1", true), ep("a2", false)] }, { season: 0, episodes: [ep("film", false)] }]);
        compare(Episodes.after(sh, "a2", today), null);
    }
    function test_findsAnEpisode() {
        var sh = show("", [{ season: 1, episodes: [ep("a1", false)] }, { season: 2, episodes: [ep("b1", false), ep("b2", false)] }]);
        compare(Episodes.find(sh, "b2"), { s: 1, e: 1 });
        compare(Episodes.find(sh, "zz"), null);
    }

    // the up-next countdown is the video's clock between two positions, not a stopwatch started when the
    // card opened: seeking to three seconds from the end leaves three seconds
    function test_upNextFollowsThePosition() {
        var d = 1420000, outro = { start: 1325000, end: 1415000 };
        var end = Episodes.upNextSpan("end", d - 3000, d, outro);
        compare(end.until - (d - 3000), 3000, "three seconds from the end: three seconds left");
        fuzzyCompare(Episodes.upNextElapsed(end, d - 3000), 0.7, 0.001);
        var credits = Episodes.upNextSpan("credits", outro.start, d, outro);
        compare(credits.until, outro.start + 10000, "ten seconds into the credits");
        compare(Episodes.upNextElapsed(credits, outro.start + 5000), 0.5);
        compare(Episodes.upNextElapsed(credits, outro.start + 5000), Episodes.upNextElapsed(credits, outro.start + 5000), "paused: it stays");
        var sought = Episodes.upNextSpan("credits", outro.start + 60000, d, outro);
        compare(sought.from, outro.start + 60000, "offered by a seek into the credits: ten seconds from there, not at once");
        compare(Episodes.upNextSpan("credits", outro.end - 4000, d, outro).until, outro.end, "never past the credits' end");
    }
}
