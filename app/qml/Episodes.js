// Where a show's episode list rests, as { s, e } (season and episode indexes in show.seasons).
// The anchor is the episode Stremio has as current (the last one played), else the last one with any
// watch state. Resting on it: an unfinished anchor is where you are; a finished one moves to the
// next episode; an anchor that is neither (Stremio already moved on to it) is where you are. With no
// anchor: the first episode of the first numbered season, so specials (season 0) don't come first.
// Never an episode that hasn't aired (`today`, "YYYY-MM-DD") while an aired one comes before it: a
// show you're caught up on rests on the last aired episode.
.pragma library

function started(ep) { return ep.progress > 0 && ep.progress < 95 }
function finished(ep) { return !started(ep) && (ep.watched || ep.progress >= 95) }
// Kitsu dates what it doesn't know 1970-01-01: that isn't aired
function aired(ep, today) { return !!ep.released && ep.released > "1970-01-01" && ep.released <= today }

// every episode in order, with its indexes
function flat(show) {
    var out = [], seasons = show && show.seasons ? show.seasons : [];
    for (var s = 0; s < seasons.length; s++)
        for (var e = 0; e < seasons[s].episodes.length; e++) out.push({ s: s, e: e, ep: seasons[s].episodes[e] });
    return out;
}

// the episode after `id` in the show, into the next season, once it has aired; null on the last aired one,
// and never on into Specials (season 0: films and extras)
function after(show, id, today) {
    var all = flat(show);
    for (var i = 0; i + 1 < all.length; i++) {
        if (all[i].ep.id !== id) continue;
        var next = all[i + 1];
        return aired(next.ep, today) && show.seasons[next.s].season !== 0 ? next.ep : null;
    }
    return null;
}

// the position of the episode `id`, or null
function find(show, id) {
    var all = flat(show);
    for (var i = 0; i < all.length; i++) if (all[i].ep.id === id) return { s: all[i].s, e: all[i].e };
    return null;
}

function resting(show, today) {
    var all = flat(show), at = -1, i;
    if (!all.length) return { s: 0, e: 0 };
    for (i = 0; i < all.length && at < 0; i++) if (all[i].ep.id === show.current) at = i;
    for (i = all.length - 1; i >= 0 && at < 0; i--) if (all[i].ep.watched || all[i].ep.progress > 0) at = i;
    if (at < 0) {
        for (i = 0; i < all.length; i++) if (show.seasons[all[i].s].season > 0) return { s: all[i].s, e: all[i].e };
        return { s: 0, e: 0 };
    }
    if (finished(all[at].ep) && at + 1 < all.length) at++;
    while (at > 0 && !aired(all[at].ep, today)) at--;
    return { s: all[at].s, e: all[at].e };
}
