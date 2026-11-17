#pragma once
// SkipTimes: where an episode's intro and end credits are, for Skip Intro and Skip Credits. A port of
// stremio-webos service/skip-timestamps.js: the file's chapters (named OP, ED, Intro, Credits...), the
// IntroDB and TheIntroDB (by IMDb episode), and AniSkip (by MyAnimeList id; Kitsu ids map to it through
// Kitsu's own mappings). Each candidate must be plausible for the episode's length (an intro 5 s to
// 200 s long, credits in the second half), sources must agree on a boundary within 5 s, and when they
// disagree only the stretch they all cover is skipped. resolve() ends in `resolved({ intro, outro })`,
// each { from, to } in ms or null; results are kept for the session.
#include <QtQml>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QUrlQuery>
#include <QTimer>

class SkipTimes : public QObject {
    Q_OBJECT
public:
    // `videoId` is "tt…:season:episode" or "kitsu:N:episode"; `chapters` [{ start, end, title }] in ms
    Q_INVOKABLE void resolve(const QString &videoId, double durationMs, const QVariantList &chapters) {
        const int ticket = ++m_ticket;
        const QString key = videoId + "|" + QString::number(qRound(durationMs / 1000)) + "|" + QString::number(chapters.size());
        if (m_cache.contains(key)) { emit resolved(m_cache.value(key)); return; }
        auto state = std::make_shared<State>();
        state->duration = durationMs; state->key = key; state->ticket = ticket;
        state->items = fromChapters(chapters, durationMs);
        static const QRegularExpression imdb("^(tt\\d+):(\\d+):(\\d+)$"), kitsu("^kitsu:(\\d+):(\\d+)$");
        const auto mi = imdb.match(videoId), mk = kitsu.match(videoId);
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
        } else if (mk.hasMatch()) {
            const QString episode = mk.captured(2);
            state->pending++;
            fetch(QUrl("https://kitsu.io/api/edge/anime/" + mk.captured(1) + "/mappings?filter[externalSite]=myanimelist/anime"), ticket,
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
    // a new video: an answer still on its way is for the last one
    Q_INVOKABLE void cancel() { ++m_ticket; }
signals:
    void resolved(const QVariantMap &segments);
private:
    struct Item { QString kind; double from, to; QString source; double episodeLength; };
    struct State { QVector<Item> items; double duration = 0; int pending = 0; int ticket = 0; QString key; };

    static double time(const QJsonValue &sec, const QJsonValue &ms) {
        if (ms.isDouble()) return ms.toDouble();
        if (sec.isDouble()) return sec.toDouble() * 1000;
        return -1;
    }
    static QVector<Item> fromChapters(const QVariantList &chapters, double duration) {
        static const QRegularExpression intro("^(?:intro|ncop|op(?:ening)?)(?:\\s*[-_:]?\\s*\\d+)?(?:\\s+(?:theme|credits|song))?$"),
                                        outro("^(?:outro|credits|nced|ed|ending)(?:\\s*[-_:]?\\s*\\d+)?(?:\\s+(?:theme|credits|song))?$|^end credits$");
        QVector<QVariantMap> c; for (const QVariant &v : chapters) c << v.toMap();
        std::sort(c.begin(), c.end(), [](const QVariantMap &a, const QVariantMap &b) { return a.value("start").toDouble() < b.value("start").toDouble(); });
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
            const double from = c[i].value("start").toDouble(), end = c[i].value("end").toDouble();
            // a chapter ends where it says, or where the next one starts
            double to = end > 0 ? end : -1;
            for (int j = i + 1; to < 0 && j < c.size(); j++) if (c[j].value("start").toDouble() > from) to = c[j].value("start").toDouble();
            out.append({ kind, from, to < 0 ? duration : to, "chapter", -1 });
        }
        return out;
    }
    template <typename F> void get(const std::shared_ptr<State> &state, const QString &url, F parse) {
        state->pending++;
        fetch(QUrl(url), state->ticket, [this, state, parse](const QJsonObject &o) { parse(o, state->items); done(state); });
    }
    template <typename F> void fetch(const QUrl &url, int ticket, F onDone) {
        QNetworkRequest r(url);
        r.setHeader(QNetworkRequest::UserAgentHeader, "seimio/0.1");
        // Kitsu answers 406 to plain JSON: it serves JSON:API's own type
        r.setRawHeader("Accept", "application/vnd.api+json, application/json");
        r.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
        QNetworkReply *reply = m_net.get(r);
        QTimer::singleShot(12000, reply, &QNetworkReply::abort);
        connect(reply, &QNetworkReply::finished, this, [this, reply, ticket, onDone] {
            reply->deleteLater();
            if (ticket != m_ticket) return;
            onDone(reply->error() == QNetworkReply::NoError ? QJsonDocument::fromJson(reply->readAll()).object() : QJsonObject());
        });
    }
    void done(const std::shared_ptr<State> &state) {
        if (--state->pending > 0 || state->ticket != m_ticket) return;
        const QVariantMap result = reconcile(state->items, state->duration);
        m_cache.insert(state->key, result);
        emit resolved(result);
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
        double from = 0, to = d;
        for (const Item &i : items) { from = qMax(from, i.from); to = qMin(to, i.to < 0 ? d : i.to); }
        return to - from >= 5000 ? QVariant(QVariantMap { { "from", from }, { "to", to } }) : QVariant();
    }
    static QVariantMap reconcile(const QVector<Item> &all, double d) {
        if (d <= 0) return { { "intro", QVariant() }, { "outro", QVariant() } };
        QVector<Item> intros, outros;
        for (const Item &i : all) if (plausible(i, d)) (i.kind == "intro" ? intros : outros) << i;
        QVariantMap out;
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

    QNetworkAccessManager m_net;
    QHash<QString, QVariantMap> m_cache;
    int m_ticket = 0;
};
