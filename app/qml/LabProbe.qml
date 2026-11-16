// Lab instrumentation, not part of the app. Every 3 s it posts frame pacing (stamped on the render
// thread) grouped by `phase`, key latency, and keys seen to the Mac's lab server. It reads switches
// from the server at launch ({ "captureAt": [ms...], "autopop": true }) and can capture the TV's
// screen through LG's capture service. { "openMenu": true } opens quick actions 2 s after launch, for
// testing the menu with the network remote, which can't long-press.
import QtQuick 2.12
import Seimio.Native 1.0

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

    Timer {
        running: true; interval: 3000; repeat: true
        onTriggered: {
            var out = { latency: lat.stats(), variant: probe.variant, luna: luna.log };
            luna.log = [];
            var fs = frames.take();
            for (var q in fs) out["rt " + q] = fs[q];
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
