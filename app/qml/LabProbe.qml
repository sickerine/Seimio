// Lab instrumentation, not part of the app. Every 3 s it posts frame pacing (stamped on the render
// thread) grouped by `phase`, key latency, and keys seen to the Mac's lab server. It reads switches
// from the server at launch ({ "captureAt": [ms...], "autopop": true }) and can capture the TV's
// screen through LG's capture service. { "openMenu": true } opens quick actions 2 s after launch, for
// testing the menu with the network remote, which can't long-press. { "timing": true } adds Qt's own
// per-frame render loop timing (GUI-thread sync vs render thread) to each report, along with stamped
// key presses, late frames and GUI-thread stalls; a string instead of true sets other Qt log rules
// (e.g. "qt.scenegraph.time.texture.debug=true"). { "bench": true } times card creation on the TV.
import QtQuick 2.12
import Seimio.Native 1.0
import Seimio.UI 1.0

Item {
    id: probe
    property var window
    property string server: "http://192.168.1.47:8091"
    property var variant: ({})
    property string phase: "idle"
    signal autopop()
    signal openMenu()

    // name what is animating now; it falls back to "idle" 900 ms after the last change
    function act(p) { phase = p; phaseReset.restart() }
    Timer { id: phaseReset; interval: 900; onTriggered: probe.phase = "idle" }

    KeyLatency { id: lat }
    FrameStats { id: frames; phase: probe.phase }
    LunaClient { id: luna; property var log: []; onResponse: log.push(payload.slice(0, 400)) }
    LogTap { id: tap }
    onVariantChanged: if (variant.timing) tap.start(probe.variant.timing === true ? "qt.scenegraph.time.renderloop.debug=true" : probe.variant.timing)

    // captures of the TV's screen at variant.captureAt ms after each call to captures()
    function capture(path) {
        var t = luna.call("luna://com.webos.service.capture/executeOneShot", JSON.stringify({ path: path, method: "DISPLAY", width: 1920, height: 1080, format: "PNG" }));
        if (t < 0) luna.log.push("capture failed " + luna.lastError());
    }
    property double captureStart: 0
    property int captureIndex: 0
    function captures() { if (variant.captureAt) { captureStart = Date.now(); captureIndex = 0; captureTimer.restart() } }
    Timer {
        id: captureTimer; interval: 10; repeat: true
        onTriggered: {
            var times = probe.variant.captureAt || [];
            if (probe.captureIndex >= times.length) { stop(); return }
            if (Date.now() - probe.captureStart >= times[probe.captureIndex]) { probe.capture("/media/developer/temp/cap" + times[probe.captureIndex] + ".png"); probe.captureIndex++ }
        }
    }
    Timer { running: !!probe.variant.autopop; interval: 2500; repeat: true; onTriggered: probe.autopop() }
    Timer { running: !!probe.variant.openMenu; interval: 2000; onTriggered: probe.openMenu() }

    // { "bench": true }: times creating cards and swapping a strip's model on the TV, 4 s after launch
    property var benchOut: null
    Item { id: benchHost; width: 1920; height: 400; y: 2000 }
    Component { id: benchCard; MediaCard { width: 384; height: 216; episode: "E3"; progress: 40; watched: true; title: "x" } }
    Component { id: benchPlain; MediaCard { width: 384; height: 216 } }
    Component { id: benchText; Text { text: "E3"; font.family: Theme.face; font.pixelSize: 18 } }
    Component { id: benchIcon; Icon { name: "check" } }
    Component { id: benchStrip; CardStrip { width: 1920; cardWidth: 384; cardHeight: 216; spacing: 32; showTitles: false } }
    function benchOne(c, n) { var t = Date.now(); for (var i = 0; i < n; i++) c.createObject(benchHost, { x: (i % 5) * 400 }); return (Date.now() - t) / n }
    Timer {
        running: !!probe.variant.bench; interval: 4000
        onTriggered: {
            var out = { card: probe.benchOne(benchCard, 40), plainCard: probe.benchOne(benchPlain, 40), text: probe.benchOne(benchText, 40), icon: probe.benchOne(benchIcon, 40) };
            var strip = benchStrip.createObject(benchHost);
            var eps = []; for (var i = 0; i < 24; i++) eps.push({ art: "", episode: "E" + i, progress: i === 3 ? 40 : -1, watched: i < 3 });
            var t = Date.now(); strip.model = eps; out.stripSwap = Date.now() - t;
            t = Date.now(); strip.model = eps.slice(); out.stripSwap2 = Date.now() - t;
            probe.benchOut = out;
            for (var k = benchHost.children.length - 1; k >= 0; k--) benchHost.children[k].destroy();
        }
    }

    Timer {
        running: true; interval: 3000; repeat: true
        onTriggered: {
            var out = { latency: lat.stats(), variant: probe.variant, luna: luna.log, bench: probe.benchOut };
            luna.log = [];
            var fs = frames.take();
            for (var q in fs) out["rt " + q] = fs[q];
            if (probe.variant.timing) out.log = tap.take().map(function (l) { return probe.phase + " | " + l }).slice(-600);
            var x = new XMLHttpRequest(); x.open("POST", probe.server + "/design"); x.send(JSON.stringify(out));
        }
    }
    Component.onCompleted: {
        lat.attach(window); frames.attach(window); luna.init("");
        var x = new XMLHttpRequest();
        x.open("GET", server + "/variant.json");
        x.onreadystatechange = function () { if (x.readyState === 4 && x.status === 200) { try { probe.variant = JSON.parse(x.responseText) } catch (e) {} } };
        x.send();
    }
}
