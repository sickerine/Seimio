// The hero backdrop, with a slow Ken Burns drift. `target` is its only input; the rest is internal
// state with fixed rules:
//   shown     the url fully visible now
//   incoming  the url being loaded or crossfaded in, "" when idle
// - A new target replaces an incoming one that hasn't started crossfading.
// - A target equal to `shown` cancels the incoming one.
// - A crossfade that has started always finishes; then the latest target is applied.
// - A failed load drops the incoming one and keeps what is shown.
// `busy` is true from a target change until the screen shows that target, so anything that
// captures the backdrop (frost) knows when its copy would be stale.
import QtQuick 2.12

Item {
    id: root
    property string target
    property size decodeSize: Qt.size(960, 540)
    property string shown: ""
    property string incoming: ""
    readonly property bool busy: target !== shown
    signal crossfadeStarted()

    property int front: 0                     // which layer is in front
    function img(i) { return i ? l1 : l0 }
    onTargetChanged: apply()

    function apply() {
        if (fade.running) return;              // finishes first, then calls apply() again
        if (!target || target === shown) { incoming = ""; return }
        incoming = target;
        var back = img(1 - front);
        if (back.url === target && back.status === Image.Ready) { startFade(); return }
        back.opacity = 0;
        back.url = target;                     // starts a load; loaded() continues from there
    }
    function loaded(i, ok) {
        if (i !== 1 - front || img(i).url !== incoming || fade.running) return;
        if (!ok) { incoming = ""; return }
        startFade();
    }
    function startFade() {
        var back = img(1 - front);
        back.z = 2; img(front).z = 1;
        fade.target = back;
        fade.restart();
        crossfadeStarted();
    }
    NumberAnimation {
        id: fade; property: "opacity"; from: 0; to: 1; duration: 700; easing.type: Easing.InOutQuad
        onFinished: {
            root.img(root.front).opacity = 0;   // the old front is fully covered now; stop drawing it
            root.front = 1 - root.front;
            root.shown = root.incoming;
            root.incoming = "";
            root.apply();
        }
    }
    Image {
        id: l0; property string url
        anchors.fill: parent; source: url; opacity: 0
        fillMode: Image.PreserveAspectCrop; asynchronous: true; sourceSize: root.decodeSize
        onStatusChanged: if (status === Image.Ready || status === Image.Error) root.loaded(0, status === Image.Ready)
    }
    Image {
        id: l1; property string url
        anchors.fill: parent; source: url; opacity: 0
        fillMode: Image.PreserveAspectCrop; asynchronous: true; sourceSize: root.decodeSize
        onStatusChanged: if (status === Image.Ready || status === Image.Error) root.loaded(1, status === Image.Ready)
    }
    SequentialAnimation on scale {
        loops: Animation.Infinite
        NumberAnimation { from: 1.0; to: 1.07; duration: 18000; easing.type: Easing.InOutSine }
        NumberAnimation { from: 1.07; to: 1.0; duration: 18000; easing.type: Easing.InOutSine }
    }
}
