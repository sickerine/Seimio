// The blur behind Glass and Frost: captures `sourceRect` of `source` at 1/4 size and blurs it with a
// separable Gaussian twice, at 1/4 then 1/8 size. A Gaussian leaves no gaps between taps, so thin bright
// lines (a progress bar, text) turn into a smooth glow instead of stacked copies, and two small passes
// blur wide for little cost. `output` is the blurred texture, `outputSize` its size.
//
// Capturing re-renders the source region every frame, so it runs only while `active`. A `frozen` chain
// captures once when it becomes active, refreshes every `busyInterval` ms while `sourceBusy` (the source
// is mid-change; a blur this wide hides a 20 Hz refresh, and every frame cost ~10 render passes on the
// TV), and takes one last capture when that settles, so a frozen blur is never stale. While
// `sourceMoving` (a crossfade a frost covers the whole screen with) it captures every frame: at 20 Hz a
// full-screen fade visibly stepped.
import QtQuick 2.12

Item {
    id: chain
    property Item source
    property rect sourceRect
    property bool active: true
    property bool frozen: false
    property bool sourceBusy: false
    property bool sourceMoving: false
    property bool hideSource: false      // keeps the source out of the scene while still capturing it
    property int busyInterval: 50
    readonly property alias output: v2.output
    readonly property size quarterSize: Qt.size(Math.max(1, Math.round(sourceRect.width / 4)), Math.max(1, Math.round(sourceRect.height / 4)))
    readonly property size outputSize: Qt.size(Math.max(1, Math.round(sourceRect.width / 8)), Math.max(1, Math.round(sourceRect.height / 8)))

    onActiveChanged: if (active && frozen) quarter.scheduleUpdate()
    onSourceBusyChanged: if (!sourceBusy && active && frozen) quarter.scheduleUpdate()

    ShaderEffectSource {
        id: quarter
        sourceItem: chain.source
        sourceRect: chain.sourceRect
        textureSize: chain.quarterSize
        live: chain.active && (!chain.frozen || chain.sourceMoving)
        hideSource: chain.hideSource; visible: false; smooth: true
    }
    Timer {
        running: chain.active && chain.frozen && chain.sourceBusy
        interval: chain.busyInterval; repeat: true; triggeredOnStart: true
        onTriggered: quarter.scheduleUpdate()
    }
    GaussPass { id: h1; input: quarter; inputSize: chain.quarterSize; live: chain.active }
    GaussPass { id: v1; input: h1.output; inputSize: chain.quarterSize; outputSize: chain.outputSize; vertical: true; live: chain.active }
    GaussPass { id: h2; input: v1.output; inputSize: chain.outputSize; step: 1.4; live: chain.active }
    GaussPass { id: v2; input: h2.output; inputSize: chain.outputSize; vertical: true; step: 1.4; live: chain.active }
}
