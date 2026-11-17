// Up next: the next episode, offered over the end of this one, at the bottom right. `mode`:
//   "credits"  the credits have started: Next episode, counting down `seconds`, and Skip credits
//              (`canSkip`: something plays after them)
//   "end"      the file's last seconds: Next episode, counting down the time that's left
// The countdown is a sweep across the Next button; when it reaches the end the next episode plays. OK on Next plays
// it now, Skip credits jumps past them, Back closes the card. It owns the remote while it's up, and keeps
// showing what it showed while it fades out.
import QtQuick 2.12
import Seimio.UI 1.0

FocusScope {
    id: up
    property bool open: false
    property string mode: "credits"
    property bool canSkip: true
    property var episode: null              // { thumb, episode, title }
    property string fallback                // the show's backdrop, for an episode without a still
    property real seconds: 10               // read when it opens
    property bool paused: false             // the countdown waits while the video is paused
    signal next()
    signal skipCredits()
    signal dismissed()

    Latch { id: shown; value: ({ mode: up.mode, canSkip: up.canSkip, episode: up.episode }); live: up.open }
    readonly property var s: shown.current || ({})
    property real elapsed: 0                // 0 to 1 through the countdown
    NumberAnimation on elapsed { id: count; running: false; paused: up.paused && running; from: 0; to: 1; onFinished: if (up.open) up.next() }
    onOpenChanged: { if (open) { elapsed = 0; count.duration = up.seconds * 1000; count.restart(); buttons.currentIndex = 0 } else count.stop() }

    width: 600; height: column.height + 40
    opacity: open ? 1 : 0; scale: open ? 1 : 0.92; transformOrigin: Item.BottomRight
    visible: opacity > 0.01
    Behavior on opacity { NumberAnimation { duration: 220 } }
    Behavior on scale { NumberAnimation { duration: 360; easing.type: Theme.spring; easing.overshoot: 1.3 } }

    Rectangle { anchors.fill: parent; radius: 32; color: "#f0141418"; border.width: 1; border.color: "#26ffffff" }
    Column {
        id: column
        x: 20; y: 20; width: parent.width - 40
        spacing: 20
        MediaCard {
            width: parent.width; height: Math.round(width * 9 / 16)
            art: up.s.episode ? up.s.episode.thumb || "" : ""
            fallback: up.fallback
            episode: up.s.episode ? "E" + up.s.episode.episode : ""
            caption: up.s.episode ? up.s.episode.title || "" : ""
            nextLabel: true; showTitle: false; radius: 18
        }
        // the buttons span the still, edge to edge: Next takes what Skip credits leaves, or all of it
        ButtonRow {
            id: buttons
            width: parent.width; stretch: 0
            focus: true
            model: (up.s.mode === "credits" && up.s.canSkip)
                ? [{ label: "Next episode", icon: "play", fill: up.elapsed }, { label: "Skip credits" }]
                : [{ label: "Next episode", icon: "play", fill: up.elapsed }]
            onTriggered: if (buttonIndex === 0) up.next(); else up.skipCredits()
        }
    }
    Keys.onPressed: {
        event.accepted = true;
        if (Remote.isBack(event.key)) up.dismissed();
    }
}
