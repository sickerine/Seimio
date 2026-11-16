// The page for a single title: a movie, or a show with one episode. Home's title info (HeroInfo) moves
// down to sit above these actions over the clear art, so the page is that info plus a row of actions
// anchored to the bottom left. open(item) resets it for a title.
import QtQuick 2.12
import Seimio.UI 1.0

FocusScope {
    id: page
    property bool active: false
    property var item: null
    signal play()
    readonly property real actionsY: 884        // the actions' top; the info sits 40 px above them
    width: Theme.screenWidth; height: Theme.screenHeight

    function open(title) { item = title; actions.currentIndex = 0 }
    opacity: active ? 1 : 0
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: page.active ? 200 : 260 } }

    Reveal {
        shown: page.active; delay: 160
        x: Theme.margin; y: page.actionsY
        ButtonRow {
            id: actions
            focus: true
            onTriggered: if (buttonIndex === 0) page.play()
            model: [
                { label: page.item && page.item.progress > 0 ? "Resume" : "Play", icon: "play", primary: true,
                  progress: page.item && page.item.progress > 0 ? page.item.progress : -1 },
                { label: "Add to library", icon: "plus", round: true },
                { label: "Mark watched", icon: "check", round: true }
            ]
        }
    }
}
