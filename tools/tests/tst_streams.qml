// Streams reads release names as the patched Stremio app does. streams-fixture.json holds that app's
// answers (stremio-webos stream-filters.js and its badge code) for its test titles and its saved Torrentio
// lists, made once by running them through that code, except where the TV says otherwise: what plays was
// measured on the C5 (docs/playback.md), so Opus 7.1, FLAC 5.1 and Dolby Vision in AV1 are unsupported here.
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

    // anime with no Blu-ray: the most seeded, dub-only releases left out, unless a v2/REPACK of one of the
    // three most seeded exists; with a Blu-ray the AI judges (no pick here)
    function stream(release, seeders, res) {
        return { name: "[TB+] Torrentio\n" + res, title: release + "\n👤 " + seeders + " 💾 1 GB ⚙️ NyaaSi", url: "u" + seeders }
    }
    function pickOf(list) { return streams.ruledPick(JSON.stringify({ streams: list })).release || "" }
    function test_animeRule() {
        var x = new XMLHttpRequest();
        x.open("GET", Qt.resolvedUrl("cyberpunk-streams.json"), false); x.send();
        // the most seeded is VARYG's dual-audio, multi-subs batch (2702); ToonsHub's English dub prerelease
        // (1664) would be next, and is left out
        verify(streams.ruledPick(x.responseText).release.indexOf("H.264-VARYG") > 0, "Cyberpunk Edgerunners 2 E1: VARYG's batch");
        compare(pickOf([stream("[SubsPlease] Show - 01 (1080p) [AAC]", 900, "1080p"), stream("[SubsPlease] Show - 01v2 (1080p) [AAC]", 300, "1080p"), stream("[Erai-raws] Show - 01 [1080p]", 500, "1080p")]),
                "[SubsPlease] Show - 01v2 (1080p) [AAC]", "a v2 of the top release");
        compare(pickOf([stream("[ToonsHub] Show S01E01 1080p WEB-DL (English Dub)", 2000, "1080p"), stream("[Judas] Show - S01E01 [1080p][Multi-Subs]", 300, "1080p")]),
                "[Judas] Show - S01E01 [1080p][Multi-Subs]", "a dub alone is left out");
        compare(pickOf([stream("[SubsPlease] Show - 01 (1080p)", 900, "1080p"), stream("[Judas] Show 01 [BDRip 1080p]", 50, "1080p")]), "", "a Blu-ray: the AI judges");
        // no subtitle track: Kawaiika-Raws' raw and NoobSubs' hardsubbed MP4 were picks for Demon Slayer S1 E18
        compare(pickOf([stream("[SubsPlease] Show - 01 (1080p)", 900, "1080p"), stream("[Kawaiika-Raws] Show 01 [BDRip 1920x1080 HEVC FLAC]", 50, "1080p")]),
                "[SubsPlease] Show - 01 (1080p)", "a raw Blu-ray is left out");
        compare(pickOf([stream("[SubsPlease] Show - 01 (1080p)", 900, "1080p"), stream("[NoobSubs] Show (1080p Blu-ray 8bit AAC MP4)\n[NoobSubs] Show 01 (1080p Blu-ray 8bit AAC).mp4", 50, "1080p")]),
                "[SubsPlease] Show - 01 (1080p)", "a Blu-ray MP4 (burned-in subtitles) is left out");
    }
}
