#pragma once
// Where a show's episode list rests: the episode you are on. The one rule for it. A show made here
// (Live::show, Franchise) carries its answer as `rest`, an episode's id, and everything goes by that: a
// Continue Watching card's still and label (Catalog), the episode its page opens on, and the one the
// page's Play names (Episodes.resting in the app reads `rest`). Worked out apart in three places, the
// card said one episode and the page another.
//
// The anchor is the episode Stremio has as current (the last one played), else the last one with any
// watch state. Resting on it: an unfinished anchor is where you are; a finished one moves to the next
// episode; an anchor that is neither (Stremio already moved on to it) is where you are. With no anchor:
// the first episode of the first numbered season, so specials (season 0) don't come first. Never an
// episode that hasn't aired while an aired one comes before it: a show you're caught up on rests on the
// last aired episode.
#include <QDate>
#include <QMutex>
#include <QString>
#include <QVariant>
#include <QVector>

namespace Episodes {
struct Ep { QString id, released; bool watched = false; double progress = 0; int season = 1; };

// The day episodes are judged aired by ("YYYY-MM-DD"): the app's when it has said one (a preview pins
// its day), else the clock's. Read on the data thread, set on the GUI's.
inline QMutex &dayLock() { static QMutex lock; return lock; }
inline QString &dayPinned() { static QString day; return day; }
inline void setToday(const QString &day) { QMutexLocker l(&dayLock()); dayPinned() = day; }
inline QString today() { QMutexLocker l(&dayLock()); return dayPinned().isEmpty() ? QDate::currentDate().toString("yyyy-MM-dd") : dayPinned(); }

inline bool started(const Ep &e) { return e.progress > 0 && e.progress < 95; }
inline bool finished(const Ep &e) { return !started(e) && (e.watched || e.progress >= 95); }
// Kitsu dates what it doesn't know 1970-01-01: that isn't aired
inline bool aired(const Ep &e, const QString &day) { return !e.released.isEmpty() && e.released > "1970-01-01" && e.released <= day; }

// which of `all` (every episode, in order) the list rests on; -1 with no episodes
inline int resting(const QVector<Ep> &all, const QString &current, const QString &day) {
    if (all.isEmpty()) return -1;
    int at = -1;
    for (int i = 0; i < all.size() && at < 0; i++) if (all[i].id == current) at = i;
    for (int i = all.size() - 1; i >= 0 && at < 0; i--) if (all[i].watched || all[i].progress > 0) at = i;
    if (at < 0) {
        for (int i = 0; i < all.size(); i++) if (all[i].season > 0) return i;
        return 0;
    }
    if (finished(all[at]) && at + 1 < all.size()) at++;
    while (at > 0 && !aired(all[at], day)) at--;
    return at;
}
// every episode of a show's seasons, [{ season, episodes: [{ id, watched, progress, released }] }], in
// order (a franchise's related shows are a tab of its page, and no episodes of it)
inline QVector<Ep> flat(const QVariantList &seasons) {
    QVector<Ep> all;
    for (const QVariant &s : seasons) {
        const QVariantMap season = s.toMap();
        if (season.value("kind") == "related") continue;
        for (const QVariant &e : season.value("episodes").toList()) {
            const QVariantMap ep = e.toMap();
            all << Ep { ep.value("id").toString(), ep.value("released").toString(), ep.value("watched").toBool(), ep.value("progress").toDouble(), season.value("season").toInt() };
        }
    }
    return all;
}
// the id of the episode those seasons rest on, "" when they have none
inline QString rest(const QVariantList &seasons, const QString &current, const QString &day = today()) {
    const QVector<Ep> all = flat(seasons);
    const int at = resting(all, current, day);
    return at < 0 ? QString() : all[at].id;
}
}
