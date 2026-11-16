// A horizontal row of MediaCards walked with Left/Right. The focused card always sits at the left
// `inset` and the row slides under it. It's a ListView, so only cards near the screen exist: a row of
// 96 episodes creates about six cards, not 96. OK comes out as `activated` (tap) or `held` (long
// press) with the index. Up, Down and Back pass on to the parent.
//
// `model` is a JS array of card data: { art, title, episode, progress, watched, upcoming }.
import QtQuick 2.12

FocusScope {
    id: strip
    property var model: []
    property int cardWidth: 220
    property int cardHeight: 330
    property int spacing: 36
    property real cardRadius: 16
    property int inset: Theme.margin
    property bool showTitles: true
    property bool nextLabels: true       // Home's Continue Watching marks unstarted next episodes "Next"
    property alias currentIndex: list.currentIndex
    readonly property int count: list.count
    property int moveDir: 1
    signal activated(int cardIndex)
    signal held(int cardIndex)
    height: cardHeight + (showTitles ? 70 : 0)

    // jump without animating (a new model, or restoring a position)
    function jumpTo(i) { slide.stop(); list.currentIndex = i; list.contentX = targetX(i) }
    function targetX(i) { return i * (cardWidth + spacing) - inset }

    ListView {
        id: list
        anchors.fill: parent
        orientation: ListView.Horizontal
        spacing: strip.spacing
        model: strip.model
        interactive: false
        leftMargin: strip.inset
        // the row moves by our own animation, so the easing matches everything else
        highlightFollowsCurrentItem: false
        highlightRangeMode: ListView.NoHighlightRange
        cacheBuffer: strip.cardWidth * 2
        onCurrentIndexChanged: { slide.stop(); slide.to = strip.targetX(currentIndex); slide.start() }
        onModelChanged: strip.jumpTo(0)
        delegate: MediaCard {
            width: strip.cardWidth; height: strip.cardHeight; radius: strip.cardRadius
            art: modelData.art || ""
            title: modelData.title || ""
            episode: modelData.episode || ""
            progress: modelData.progress === undefined ? -1 : modelData.progress
            watched: !!modelData.watched
            upcoming: modelData.upcoming || ""
            showTitle: strip.showTitles
            nextLabel: strip.nextLabels
            focused: ListView.isCurrentItem && strip.activeFocus
            moveDir: strip.moveDir
        }
    }
    NumberAnimation { id: slide; target: list; property: "contentX"; duration: 400; easing.type: Theme.ease }

    OkPress { id: ok; onTapped: strip.activated(strip.currentIndex); onHeld: strip.held(strip.currentIndex) }
    Keys.onLeftPressed: if (currentIndex > 0) { moveDir = -1; currentIndex-- }
    Keys.onRightPressed: if (currentIndex < count - 1) { moveDir = 1; currentIndex++ }
    Keys.onPressed: if (Remote.isOk(event.key)) { event.accepted = true; ok.press(event) }
    Keys.onReleased: if (Remote.isOk(event.key)) { event.accepted = true; ok.release(event) }
}
