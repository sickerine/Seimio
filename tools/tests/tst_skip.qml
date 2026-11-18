// SkipTimes: where the intro and credits are. A file's chapters are where its songs really are; the
// sources time other cuts. Dragon Ball Z 1 ([Anime Time], 1453.5 s, chapters named "Chapter 1" to 4):
// AniSkip has an "op" at 2:06-3:36 and a "mixed-op" at 0:00-3:00, both for a cut 16 s longer, and the
// button used to show for what the two share, 2:06-3:00, a minute into the episode.
import QtQuick 2.12
import QtTest 1.2
import Seimio.Data 1.0

TestCase {
    name: "Skip"
    SkipTimes { id: skip }
    readonly property var dbzChapters: [{ start: 0, end: 110600, title: "Chapter 1" }, { start: 110600, end: 757700, title: "Chapter 2" },
                                        { start: 757700, end: 1354800, title: "Chapter 3" }, { start: 1354800, end: 1453400, title: "Chapter 4" }]
    readonly property var dbzAniSkip: [{ kind: "intro", from: 126015, to: 216015, source: "aniskip", episodeLength: 1469500 },
                                       { kind: "intro", from: 625, to: 180000, source: "aniskip", episodeLength: 1467584 },
                                       { kind: "outro", from: 1370000, to: 1468000, source: "aniskip", episodeLength: 1468611 },
                                       { kind: "outro", from: 1392962, to: 1467000, source: "aniskip", episodeLength: 1467559 }]
    function test_theChapterASourcePointsAt() {
        var r = skip.reconciled(dbzAniSkip, 1453500, dbzChapters);
        compare(r.intro.from, 0); compare(r.intro.to, 110600, "the first chapter, which the mixed-op covers");
        compare(r.outro.from, 1354800); compare(r.outro.to, 1453400, "the last chapter");
    }
    // Demon Slayer S3 10 (iAHD Blu-ray): the credits are the last 90 s of the chapter the second half is,
    // and the preview is the chapter after. Two sources agree on them; they aren't a chapter of their own.
    function test_creditsThatCloseAChapter() {
        var chapters = [{ start: 0, end: 43100, title: "Chapter 01" }, { start: 43100, end: 132000, title: "Chapter 02" }, { start: 132000, end: 686000, title: "Chapter 03" },
                        { start: 686000, end: 1381000, title: "Chapter 04" }, { start: 1381000, end: 1422000, title: "Chapter 05" }];
        var r = skip.reconciled([{ kind: "intro", from: 41000, to: 131100, source: "aniskip", episodeLength: 1420000 }, { kind: "intro", from: 41063, to: 131108, source: "introdb" },
                                 { kind: "outro", from: 1290067, to: 1380100, source: "introdb" }, { kind: "outro", from: 1290581, to: 1379963, source: "theintrodb" }], 1422000, chapters);
        compare(r.intro.from, 43100); compare(r.intro.to, 132000, "the intro is chapter 2");
        compare(r.outro.from, 1290067, "the credits start where the source says"); compare(r.outro.to, 1381000, "and end with the chapter");
    }
    function test_chaptersNothingPointsAt() {
        var r = skip.reconciled([{ kind: "intro", from: 300000, to: 390000, source: "aniskip" }], 1453500, dbzChapters);
        verify(!r.intro, "no chapter is that: nothing, rather than a guess");
    }
    function test_aNamedChapterIsIt() {
        var chapters = [{ start: 0, end: 60000, title: "Prologue" }, { start: 60000, end: 150000, title: "OP" }, { start: 150000, end: 1400000, title: "Episode" }];
        var r = skip.reconciled([{ kind: "intro", from: 0, to: 90000, source: "aniskip" }], 1400000, chapters);
        compare(r.intro.from, 60000); compare(r.intro.to, 150000);
    }
    // Reborn as a Space Mercenary 1 (SubsPlease, no chapters): nothing in AniSkip, and the two databases
    // keyed by IMDb episode agree on where its intro ends
    function test_twoSourcesThatAgree() {
        var r = skip.reconciled([{ kind: "intro", from: 66000, to: 155000, source: "introdb" }, { kind: "intro", from: 65999, to: 159799, source: "theintrodb" },
                                 { kind: "outro", from: 1325000, to: 1415000, source: "introdb" }], 1420109, []);
        compare(r.intro.from, 65999); compare(r.intro.to, 159799);
        compare(r.outro.from, 1325000);
    }
    function test_withoutChapters() {
        verify(!skip.reconciled(dbzAniSkip.slice(0, 2), 1453500, []).intro, "one source's two entries that disagree: nothing");
        var one = skip.reconciled([{ kind: "intro", from: 5000, to: 95000, source: "aniskip" }], 1400000, []);
        compare(one.intro.from, 5000, "a single entry stands");
        var two = skip.reconciled([{ kind: "intro", from: 5000, to: 95000, source: "aniskip" }, { kind: "intro", from: 3000, to: 93000, source: "introdb" }], 1400000, []);
        compare(two.intro.from, 3000); compare(two.intro.to, 95000, "two sources that agree on the end: the stretch either names");
    }
}
