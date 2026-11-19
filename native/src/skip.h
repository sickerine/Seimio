#pragma once
// SkipTimes: where an episode's intro and end credits are, for Skip Intro and Skip Credits. A port of
// stremio-webos service/skip-timestamps.js: the file's chapters (named OP, ED, Intro, Credits...), the
// IntroDB and TheIntroDB (by IMDb episode), and AniSkip (by MyAnimeList id; Kitsu ids map to it through
// Kitsu's own mappings). An anime played by its Kitsu id is asked of all three when its IMDb episode is
// known (`imdbEpisode`): AniSkip is filled in by its viewers and misses episodes the other two have
// (Reborn as a Space Mercenary 1 was in both and not in AniSkip). Each candidate must be plausible for the episode's length (an intro 5 s to
// 200 s long, credits in the second half).
// In a file with chapters, the chapters say whether a source's segment is this cut's: one named for it
// (OP, Credits) is it; else the chapter of a plausible length that a segment covers most of, with the
// chapter's own bounds (chapterFor); else a segment that opens or closes a chapter, with that edge moved
// onto the chapter's (edgeFor). A segment the chapters don't bear out gives nothing: the sources time
// other cuts of an episode often enough that their numbers alone put the button in the wrong place.
// Without chapters, sources must agree on a boundary within 5 s, and when two disagree only the stretch
// both cover is skipped; one source's own entries that disagree are no evidence, and give nothing.
// resolve() ends in `resolved({ intro, outro })`, each { from, to } in ms or null. A video's answer is a
// query (query.h), kept a day: asked for again it answers at once, and only the video asked for last
// answers.
#include <QtQml>
#include <QUrlQuery>
#include "net.h"

class SkipTimes : public QObject {
    Q_OBJECT
public:
    explicit SkipTimes(QObject *parent = nullptr) : QObject(parent) {
        // Kitsu answers 406 to plain JSON: it serves JSON:API's own type
        m_net.headers = { { "Accept", "application/vnd.api+json, application/json" } };
        m_net.idleMs = 12000;
    }
    // `videoId` is "tt…:season:episode" or "kitsu:N:episode"; `chapters` [{ start, end, title }] in ms;
    // `imdbEpisode` the same episode as "tt…:season:episode" when `videoId` is a Kitsu one, or ""
    Q_INVOKABLE void resolve(const QString &videoId, double durationMs, const QVariantList &chapters, const QString &imdbEpisode = QString()) {
        query::Options kept; kept.freshMs = kept.keepMs = 24 * 60 * 60 * 1000; kept.retries = 0;
        m_result.watch({ "skip", videoId, imdbEpisode, QString::number(qRound(durationMs / 1000)), QString::number(chapters.size()) },
                       [=](query::Call<QVariantMap> call) { gather(videoId, durationMs, chapters, imdbEpisode, call); }, kept);
        m_result.retell();                              // (each asking is answered, the same video asked for again too)
    }
    // a new video: an answer still on its way is for the last one
    Q_INVOKABLE void cancel() { m_result.stop(); }
signals:
    void resolved(const QVariantMap &segments);
private:
    struct Item { QString kind; double from, to; QString source; double episodeLength; };
    using Spans = QVector<QPair<double, double>>;              // chapters as { from, to }, in order
    struct State { QVector<Item> items; Spans spans; double duration = 0; int pending = 0; query::Call<QVariantMap> call; };
    // the fetch of a video's query: the chapters, and each source that knows the episode
    void gather(const QString &videoId, double durationMs, const QVariantList &chapters, const QString &imdbEpisode, query::Call<QVariantMap> call) {
        auto state = std::make_shared<State>();
        state->duration = durationMs; state->call = call;
        state->items = fromChapters(chapters, durationMs);
        state->spans = spansOf(sorted(chapters), durationMs);
        static const QRegularExpression imdb("^(tt\\d+):(\\d+):(\\d+)$"), kitsu("^kitsu:(\\d+):(\\d+)$");
        const auto mk = kitsu.match(videoId), mi = imdb.match(mk.hasMatch() ? imdbEpisode : videoId);
        if (mi.hasMatch()) {
            QUrlQuery q; q.addQueryItem("imdb_id", mi.captured(1)); q.addQueryItem("season", mi.captured(2)); q.addQueryItem("episode", mi.captured(3));
            get(state, "https://api.introdb.app/segments?" + q.toString(), [](const QJsonObject &o, QVector<Item> &out) {
                for (auto kind : { "intro", "outro" }) {
                    const QJsonObject r = o.value(kind).toObject();
                    if (r.isEmpty()) continue;
                    double from = time(r.value("start_sec"), r.value("start_ms")), to = time(r.value("end_sec"), r.value("end_ms"));
                    if (QString(kind) == "intro" && from < 0) from = 0;
                    out.append({ kind, from, to, "introdb", -1 });
                }
            });
            q.addQueryItem("duration_ms", QString::number(qRound64(durationMs)));
            get(state, "https://api.theintrodb.org/v3/media?" + q.toString(), [](const QJsonObject &o, QVector<Item> &out) {
                for (auto pair : { std::make_pair("intro", "intro"), std::make_pair("credits", "outro") })
                    for (const QJsonValue &v : o.value(pair.first).toArray()) {
                        const QJsonObject r = v.toObject();
                        double from = time(QJsonValue(), r.value("start_ms")), to = time(QJsonValue(), r.value("end_ms"));
                        if (QString(pair.second) == "intro" && from < 0) from = 0;
                        out.append({ pair.second, from, to, "theintrodb", -1 });
                    }
            });
        }
        if (mk.hasMatch()) {
            const QString episode = mk.captured(2);
            state->pending++;
            fetch("https://kitsu.io/api/edge/anime/" + mk.captured(1) + "/mappings?filter[externalSite]=myanimelist/anime",
                  [this, state, episode](const QJsonObject &o) {
                const QString mal = o.value("data").toArray().first().toObject().value("attributes").toObject().value("externalId").toString();
                if (!mal.isEmpty()) {
                    const QString url = "https://api.aniskip.com/v2/skip-times/" + mal + "/" + episode + "?types[]=op&types[]=ed&types[]=mixed-op&types[]=mixed-ed&episodeLength="
                                        + QString::number(qRound(state->duration / 1000));
                    get(state, url, [](const QJsonObject &o, QVector<Item> &out) {
                        if (!o.value("found").toBool()) return;
                        for (const QJsonValue &v : o.value("results").toArray()) {
                            const QJsonObject r = v.toObject(), iv = r.value("interval").toObject();
                            const QString t = r.value("skipType").toString();
                            const QString kind = t == "op" || t == "mixed-op" ? "intro" : t == "ed" || t == "mixed-ed" ? "outro" : "";
                            if (kind.isEmpty() || iv.isEmpty()) continue;
                            out.append({ kind, iv.value("startTime").toDouble() * 1000, iv.value("endTime").toDouble() * 1000, "aniskip", r.value("episodeLength").toDouble() * 1000 });
                        }
                    });
                }
                done(state);
            });
        }
        if (!state->pending) done(state);
    }
public:
    // tests: what reconcile() makes of candidates [{ kind, from, to, source, episodeLength }] (ms) for a file
    // of `durationMs` with `chapters` [{ start, end, title }]
    Q_INVOKABLE QVariantMap reconciled(const QVariantList &candidates, double durationMs, const QVariantList &chapters) const {
        QVector<Item> items = fromChapters(chapters, durationMs);
        for (const QVariant &v : candidates) {
            const QVariantMap m = v.toMap();
            items.append({ m.value("kind").toString(), m.value("from").toDouble(), m.value("to").toDouble(), m.value("source").toString(), m.value("episodeLength", -1).toDouble() });
        }
        return reconcile(items, durationMs, spansOf(sorted(chapters), durationMs));
    }
private:

    static double time(const QJsonValue &sec, const QJsonValue &ms) {
        if (ms.isDouble()) return ms.toDouble();
        if (sec.isDouble()) return sec.toDouble() * 1000;
        return -1;
    }
    static QVector<QVariantMap> sorted(const QVariantList &chapters) {
        QVector<QVariantMap> c; for (const QVariant &v : chapters) c << v.toMap();
        std::sort(c.begin(), c.end(), [](const QVariantMap &a, const QVariantMap &b) { return a.value("start").toDouble() < b.value("start").toDouble(); });
        return c;
    }
    // a chapter ends where it says, or where the next one starts, or with the file
    static Spans spansOf(const QVector<QVariantMap> &c, double duration) {
        Spans out;
        for (int i = 0; i < c.size(); i++) {
            const double from = c[i].value("start").toDouble(), end = c[i].value("end").toDouble();
            double to = end > 0 ? end : -1;
            for (int j = i + 1; to < 0 && j < c.size(); j++) if (c[j].value("start").toDouble() > from) to = c[j].value("start").toDouble();
            out << qMakePair(from, to < 0 ? duration : to);
        }
        return out;
    }
    static QVector<Item> fromChapters(const QVariantList &chapters, double duration) {
        static const QRegularExpression intro("^(?:intro|ncop|op(?:ening)?)(?:\\s*[-_:]?\\s*\\d+)?(?:\\s+(?:theme|credits|song))?$"),
                                        outro("^(?:outro|credits|nced|ed|ending)(?:\\s*[-_:]?\\s*\\d+)?(?:\\s+(?:theme|credits|song))?$|^end credits$");
        const QVector<QVariantMap> c = sorted(chapters);
        const Spans spans = spansOf(c, duration);
        // a file with OP/ED chapters means the songs by them (as AniSkip's "op" and "ed" do): there,
        // "Intro" and "Outro" are the cold open and the epilogue, not something to skip
        static const QRegularExpression song("^(?:ncop|op(?:ening)?|nced|ed|ending)(?:\\s*[-_:]?\\s*\\d+)?(?:\\s+(?:theme|credits|song))?$");
        bool songs = false;
        for (const QVariantMap &m : c) songs = songs || song.match(m.value("title").toString().trimmed().toLower()).hasMatch();
        QVector<Item> out;
        for (int i = 0; i < c.size(); i++) {
            const QString t = c[i].value("title").toString().trimmed().toLower();
            const QString kind = intro.match(t).hasMatch() ? "intro" : outro.match(t).hasMatch() ? "outro" : "";
            if (kind.isEmpty() || (songs && !song.match(t).hasMatch())) continue;
            out.append({ kind, spans[i].first, spans[i].second, "chapter", -1 });
        }
        return out;
    }
    template <typename F> void get(const std::shared_ptr<State> &state, const QString &url, F parse) {
        state->pending++;
        fetch(url, [this, state, parse](const QJsonObject &o) { parse(o, state->items); done(state); });
    }
    // one source's answer (an empty object when it couldn't be had: a source the less, asked once)
    template <typename F> void fetch(const QString &url, F onDone) {
        query::Options once; once.keepMs = 0; once.retries = 0;
        m_net.read(url, QByteArray(), once, [onDone](std::shared_ptr<const Answer> a, const query::Failure &) {
            onDone(a && a->status >= 200 && a->status < 300 ? QJsonDocument::fromJson(a->body).object() : QJsonObject());
        });
    }
    void done(const std::shared_ptr<State> &state) {
        if (--state->pending > 0) return;
        state->call.ok(reconcile(state->items, state->duration, state->spans));
    }

    // skip-timestamps.js: plausible(), strongestCluster(), sharedSegment(), reconcile()
    static bool plausible(const Item &i, double d) {
        if (i.from < 0 || i.from > d + 10000) return false;
        if (i.kind == "intro" && i.to < 0) return false;
        if (i.to >= 0 && (i.to <= i.from || i.to > d + 10000)) return false;
        const double length = i.to < 0 ? d - i.from : i.to - i.from;
        if (length < 5000 || (i.kind == "intro" && length > 200000) || (i.kind == "outro" && length > 600000)) return false;
        if (i.kind == "outro" && i.from < d / 2) return false;                      // opening titles filed as credits
        if (i.episodeLength > 0 && qAbs(i.episodeLength - d) > qMax(120000.0, d * 0.05)) return false;
        return true;
    }
    static QVector<Item> strongestCluster(const QVector<Item> &items, bool byEnd) {
        if (items.size() < 2) return items;
        QVector<Item> best;
        for (const Item &c : items) {
            QVector<Item> cluster;
            for (const Item &o : items) if (qAbs((byEnd ? o.to : o.from) - (byEnd ? c.to : c.from)) <= 5000) cluster << o;
            if (cluster.size() > best.size()) best = cluster;
        }
        return best.size() >= 2 ? best : QVector<Item>();
    }
    static QVariant shared(const QVector<Item> &items, double d) {
        if (items.size() < 2) return QVariant();
        // two entries of one source that disagree aren't two witnesses: AniSkip's "op" and "mixed-op" for
        // Dragon Ball Z 1 start two minutes apart, and what they share is neither
        bool one = true; for (const Item &i : items) one = one && i.source == items[0].source;
        if (one) return QVariant();
        double from = 0, to = d;
        for (const Item &i : items) { from = qMax(from, i.from); to = qMin(to, i.to < 0 ? d : i.to); }
        return to - from >= 5000 ? QVariant(QVariantMap { { "from", from }, { "to", to } }) : QVariant();
    }
    // The chapter a source's segment is: the one of a plausible length for `kind` that a candidate covers
    // four fifths of at least, the most covered (the earliest of equals), with the chapter's own bounds
    static QVariant chapterFor(const QString &kind, const QVector<Item> &candidates, const Spans &spans, double d) {
        double best = 0; QVariant out;
        for (const auto &s : spans) {
            if (!plausible({ kind, s.first, s.second, "chapter", -1 }, d)) continue;
            for (const Item &c : candidates) {
                const double covered = (qMin(s.second, c.to < 0 ? d : c.to) - qMax(s.first, c.from)) / (s.second - s.first);
                if (covered >= 0.8 && covered > best) { best = covered; out = QVariantMap { { "from", s.first }, { "to", s.second } }; }
            }
        }
        return out;
    }
    // A segment that isn't a chapter of its own but begins where one begins or ends where one ends (within
    // 5 s; the file's own start and end are no evidence) and lies inside it: the source's, with that edge on
    // the chapter's. Demon Slayer's Blu-rays keep the credits as the last 90 s of the chapter the episode's
    // second half is, with the preview after it as the next.
    static QVariant edgeFor(const QVector<Item> &candidates, const Spans &spans, double d) {
        for (const Item &c : candidates) {
            for (int i = 0; i < spans.size(); i++) {
                const double a = spans[i].first, b = spans[i].second;
                Item out = c; out.to = qMin(c.to < 0 ? d : c.to, b);
                if (i > 0 && qAbs(c.from - a) <= 5000 && (c.to < 0 ? d : c.to) <= b + 5000) out.from = a;                     // opens it
                else if (i + 1 < spans.size() && qAbs((c.to < 0 ? d : c.to) - b) <= 5000 && c.from >= a - 5000) out.to = b;    // closes it
                else continue;
                if (plausible(out, d)) return QVariantMap { { "from", out.from }, { "to", out.to } };
            }
        }
        return QVariant();
    }
    static QVariantMap reconcile(const QVector<Item> &all, double d, const Spans &spans = Spans()) {
        if (d <= 0) return { { "intro", QVariant() }, { "outro", QVariant() } };
        QVector<Item> intros, outros;
        for (const Item &i : all) if (plausible(i, d)) (i.kind == "intro" ? intros : outros) << i;
        QVariantMap out;
        if (!spans.isEmpty()) {
            for (const QString &kind : { QString("intro"), QString("outro") }) {
                QVector<Item> named, others;
                // a segment timed on a longer cut may run past this file's end (credits to the end of a cut
                // 16 s longer): it still says which chapter it is
                for (Item i : all) {
                    if (i.kind != kind) continue;
                    if (i.to > d) i.to = d;
                    if (plausible(i, d)) (i.source == "chapter" ? named : others) << i;
                }
                QVariant found = named.isEmpty() ? chapterFor(kind, others, spans, d) : QVariant(QVariantMap { { "from", named[0].from }, { "to", named[0].to } });
                out[kind] = found.isValid() ? found : edgeFor(others, spans, d);
            }
            return out;
        }
        const QVector<Item> ic = strongestCluster(intros, true);
        if (!ic.isEmpty()) {
            double from = d, to = 0; for (const Item &i : ic) { from = qMin(from, i.from); to = qMax(to, i.to); }
            out["intro"] = QVariantMap { { "from", from }, { "to", to } };
        } else out["intro"] = shared(intros, d);
        QVector<Item> oc = strongestCluster(outros, false);
        if (oc.isEmpty() && outros.size() >= 2) {                                  // one source's earliest
            bool one = true; for (const Item &i : outros) one = one && i.source == outros[0].source;
            if (one) { Item first = outros[0]; for (const Item &i : outros) if (i.from < first.from) first = i; oc = { first }; }
        }
        if (!oc.isEmpty()) {
            double from = d, to = d; for (const Item &i : oc) { from = qMin(from, i.from); to = qMin(to, i.to < 0 ? d : i.to); }
            out["outro"] = QVariantMap { { "from", from }, { "to", to } };
        } else out["outro"] = shared(outros, d);
        return out;
    }

    query::Queries m_queries { this };
    Net m_net { &m_queries, this };
    query::Observer<QVariantMap> m_result { &m_queries, [this](const query::Result<QVariantMap> &r) { if (r.data && !r.fetching) emit resolved(*r.data); } };
};
