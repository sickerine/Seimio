// Lab data, from the JSON and art in app/art (fetched by tools/fetch-art.py). The real app gets the same
// shapes from stremio-core.
//   continueWatching: [title]
//   popular:          [{ title, kind: "portrait", items: [title] }]   (for the tabs; Home doesn't list them)
//   title:            { id, name, title, art, backdrop, logo, description, chips, rating, episode, progress }
//   series:           { id: { name, current, description, genres, year, rating, seasons: [{ season, episodes }] } }
//   calendar:         { "YYYY-MM-DD": [{ item, name, art, season, episode, title, overview, watched, released, time }] }
//                     every episode of a library show by release day; `item` is the show's title entry.
//                     With airing.json (tools/fetch-airing.py), a month of AniList's airing schedule
//                     follows the library's episodes on each day, to try the calendar with a full month.
// Art paths become absolute URLs here, so components anywhere can load them.
import QtQuick 2.12

QtObject {
    id: catalog
    property var continueWatching: []
    property var popular: []
    property var series: ({})
    property var calendar: ({})
    property var airing: []
    readonly property string base: Qt.resolvedUrl("../art/")

    function load(name, done) {
        var x = new XMLHttpRequest();
        x.open("GET", base + name);
        x.onreadystatechange = function () { if (x.readyState === 4) done(x.status === 200 || x.status === 0 ? x.responseText : "") };
        x.send();
    }
    function art(file) { return file ? base + file : "" }

    function buildCalendar() {
        var byId = {};
        continueWatching.forEach(function (i) { byId[i.id] = i });
        var out = {};
        for (var id in series) {
            var show = series[id], item = byId[id];
            if (!item) continue;
            show.seasons.forEach(function (s) {
                s.episodes.forEach(function (e) {
                    if (!e.released) return;
                    (out[e.released] = out[e.released] || []).push({
                        item: item, name: show.name, art: e.thumb || item.backdrop,
                        season: s.season, episode: e.episode, title: e.title, overview: e.overview, watched: e.watched, released: e.released, time: ""
                    });
                });
            });
        }
        airing.forEach(function (a) {
            var item = { id: a.id, name: a.name, title: a.name, art: a.art, backdrop: a.art, logo: "", description: a.description,
                         chips: [], rating: "", episode: "E" + a.episode, progress: -1 };
            (out[a.date] = out[a.date] || []).push({ item: item, name: a.name, art: a.art, season: 1, episode: a.episode,
                                                     title: "", overview: a.description, watched: false, released: a.date, time: a.time });
        });
        calendar = out;
    }

    Component.onCompleted: {
        load("series.json", function (t) {
            if (!t) return;
            var all = JSON.parse(t);
            for (var id in all)
                all[id].seasons.forEach(function (s) { s.episodes.forEach(function (e) { e.thumb = catalog.art(e.thumb) }) });
            catalog.series = all;
            catalog.buildCalendar();
        });
        load("cw.json", function (t) {
            catalog.continueWatching = JSON.parse(t).filter(function (i) { return i.backdrop }).map(function (i) {
                return { id: i.id, name: i.name, title: i.name, art: art(i.backdrop), backdrop: art(i.backdrop), logo: art(i.logo),
                         description: i.description, chips: [String(i.year).replace(/[-–]$/, "")].concat(i.genres).filter(function (s) { return s }),
                         rating: "", episode: i.episode, progress: i.progress };
            });
            catalog.buildCalendar();
        });
        load("airing.json", function (t) {
            if (!t) return;
            catalog.airing = JSON.parse(t).map(function (a) { a.art = catalog.art(a.art); return a });
            catalog.buildCalendar();
        });
        load("rows.json", function (t) {
            catalog.popular = JSON.parse(t).map(function (r) {
                return { title: r.title, kind: "portrait", items: r.items.map(function (m) {
                    return { id: m.id, name: m.name, title: m.name, art: art(m.poster), backdrop: art(m.backdrop), logo: art(m.logo),
                             description: m.description, chips: [m.year, m.runtime].concat(m.genres).filter(function (s) { return s }),
                             rating: m.rating, episode: "", progress: -1 };
                }) };
            });
        });
    }
}
