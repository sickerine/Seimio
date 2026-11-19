// PlayerScreen and the watch party: what plays is told to the party from the moment its link is in hand,
// and with someone in the room (and his setting on) the video, once loaded, stays where it starts until
// everyone there can play it.
import QtQuick 2.12
import QtTest 1.2
import Seimio.UI 1.0
import "../../app/qml"

Item {
    id: root
    width: 1920; height: 1080
    // Party, as far as the screen uses it
    QtObject {
        id: party
        property var viewers: []
        property bool waits: true
        readonly property bool loading: viewers.some(function (v) { return v.loading })
        property var told: []
        function playing(state) { told.push(state) }
        function stopped() { told.push(null) }
    }
    QtObject { id: streams; property string stage: ""; property var rows: []; property var picked: null; function cancel() {} }
    QtObject { id: tracks; function delay(key) { return 0 } function favorites(kind) { return [] } }
    PlayerScreen { id: screen; party: party; streams: streams; tracks: tracks; active: true; focus: true; useTee: false }

    TestCase {
        name: "WaitingForTheRoom"
        when: windowShown
        function last() { return party.told[party.told.length - 1] }
        function begin(room, waits) {
            party.viewers = room; party.waits = waits !== false; party.told = [];
            screen.prepare({ name: "A film", id: "tt1" }, "");
            screen.start("https://cdn.example/a.mkv", { url: "https://cdn.example/a.mkv" }, 0.5);
        }
        function cleanup() { screen.stop() }

        function test_waitsUntilEveryoneCanPlayIt() {
            begin([{ id: 1, loading: false }, { id: 2, loading: false }]);
            verify(screen.waiting);
            verify(!screen.playing, "loaded, and held");
            // the party heard at once, with where it will start: its friends load it while the TV waits
            compare(last().media, "https://cdn.example/a.mkv");
            compare(last().paused, true);
            compare(Math.round(last().position), 711023, "half way through the 23:42 it is");
            compare(screen.status, "Waiting for the room");
            party.viewers = [{ id: 1, loading: true }, { id: 2, loading: true }];       // they say they are loading it
            wait(1700);
            verify(!screen.playing, "still held, past the moment a room that said nothing is believed");
            party.viewers = [{ id: 1, loading: false }, { id: 2, loading: true }];
            wait(100);
            verify(!screen.playing, "one of two is not the room");
            party.viewers = [{ id: 1, loading: false }, { id: 2, loading: false }];
            tryVerify(function () { return screen.playing }, 1000, "and starts when the last of them is in");
            verify(!screen.waiting);
            compare(last().paused, false);
        }
        // a friend's player says it is loading a moment after it hears what plays: a room that looks ready
        // in that moment is not taken at its word
        function test_aRoomThatHasNotSpokenYetIsGivenAMoment() {
            begin([{ id: 1, loading: false }]);
            wait(600);
            verify(!screen.playing, "not at once");
            tryVerify(function () { return screen.playing }, 2000, "but a second and a half on, with nobody loading");
        }
        function test_okStartsItWhoeverIsStillLoading() {
            begin([{ id: 1, loading: true }]);
            wait(100);
            verify(screen.waiting && !screen.playing);
            keyClick(Qt.Key_Return);
            verify(screen.playing);
            verify(!screen.waiting);
        }
        function test_startsAtOnceWithNobodyThereOrHisSettingOff() {
            begin([]);
            verify(!screen.waiting && screen.playing, "an empty room");
            screen.stop();
            begin([{ id: 1, loading: true }], false);
            verify(!screen.waiting && screen.playing, "switched off");
            compare(last().media, "https://cdn.example/a.mkv", "and the party is told all the same");
        }
        function test_theRoomLeavingStartsIt() {
            begin([{ id: 1, loading: true }]);
            wait(1600);
            verify(!screen.playing);
            party.viewers = [];
            tryVerify(function () { return screen.playing }, 1000);
        }
        function test_stoppingSaysSo() {
            begin([]);
            screen.stop();
            compare(last(), null);
        }
        // the screen's player (the Mac's stand-in), to make it do what the TV's does by itself
        function player() { for (var i = 0; i < screen.resources.length; i++) if (screen.resources[i].windowId !== undefined && screen.resources[i].land) return screen.resources[i]; return null }
        function seekTo(ms) { screen.seekTarget = ms; screen.seekNow() }
        function told(what) { var s = last(); return s === null ? "nothing plays" : Math.round(s.position / 1000) + " s " + (s.paused ? "held" : s.buffering ? "loading" : "moving") }
        // What the room is told in each state the player can be in. The friends' players go by it: told
        // "moving" at a place the picture has not reached, they run ahead of it and are pulled back, which
        // is the same stretch played twice ("it was looping for him as I kept seeking").
        function test_whatTheRoomIsToldStateByState() {
            var media = player();
            begin([]);
            compare(told(), "711 s moving", "playing, from where it resumed");
            screen.togglePause();
            compare(told(), "711 s held", "paused");
            screen.togglePause();
            compare(told(), "711 s moving", "and on");
            seekTo(900000);
            compare(told(), "900 s loading", "sought: at the place asked for, and not moving yet");
            media.land(897500);
            compare(told(), "898 s moving", "landed, on the keyframe before it: from there");
            seekTo(1000000); seekTo(1100000);
            compare(told(), "1100 s loading", "sought again before the first had landed: still loading, at the newest");
            media.land(1098000);
            compare(told(), "1098 s moving");
            media.stall(true);
            compare(told(), "1098 s loading", "the stream ran dry");
            media.stall(false);
            compare(told(), "1098 s moving");
            screen.togglePause(); seekTo(300000);
            compare(told(), "300 s held", "sought while paused: held at the place asked for");
            media.land(298000);
            compare(told(), "298 s held", "and at where it landed");
            screen.togglePause();
            compare(told(), "298 s moving");
            media.end();
            compare(told(), "298 s held", "played to its end: not moving any more");
            media.fail("gone");
            compare(told(), "nothing plays", "a stream that can't be played is not in the room");
        }
        // sought while it waits for the room: the room is told the place he chose, and it starts there
        function test_soughtWhileWaiting() {
            begin([{ id: 1, loading: true }]);
            wait(50);
            compare(told(), "711 s held", "waiting, at where it will start");
            seekTo(60000); player().land(58000);
            compare(told(), "58 s held", "and at the place he sought to instead");
            keyClick(Qt.Key_Return);
            verify(screen.playing && !screen.waiting);
        }
        function test_hisSwitchTurnedOffWhileItWaitsStartsIt() {
            begin([{ id: 1, loading: true }]);
            wait(50);
            verify(screen.waiting && !screen.playing);
            party.waits = false;
            verify(screen.playing && !screen.waiting);
        }
        // another stream in the same player: the room hears that the first is over, then of the second
        // from its own start, with nothing of the first's place in it
        function test_anotherStreamStartsOver() {
            begin([]);
            seekTo(1200000); player().land(1200000);
            compare(told(), "1200 s moving");
            party.told = [];
            screen.prepare({ name: "Another", id: "tt2" }, "");
            compare(last(), null, "the first is over");
            screen.start("https://cdn.example/b.mkv", { url: "https://cdn.example/b.mkv" }, 0);
            compare(last().media, "https://cdn.example/b.mkv");
            verify(party.told.every(function (s) { return s === null || s.media !== "https://cdn.example/b.mkv" || s.position < 1000000 }), "never at the first one's place");
        }
    }
}
