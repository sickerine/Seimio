// Track choice follows mpv: languages match across ISO 639-1/639-2 and titles, an active choice becomes
// the group's default, and a fallback is never saved. The tracks are a real Blu-ray release's
// ([Salieri] Demon Slayer S3, as ffprobe lists them). Qt runs the tests in name order, so each keeps to
// its own group.
import QtQuick 2.12
import QtTest 1.2
import Seimio.Data 1.0

TestCase {
    name: "Tracks"
    Tracks { id: tracks; dataDir: "/tmp/seimio-tracks-test-" + Date.now() }
    readonly property var salieri: [
        { id: 0, type: "audio", lang: "eng", title: "ENG", default: true },
        { id: 1, type: "audio", lang: "jpn", title: "JPN" },
        { id: 0, type: "sub", lang: "eng", title: "Signs & Songs 01", default: true, forced: true },
        { id: 1, type: "sub", lang: "eng", title: "Dialogue 01" },
        { id: 2, type: "sub", lang: "eng", title: "Signs 02", playable: false },
        { id: 3, type: "sub", lang: "eng", title: "Dialogue 02", playable: false },
        { id: 4, type: "sub", lang: "eng", title: "S&S", forced: true },
        { id: 5, type: "sub", lang: "eng", title: "Dialog - ENG", default: true },
        { id: 6, type: "sub", lang: "eng", title: "[Tenrai-Sensei] No Honorifics" }
    ]
    function test_noChoiceKeepsTheFilesDefaults() {
        var c = tracks.choose(salieri, "fresh");
        compare(c.audio, 0);
        compare(c.sub, 0, "English audio: the forced signs and songs, as for a dub");
        tracks.prefer("japanese", "audio", "jpn", "");
        compare(tracks.choose(salieri, "japanese").sub, 5, "Japanese audio: the default full subtitles, not the forced ones");
    }
    function test_japaneseAudioCarriesOverHoweverItsTagged() {
        tracks.prefer("anime", "audio", "jpn", "JPN");
        compare(tracks.choose(salieri, "anime").audio, 1);
        compare(tracks.choose([{ id: 0, type: "audio", lang: "en" }, { id: 1, type: "audio", lang: "ja" }], "anime").audio, 1, "ja is jpn");
        compare(tracks.choose([{ id: 0, type: "audio", lang: "und", title: "English" }, { id: 1, type: "audio", lang: "", title: "Japanese (Original)" }], "anime").audio, 1, "from the title");
        compare(tracks.choose(salieri, "other").audio, 0, "other titles keep their own default");
    }
    function test_aFallbackIsNotSaved() {
        tracks.prefer("fallback", "audio", "jpn", "");
        compare(tracks.choose([{ id: 0, type: "audio", lang: "eng", default: true }], "fallback").audio, 0, "no Japanese: the file's default plays");
        compare(tracks.preferences("fallback").audio, "jpn", "and Japanese stays the choice");
    }
    // A show's default wins over its group's, list by list: what the show hasn't set comes from the group,
    // and another show (or a film, with no show) has only the group's.
    function test_aShowsDefaultOverTheGroups() {
        tracks.prefer("showGroup", "audio", "eng", "");
        tracks.prefer("showGroup", "sub", "off", "");
        tracks.prefer("series:tt9335498", "audio", "jpn", "");
        var c = tracks.choose(salieri, "showGroup", "tt9335498");
        compare(c.audio, 1, "the show's Japanese audio");
        compare(c.subsOff, true, "the group's subtitles: the show set none");
        compare(tracks.choose(salieri, "showGroup", "tt0000001").audio, 0, "another show: the group's English");
        compare(tracks.choose(salieri, "showGroup").audio, 0, "a film: the group's English");
        tracks.prefer("series:tt9335498", "audio", "", "");
        compare(tracks.choose(salieri, "showGroup", "tt9335498").audio, 0, "cleared: the group's again");
    }
    function test_subtitlesOffAndOn() {
        tracks.prefer("other", "sub", "off", "");
        var c = tracks.choose(salieri, "other");
        compare(c.sub, -1); verify(c.subsOff);
        tracks.prefer("other", "sub", "en", "");
        compare(tracks.choose([{ id: 0, type: "audio", lang: "jpn" }, { id: 0, type: "sub", lang: "fre" }, { id: 1, type: "sub", lang: "eng" }], "other").sub, 1);
    }
    // a release that flags its signs track default and not forced, and leaves the dialogue unflagged
    readonly property var badlyFlagged: [
        { id: 0, type: "audio", lang: "jpn", default: true },
        { id: 1, type: "audio", lang: "eng" },
        { id: 0, type: "sub", lang: "eng", title: "Signs & Songs", default: true },
        { id: 1, type: "sub", lang: "eng", title: "Full Subtitles" }
    ]
    function test_dialogueOverSignsWithForeignAudio() {
        tracks.prefer("signs", "sub", "eng", "");
        compare(tracks.choose(badlyFlagged, "signs").sub, 1, "Japanese audio: the dialogue, though signs is the default");
        tracks.prefer("signs", "audio", "eng", "");
        compare(tracks.choose(badlyFlagged, "signs").sub, 0, "English audio: the signs, as for a dub");
        compare(tracks.choose([{ id: 0, type: "audio", lang: "jpn" }, { id: 3, type: "sub", lang: "eng", title: "Signs" }], "signs").sub, 3, "signs only: better than nothing");
    }
    // OpenSubtitles addon tracks come after the file's, numbered from 1000, with no flags
    function test_addonSubtitlesPlayOnlyForTheChosenLanguage() {
        var file = [{ id: 0, type: "audio", lang: "eng", default: true }, { id: 3, type: "sub", lang: "eng" }];
        var addon = [{ id: 1000, type: "sub", lang: "pt-BR", external: true }, { id: 1001, type: "sub", lang: "eng", external: true }];
        compare(tracks.choose(file.concat(addon), "addon").sub, -1, "no choice: none plays");
        tracks.prefer("addon", "sub", "eng", "");
        compare(tracks.choose(file.concat(addon), "addon").sub, 3, "the file's own wins a tie");
        tracks.prefer("addon", "sub", "pt-BR", "");
        compare(tracks.choose(file.concat(addon), "addon").sub, 1000, "Brazilian Portuguese from the addon");
        compare(tracks.choose(file.concat([{ id: 1000, type: "sub", lang: "por" }]), "addon").sub, 1000, "a Portuguese choice takes Portuguese");
        // files often tag BCP 47 ("en-US"); the addon's plain "eng" is a closer match by mpv's score, but
        // loaded for you, it ranks after the file's own (mpv's auto_loaded)
        tracks.prefer("addon", "sub", "eng", "");
        compare(tracks.choose([{ id: 0, type: "audio", lang: "eng" }, { id: 3, type: "sub", lang: "en-US" }, { id: 1001, type: "sub", lang: "eng", external: true }], "addon").sub, 3, "the file's en-US over the addon's eng");
    }
    // mpv's compare_track: text before image subtitles (PGS, VobSub) when nothing else decides
    function test_textBeforeImageSubtitles() {
        tracks.prefer("image", "sub", "eng", "");
        compare(tracks.choose([{ id: 0, type: "audio", lang: "jpn" }, { id: 3, type: "sub", lang: "eng", codec: "S_HDMV/PGS" }, { id: 4, type: "sub", lang: "eng", codec: "S_TEXT/UTF8" }], "image").sub, 4);
    }
    // favourites: per list, in the order added, toggled off again, and cleared with every choice
    function test_favorites() {
        tracks.clearPreferences();
        compare(tracks.favorites("sub"), []);
        tracks.setFavorite("sub", "eng", true); tracks.setFavorite("sub", "jpn", true); tracks.setFavorite("sub", "eng", true);
        compare(tracks.favorites("sub"), ["jpn", "eng"], "added again goes last, once");
        compare(tracks.favorites("audio"), [], "audio keeps its own");
        tracks.setFavorite("sub", "jpn", false);
        compare(tracks.favorites("sub"), ["eng"]);
        compare(tracks.baseLanguage("pt-BR", ""), "por");
        tracks.clearPreferences();
        compare(tracks.favorites("sub"), []);
    }
    function test_unplayableTracksAreNeverChosen() {
        tracks.prefer("other", "audio", "eng", "");
        compare(tracks.choose([{ id: 0, type: "audio", lang: "eng", playable: false }, { id: 1, type: "audio", lang: "eng" }], "other").audio, 1);
    }
    function test_delayIsPerFile() {
        tracks.setDelay("a.mkv", 300);
        compare(tracks.delay("a.mkv"), 300); compare(tracks.delay("b.mkv"), 0);
    }

    // what a file's video header says the TV won't show (measured: docs/playback.md)
    function test_videoTrouble() {
        compare(tracks.videoTrouble("V_MPEG4/ISO/AVC", "016e0028"), "10-bit H.264", "avcC, profile 110");
        compare(tracks.videoTrouble("V_MPEG4/ISO/AVC", "01640028"), "", "High: fine");
        compare(tracks.videoTrouble("V_MPEGH/ISO/HEVC", "0102"), "", "Main 10: fine");
        compare(tracks.videoTrouble("V_MPEGH/ISO/HEVC", "0104"), "HEVC beyond 10-bit 4:2:0", "range extensions");
        compare(tracks.videoTrouble("V_AV1", "81"), "");
    }
}
