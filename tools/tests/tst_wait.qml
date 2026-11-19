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
    }
}
