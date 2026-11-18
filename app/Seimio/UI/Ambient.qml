// A motion that never ends and that nobody started: the backdrop's drift, the light going round today's
// day. It turns a ShaderEffect's uniform from 0 to 1 every `period` ms, and the shader makes the motion
// of that.
//
// At rest (Remote.resting) it runs on the render thread, so it goes on while the GUI thread builds a page
// ahead or the JavaScript engine collects its garbage: on the GUI thread each of those held it up 30 ms,
// a late frame. While things move it runs on the GUI thread with them: an animation on the render thread
// makes the render loop run by itself, and the GUI thread then gets its turn every other frame much of
// the time (a stream of 33 ms ticks on the TV, which frame times don't show: every frame is on time,
// half of them with nothing new in them). It goes from one thread to the other where it is. Previews
// hold it at its start (Theme.still).
import QtQuick 2.12

QtObject {
    id: ambient
    property Item effect                // the ShaderEffect; `uniform` is a property of it too
    property string uniform
    property int period: 1000
    property bool running: true         // stopped, it holds where it is
    readonly property int wanted: !running || !effect || Theme.still ? 0 : Remote.resting ? 2 : 1      // 0 stopped, 1 the GUI thread, 2 the render thread
    property int driven: 0
    // on the render thread the property isn't written, so where it is comes from when it started and where
    property real from: 0
    property double since: 0
    onWantedChanged: drive()
    onEffectChanged: { stop(); drive() }                // another effect starts from its own place
    Component.onCompleted: drive()
    function stop() { gui.stop(); render.stop(); driven = 0 }
    function drive() {
        if (wanted === driven) return;
        var at = driven === 2 ? (from + (Date.now() - since) / period) % 1 : effect ? effect[uniform] % 1 : 0;
        stop();
        if (!effect) return;
        effect[uniform] = Theme.still ? 0 : at;
        driven = wanted;
        if (driven === 1) { gui.from = at; gui.to = at + 1; gui.start() }
        else if (driven === 2) { from = at; since = Date.now(); render.from = at; render.to = at + 1; render.start() }
    }
    property NumberAnimation gui: NumberAnimation { target: ambient.effect; property: ambient.uniform; duration: ambient.period; loops: Animation.Infinite }
    property UniformAnimator render: UniformAnimator { target: ambient.effect; uniform: ambient.uniform; duration: ambient.period; loops: Animation.Infinite }
}
