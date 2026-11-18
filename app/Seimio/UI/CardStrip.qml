// A horizontal row of MediaCards walked with Left/Right. The focused card always sits at the left
// `inset` and the row slides under it. OK comes out as `activated` (tap) or `held` (long press) with
// the index. Up, Down and Back pass on to the parent, and so do Left at the first card and Right at the
// last, so a screen can go on past the ends.
//
// The row keeps a fixed set of cards, just enough to cover its width while sliding, and hands them
// new data as it moves: card slot k shows whichever index in the visible window leaves remainder k
// when divided by the number of slots. Moving along the row, or swapping in a new model, never creates
// or destroys a card, so it costs no item creation and no new scene graph nodes on the TV. A row whose
// cards change size (a show's episodes are stills, its films posters) says how narrow they get
// (`narrowest`), and the set is made for that: sized by the width of the moment, every card was destroyed
// and made again at each change (22-26 ms on the TV).
//
// `model` is a JS array of card data: { art, fallback, title, caption, label, episode, progress, watched,
// upcoming }, and for a title's card its `id` (and `kitsu`), which `marks` goes by.
// With `slides` off the row stays put and the focus moves along it (a row of a grid that fits the screen).
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
    property int currentIndex: 0
    readonly property int count: model.length
    // whether the current card is drawn focused; a screen can keep it on while a menu over the row
    // has the remote
    property bool showFocus: activeFocus
    property int moveDir: 1
    property bool slides: true
    // ids of titles that are watched (each true): a card of a title wears its check by its id (`kitsu` for
    // an anime known by another id), where an episode's card carries `watched` itself
    property var marks: ({})
    signal activated(int cardIndex)
    signal held(int cardIndex)
    height: cardHeight + (showTitles ? 70 : 0)

    readonly property int stride: cardWidth + spacing
    // how far the row has slid: card i sits at inset + i * stride - scroll
    property real scroll: 0
    // the card left of the inset is partly on screen, and a slide shows one more at the far end
    readonly property int slots: Math.ceil((width + stride) / stride) + 1
    property int narrowest: cardWidth
    readonly property int pool: Math.ceil((width + narrowest + spacing) / (narrowest + spacing)) + 1
    readonly property int first: Math.max(0, Math.floor((scroll - inset) / stride))

    // where the focused card rests, in the window: for a menu beside it
    function focusRect() { var p = mapToItem(null, inset + (slides ? 0 : currentIndex * stride), 0); return Qt.rect(p.x, p.y, cardWidth, cardHeight) }
    // move without animating (a new model, or restoring a position)
    function jumpTo(i) { currentIndex = i; slide.stop(); scroll = slides ? i * stride : 0 }
    onCurrentIndexChanged: if (slides) { slide.to = currentIndex * stride; slide.restart() }
    onCountChanged: if (currentIndex >= count) jumpTo(Math.max(0, count - 1))
    onStrideChanged: jumpTo(currentIndex)
    NumberAnimation { id: slide; target: strip; property: "scroll"; duration: 400; easing.type: Theme.ease }

    Repeater {
        model: strip.width > 0 ? strip.pool : 0
        MediaCard {
            // cards past the slots wider cards need have nothing to show
            readonly property int idx: index < strip.slots ? strip.first + ((index - strip.first) % strip.slots + strip.slots) % strip.slots : -1
            readonly property var d: idx >= 0 && idx < strip.count ? strip.model[idx] : null
            // a card fully off screen isn't drawn: a sliding row keeps a card each side of what shows
            visible: d !== null && x < strip.width && x + width > 0
            x: strip.inset + idx * strip.stride - strip.scroll
            width: strip.cardWidth; height: strip.cardHeight; radius: strip.cardRadius
            art: d && d.art || ""
            fallback: d && d.fallback || ""
            title: d && d.title || ""
            episode: d && d.episode || ""
            progress: d && d.progress !== undefined ? d.progress : -1
            watched: !!(d && (d.watched || strip.marks[d.kitsu || d.id]))
            upcoming: d && d.upcoming || ""
            caption: d && d.caption || ""
            label: d && d.label || ""
            showTitle: strip.showTitles
            nextLabel: strip.nextLabels
            focused: idx === strip.currentIndex && strip.showFocus
            moveDir: strip.moveDir
        }
    }

    OkPress { id: ok; onTapped: strip.activated(strip.currentIndex); onHeld: strip.held(strip.currentIndex) }
    Keys.forwardTo: [ok]
    Keys.onLeftPressed: if (currentIndex > 0) { moveDir = -1; currentIndex-- } else event.accepted = false
    Keys.onRightPressed: if (currentIndex < count - 1) { moveDir = 1; currentIndex++ } else event.accepted = false
}
