// Loads franchises one after another through the app's own Catalog (live network, an empty account) and
// prints each as a line of JSON: its season tabs, entries and related shows. The ids are the last argument,
// comma separated (tools/franchises.sh).
import QtQuick 2.12
import Seimio.Data 1.0

Item {
    id: root
    property var ids: (Qt.application.arguments[Qt.application.arguments.length - 1] || "").split(",")
    property int at: -1
    Catalog {
        id: catalog
        onFranchiseReady: {
            if (sourceId !== root.ids[root.at]) return;
            var tabs = (show.seasons || []).map(function (s) {
                var entries = {};
                s.episodes.forEach(function (e) { if (e.entry !== undefined) entries[e.entry] = true });
                return { season: s.season, label: s.label || "", kind: s.kind || "", episodes: s.episodes.length, entries: Object.keys(entries).map(Number),
                         first: s.episodes.length ? s.episodes[0].id : "" };
            });
            console.log("FRANCHISE " + JSON.stringify({ asked: sourceId, item: item.id, video: item.video || "", name: show.name, rest: show.rest || "",
                entries: (show.entries || []).map(function (e) { return { id: e.id, kind: e.kind, title: e.title } }),
                tabs: tabs, related: (show.related || []).map(function (r) { return { id: r.id, title: r.title, relation: r.relation } }) }));
            next.restart();
        }
        onFranchiseFailed: { if (sourceId !== root.ids[root.at]) return; console.log("FRANCHISE " + JSON.stringify({ asked: sourceId, failed: reason })); next.restart() }
    }
    // (a franchise is three or four questions to AniList, which answers thirty a minute: one show every eight seconds)
    Timer { id: next; interval: 8000; running: true; onTriggered: { root.at++; if (root.at >= root.ids.length) { console.log("SWEEP DONE"); Qt.quit(); return } giveUp.restart(); catalog.loadFranchise({ id: root.ids[root.at], type: "series", name: "" }) } }
    Timer { id: giveUp; interval: 45000; onTriggered: { console.log("FRANCHISE " + JSON.stringify({ asked: root.ids[root.at], failed: "no answer in 45 s" })); next.restart() } }
}
