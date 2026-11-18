// Card art that has been shown stays decoded. Qt keeps only ~2 MB of images nothing shows, so a card that
// a row hands other data lets its art go, and on the way back the art was decoded again: the card came
// back empty and faded in (the Anime tab's rows, then Continue Watching once it grew past its cards).
//
// Every MediaCard's art is held here by a hidden image decoded as the card decodes it (the same size and
// crop, so the two share one decode): the most recent `budget` bytes of it. A screen can also hold a whole
// view's art ahead (`keep`), so its cards don't load on the way in either. The holders are made once.
//
// `reloads` counts art that had to load although it was held ready: the holder and the card no longer
// decode alike (another size or crop). Tours and tests fail on it.
pragma Singleton
import QtQuick 2.12
import QtQml 2.12

QtObject {
    id: art
    readonly property int slots: 224
    readonly property int budget: 72 * 1024 * 1024      // bytes of decoded art, at 4 a pixel
    property int held: 0                                // bytes held now
    property int reloads: 0
    property int loads: 0                               // times a card had to wait for its art (lab: a walk back adds none)

    // never reassigned, so nothing re-evaluates on a change: "url|w|h" -> holder, and per holder its key,
    // its bytes and when it was last asked for
    property var at: ({})
    property var keys: []
    property var bytes: []
    property var stamp: []
    property int clock: 0

    function key(url, w, h) { return url + "|" + w + "|" + h }
    // a card shows `url` decoded at w x h (its Image's own sourceSize)
    function hold(url, w, h) {
        url = "" + url;
        if (!url || w <= 0 || h <= 0) return;
        var k = key(url, w, h), i = at[k];
        if (i !== undefined) { stamp[i] = ++clock; return }
        i = oldest(true);
        take(i, k, url, w, h);
        while (held > budget) drop(oldest(false));
    }
    // whether `url` is held and decoded: a card that still has to load it decodes otherwise than the holder
    function ready(url, w, h) {
        var i = at[key("" + url, w, h)];
        return i !== undefined && holders.objectAt(i).status === Image.Ready;
    }
    // the holder least recently asked for; with `free`, an empty one if there is one
    function oldest(free) {
        var best = -1;
        for (var i = 0; i < slots; i++) {
            if (!keys[i]) { if (free) return i; continue }
            if (best < 0 || stamp[i] < stamp[best]) best = i;
        }
        return best;
    }
    function drop(i) {
        if (i < 0 || !keys[i]) return;
        delete at[keys[i]]; held -= bytes[i]; keys[i] = ""; bytes[i] = 0;
        holders.objectAt(i).source = "";
    }
    function take(i, k, url, w, h) {
        drop(i);
        var image = holders.objectAt(i);
        at[k] = i; keys[i] = k; bytes[i] = w * h * 4; stamp[i] = ++clock; held += bytes[i];
        image.slot = i; image.sourceSize = Qt.size(w, h); image.source = url;      // last: cached art is Ready inside the assignment
    }
    // decoded: the budget counts the picture as it came out, which is not always the size asked for (how
    // a crop is decoded differs between Qt versions)
    function sized(i, w, h) {
        if (!keys[i]) return;
        held += w * h * 4 - bytes[i]; bytes[i] = w * h * 4;
        while (held > budget) { var o = oldest(false); if (o === i || o < 0) break; drop(o) }
    }

    // A view's art, held ahead: `urls` in the order the view shows them, each decoded at w x h. They are
    // taken a few a frame (a holder's two assignments cost ~0.3 ms on the TV, and a view has a hundred),
    // last first, so the top of the view is what stays longest.
    property var queue: []
    function keep(urls, w, h) {
        queue = [];
        for (var i = urls.length - 1; i >= 0; i--) if (urls[i]) queue.push([urls[i], w, h]);
        if (queue.length) feed.start();
    }
    property Timer feed: Timer {
        interval: 16; repeat: true
        onTriggered: {
            for (var n = 0; n < 6 && art.queue.length; n++) { var q = art.queue.shift(); art.hold(q[0], q[1], q[2]) }
            if (!art.queue.length) stop();
        }
    }

    property Instantiator holders: Instantiator {
        model: art.slots
        Image {
            property int slot: -1                       // which holder this is, set when it takes art (Qt 5.12 gives an Instantiator's delegate no `index`)
            visible: false; asynchronous: true; fillMode: Image.PreserveAspectCrop
            onStatusChanged: if (status === Image.Ready && slot >= 0) art.sized(slot, implicitWidth, implicitHeight)
        }
    }
}
