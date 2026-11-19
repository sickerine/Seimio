// Loads franchises one after another through the app's own Catalog (live network, an empty account) and
// prints each as a line of JSON: its season tabs, entries and related shows. The ids are the last argument,
// comma separated (tools/franchises.sh).
import QtQuick 2.12
import Seimio.Data 1.0

Item {
    id: root
    property var ids: (Qt.application.arguments[Qt.application.arguments.length - 1] || "").split(",")
    property int at: -1
    property double askedAt: 0              // when the show on its way was asked for (`ms` in its line: how long it took)
    function say(sourceId, item, show) {
        giveUp.stop();
        var tabs = (show.seasons || []).map(function (s) {
            var entries = {};       // by entry: how many of the tab's episodes are its
            s.episodes.forEach(function (e) { if (e.entry !== undefined) entries[e.entry] = (entries[e.entry] || 0) + 1 });
            return { season: s.season, label: s.label || "", kind: s.kind || "", episodes: s.episodes.length, entries: Object.keys(entries).map(Number),
                     counts: Object.keys(entries).map(function (k) { return entries[k] }), first: s.episodes.length ? s.episodes[0].id : "" };
        });
        console.log("FRANCHISE " + JSON.stringify({ asked: sourceId, ms: Date.now() - root.askedAt, item: item.id, video: item.video || "", name: show.name, rest: show.rest || "",
            entries: (show.entries || []).map(function (e) { return { id: e.id, kind: e.kind, title: e.title, logo: e.logo || "", backdrop: e.backdrop || "" } }),
            tabs: tabs, related: (show.related || []).map(function (r) { return { id: r.id, title: r.title, relation: r.relation } }) }));
        next.restart();
    }
    Catalog {
        id: catalog
        onFranchiseReady: if (sourceId === root.ids[root.at]) root.say(sourceId, item, show)
        onFranchiseFailed: { if (sourceId !== root.ids[root.at]) return; giveUp.stop(); console.log("FRANCHISE " + JSON.stringify({ asked: sourceId, failed: reason })); next.restart() }
    }
    // (a franchise is three or four questions to AniList, which answers thirty a minute: one show every eight seconds)
    Timer {
        id: next; interval: 8000; running: true
        onTriggered: {
            root.at++;
            if (root.at >= root.ids.length) { console.log("SWEEP DONE"); Qt.quit(); return }
            giveUp.restart(); root.askedAt = Date.now();
            // (as the app asks: a page Catalog holds already, under an id an earlier one of the run turned
            // out to be, is read from it, and `loadFranchise` says nothing of it again)
            var id = root.ids[root.at], held = catalog.franchise(id);
            if (held) root.say(id, held.item, held.show); else catalog.loadFranchise({ id: id, type: "series", name: "" });
        }
    }
    Timer { id: giveUp; interval: 45000; onTriggered: { console.log("FRANCHISE " + JSON.stringify({ asked: root.ids[root.at], failed: "no answer in 45 s" })); next.restart() } }
}
