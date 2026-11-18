// Up next: the next episode, offered over the end of this one, at the bottom right. `mode`:
//   "credits"  the credits have started: Next episode ten seconds on, and Skip credits
//              (`canSkip`: something plays after them)
//   "end"      the file's last ten seconds: Next episode as this one ends
// The countdown is a sweep across the Next button, as far along as the player says (`elapsed`, 0 to 1: the
// video's own clock, so a pause holds it and a seek moves it); the player plays the next episode when it
// gets there. OK on Next plays
// it now, Skip credits jumps past them, Back closes the card. It owns the remote while it's up alone
// (`owns`); over the player's overlay it is one stop among others, and lets Up and Down through. It keeps
// showing what it showed while it fades out.
import QtQuick 2.12
import Seimio.UI 1.0
import "Episodes.js" as Episodes

FocusScope {
    id: up
    property bool open: false
    property string mode: "credits"
    property bool canSkip: true
    property var episode: null              // { thumb, episode, title }
    property string fallback                // the show's backdrop, for an episode without a still
    property real elapsed: 0                // 0 to 1 through the countdown
    property bool owns: true
    signal next()
    signal skipCredits()
    signal dismissed()

    Latch { id: shown; value: ({ mode: up.mode, canSkip: up.canSkip, episode: up.episode }); live: up.open }
    readonly property var s: shown.current || ({})
    // the sweep it shows: `elapsed` while it's up, gliding between the player's position reports, and where
    // it was all the way out (closing empties `elapsed` in the same breath as `open`: taken once both are in)
    property real sweep: 0
    Behavior on sweep { id: glide; NumberAnimation { duration: 300 } }
    function follow() { if (open) sweep = elapsed }
    onElapsedChanged: Qt.callLater(up.follow)
    onOpenChanged: if (open) { glide.enabled = false; sweep = elapsed; glide.enabled = true; buttons.currentIndex = 0 }

    width: 600; height: column.height + 40
    opacity: open ? 1 : 0; scale: open ? 1 : 0.92; transformOrigin: Item.BottomRight      // holds: `shown` latches what it offers
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
            episode: up.s.episode ? Episodes.chip(up.s.episode.episode) : ""
            caption: up.s.episode ? up.s.episode.title || "" : ""
            nextLabel: true; showTitle: false; radius: 18
        }
        // the buttons span the still, edge to edge: Next takes what Skip credits leaves, or all of it
        ButtonRow {
            id: buttons
            width: parent.width; stretch: 0
            focus: true
            model: (up.s.mode === "credits" && up.s.canSkip)
                ? [{ label: "Next episode", icon: "play", fill: up.sweep }, { label: "Skip credits" }]
                : [{ label: "Next episode", icon: "play", fill: up.sweep }]
            onTriggered: if (buttonIndex === 0) up.next(); else up.skipCredits()
        }
    }
    Keys.onPressed: {
        event.accepted = up.owns || (event.key !== Qt.Key_Up && event.key !== Qt.Key_Down);
        if (Remote.isBack(event.key)) up.dismissed();
    }
}
