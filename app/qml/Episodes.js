// What the screens ask of a show's episodes: where it rests, what comes after an episode, how one is named.
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

// how an episode is named: on a card's chip, and spelled out
function chip(n) { return "E" + n }
function named(n) { return "Episode " + n }

// The up-next countdown as two positions in the video (ms): it runs from `from` to `until`, where the next
// episode takes over. "credits": ten seconds from where the credits start, or from `p` when the offer is
// made further in (a seek into them), never past their end; "end": the file's last ten seconds.
function upNextSpan(mode, p, duration, outro) {
    if (mode !== "credits" || !outro) return { from: duration - 10000, until: duration };
    var from = Math.max(outro.start, p);
    return { from: from, until: Math.min(from + 10000, outro.end, duration) };
}
// how far through it the video is, 0 to 1
function upNextElapsed(span, p) { return span.until > span.from ? Math.max(0, Math.min(1, (p - span.from) / (span.until - span.from))) : 0 }

// the position of the episode `id`, or null
function find(show, id) {
    var all = flat(show);
    for (var i = 0; i < all.length; i++) if (all[i].ep.id === id) return { s: all[i].s, e: all[i].e };
    return null;
}

// Where a show's episode list rests, as { s, e } (season and episode indexes in show.seasons): the episode
// you are on. The show says which (`rest`, an episode's id: native/src/resting.h has the one rule for
// it), so a Continue Watching card, the episode its page opens on and the one Play names there agree.
function resting(show) { return (show && show.rest ? find(show, show.rest) : null) || { s: 0, e: 0 } }
