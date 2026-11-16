// Lab data: Home rows and shows with episodes, from the JSON and art in app/art (fetched by
// tools/fetch-art.py). The real app gets the same shapes from stremio-core.
//   rows:   [{ title, kind: "landscape" | "portrait", items: [title] }]
//   title:  { id, name, title, art, backdrop, logo, description, chips, rating, episode, progress }
//   series: { id: { name, current, description, genres, year, rating, seasons: [{ season, episodes }] } }
// Art paths become absolute URLs here, so components anywhere can load them.
import QtQuick 2.12

QtObject {
    id: catalog
    property var rows: []
    property var series: ({})
    readonly property string base: Qt.resolvedUrl("../art/")

    function load(name, done) {
        var x = new XMLHttpRequest();
        x.open("GET", base + name);
        x.onreadystatechange = function () { if (x.readyState === 4) done(x.status === 200 || x.status === 0 ? x.responseText : "") };
        x.send();
    }
    function art(file) { return file ? base + file : "" }

    Component.onCompleted: {
        load("series.json", function (t) {
            if (!t) return;
            var all = JSON.parse(t);
            for (var id in all)
                all[id].seasons.forEach(function (s) { s.episodes.forEach(function (e) { e.thumb = catalog.art(e.thumb) }) });
            catalog.series = all;
        });
        load("cw.json", function (cwText) {
            load("rows.json", function (popText) {
                var cw = JSON.parse(cwText).filter(function (i) { return i.backdrop }).map(function (i) {
                    return { id: i.id, name: i.name, title: i.name, art: art(i.backdrop), backdrop: art(i.backdrop), logo: art(i.logo),
                             description: i.description, chips: [String(i.year).replace(/[-–]$/, "")].concat(i.genres).filter(function (s) { return s }),
                             rating: "", episode: i.episode, progress: i.progress };
                });
                var out = [{ title: "Continue watching", kind: "landscape", items: cw }];
                JSON.parse(popText).forEach(function (r) {
                    out.push({ title: r.title, kind: "portrait", items: r.items.map(function (m) {
                        return { id: m.id, name: m.name, title: m.name, art: art(m.poster), backdrop: art(m.backdrop), logo: art(m.logo),
                                 description: m.description, chips: [m.year, m.runtime].concat(m.genres).filter(function (s) { return s }),
                                 rating: m.rating, episode: "", progress: -1 };
                    }) });
                });
                catalog.rows = out;
            });
        });
    }
}
