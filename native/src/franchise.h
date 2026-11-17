#pragma once
// Franchise: an anime as one show however it's reached (an AniList id from the Anime tab, a Kitsu id from
// Continue Watching or the calendar), with every season, part, film and special as an entry of its own: its
// English title, logo, backdrop, poster, description, year and score. docs/anime-seasons.md has the survey
// behind it.
//  1. ARM maps the id to Kitsu, AniList and the TVDB show, then lists the show's entries with their TVDB
//     season (0: specials and films; none: a long runner Kitsu keeps whole).
//  2. AniList's SEQUEL links from the newest season add seasons ARM can't place yet.
//  3. In parallel: each entry's Kitsu meta (episodes, logo, backdrop, poster, year), AniList for all the
//     entries at once (English titles, scores, descriptions), and Cinemeta for the franchise (its name, logo,
//     backdrop).
//  4. Seasons: long runners first, the TVDB seasons in order (split parts joined, numbered on), unplaced
//     sequels, then Movies and Specials. Every episode names its entry, and an entry without its own logo or
//     backdrop takes the franchise's.
//  5. Watch state: each member's own Stremio library state (Stremio keeps every Kitsu entry apart) over its
//     episodes; where you are is the member watched last.
// A show Kitsu doesn't have comes from Cinemeta by its IMDb id.
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QRegularExpression>
#include <QSet>
#include <QThread>
#include <QTimer>
#include <QUrl>
#include <QVariant>
#include <algorithm>
#include <climits>
#include <functional>
#include <memory>
#include "live.h"

class Franchise : public QObject {
    Q_OBJECT
public:
    explicit Franchise(QObject *parent = nullptr) : QObject(parent) {}
    void setLibrary(const QJsonObject &library) { m_library = library; }

    // `source`: { id: "anilist:N" or "kitsu:N", and what the screen showed (kept as it is) }
    void load(const QVariantMap &source) {
        auto job = std::make_shared<Job>(); job->source = source; job->sourceId = source["id"].toString();
        const QString kind = job->sourceId.section(':', 0, 0), id = job->sourceId.section(':', 1, 1);
        get("https://arm.haglund.dev/api/v2/ids?source=" + kind + "&id=" + id, [this, job](const QByteArray &body, bool ok) {
            const QJsonObject ids = QJsonDocument::fromJson(body).object();
            job->picked = ids.value("kitsu").toInt();
            if (!ok || ids.isEmpty()) { emit failed(job->sourceId, "Not on Kitsu yet"); return; }
            if (!job->picked) { cinemetaOnly(job, ids.value("imdb").toString()); return; }
            job->imdb = ids.value("imdb").toString();
            const int tvdb = ids.value("thetvdb").toInt();
            if (!tvdb) { job->entries = QJsonArray { ids }; job->tail = ids.value("anilist").toInt(); sequels(job, 0); return; }
            get("https://arm.haglund.dev/api/v2/thetvdb?id=" + QString::number(tvdb), [this, job, ids](const QByteArray &body, bool ok) {
                job->entries = ok ? QJsonDocument::fromJson(body).array() : QJsonArray();
                bool has = false; int best = -1;
                for (const QJsonValue &v : job->entries) {
                    const QJsonObject e = v.toObject();
                    has = has || e.value("kitsu").toInt() == job->picked;
                    if (job->imdb.isEmpty()) job->imdb = e.value("imdb").toString();
                    const int season = e.value("thetvdb-season").toInt(-1);
                    if (season > best && e.value("anilist").toInt()) { best = season; job->tail = e.value("anilist").toInt(); }
                }
                if (!has) job->entries.append(ids);
                if (!job->tail) job->tail = ids.value("anilist").toInt();
                sequels(job, 0);
            });
        });
    }
signals:
    void ready(const QString &sourceId, const QVariantMap &item, const QVariantMap &show);
    void failed(const QString &sourceId, const QString &reason);

private:
    struct Job {
        QVariantMap source; QString sourceId, imdb; int picked = 0, tail = 0, pending = 0;
        QJsonArray entries; QHash<int, QJsonObject> kitsu; QHash<int, QJsonObject> anilist; QJsonObject cinemeta; QJsonObject library;
    };
    QNetworkAccessManager m_net { this };
    QJsonObject m_library;

    void get(const QString &url, std::function<void(const QByteArray &, bool)> done) { send(url, QByteArray(), done); }
    void send(const QString &url, const QByteArray &body, std::function<void(const QByteArray &, bool)> done) {
        QNetworkRequest r { QUrl(url) };
        r.setHeader(QNetworkRequest::UserAgentHeader, "seimio/0.1");
        r.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
        if (!body.isEmpty()) { r.setHeader(QNetworkRequest::ContentTypeHeader, "application/json"); r.setRawHeader("Accept", "application/json"); }
        QNetworkReply *reply = body.isEmpty() ? m_net.get(r) : m_net.post(r, body);
        QTimer::singleShot(15000, reply, &QNetworkReply::abort);
        connect(reply, &QNetworkReply::finished, this, [reply, done] { reply->deleteLater(); done(reply->readAll(), reply->error() == QNetworkReply::NoError); });
    }
    static QByteArray graphql(const QString &query) { return QJsonDocument(QJsonObject { { "query", query } }).toJson(QJsonDocument::Compact); }

    // AniList's next season after `job->tail` that ARM's TVDB show doesn't have (up to 3 in a row)
    void sequels(std::shared_ptr<Job> job, int hop) {
        if (!job->tail || hop >= 3) { details(job); return; }
        send("https://graphql.anilist.co", graphql("{ Media(id:" + QString::number(job->tail) + "){ relations{ edges{ relationType node{ id type format } } } } }"),
             [this, job, hop](const QByteArray &body, bool) {
            int next = 0;
            for (const QJsonValue &v : QJsonDocument::fromJson(body).object().value("data").toObject().value("Media").toObject().value("relations").toObject().value("edges").toArray()) {
                const QJsonObject e = v.toObject(), n = e.value("node").toObject();
                const QString f = n.value("format").toString();
                if (e.value("relationType").toString() == "SEQUEL" && n.value("type").toString() == "ANIME" && (f == "TV" || f == "TV_SHORT" || f == "ONA")) { next = n.value("id").toInt(); break; }
            }
            for (const QJsonValue &v : job->entries) if (next && v.toObject().value("anilist").toInt() == next) next = 0;
            if (!next) { details(job); return; }
            get("https://arm.haglund.dev/api/v2/ids?source=anilist&id=" + QString::number(next), [this, job, hop, next](const QByteArray &body, bool ok) {
                QJsonObject ids = QJsonDocument::fromJson(body).object();
                if (!ok || !ids.value("kitsu").toInt()) { details(job); return; }
                ids["appended"] = true;
                job->entries.append(ids); job->tail = next;
                sequels(job, hop + 1);
            });
        });
    }
    // every entry's Kitsu meta, AniList for all the entries, Cinemeta for the franchise; then the show
    void details(std::shared_ptr<Job> job) {
        QVector<int> kitsu; QStringList anilist;
        for (const QJsonValue &v : job->entries) {
            const QJsonObject e = v.toObject();
            const int k = e.value("kitsu").toInt(), a = e.value("anilist").toInt();
            if (k && !kitsu.contains(k)) kitsu << k;
            if (a && !anilist.contains(QString::number(a))) anilist << QString::number(a);
        }
        job->pending = kitsu.size() + 1 + (job->imdb.isEmpty() ? 0 : 1);
        auto done = [this, job] {
            if (--job->pending) return;
            if (!job->kitsu.contains(job->picked)) { emit failed(job->sourceId, "Couldn't load its episodes"); return; }
            job->library = m_library;
            auto out = std::make_shared<QPair<QVariantMap, QVariantMap>>();
            QThread *worker = QThread::create([out, job] { *out = build(*job); });
            connect(worker, &QThread::finished, this, [this, out, job] { emit ready(job->sourceId, out->first, out->second); });
            connect(worker, &QThread::finished, worker, &QObject::deleteLater);
            worker->start();
        };
        for (int k : kitsu)
            get("https://anime-kitsu.strem.fun/meta/series/kitsu:" + QString::number(k) + ".json", [job, k, done](const QByteArray &body, bool ok) {
                if (ok) job->kitsu[k] = QJsonDocument::fromJson(body).object().value("meta").toObject();
                done();
            });
        send("https://graphql.anilist.co", graphql("{ Page(perPage:50){ media(id_in:[" + anilist.join(',') + "]){ id title{ english romaji } averageScore description(asHtml:false) } } }"),
             [job, done](const QByteArray &body, bool) {
            for (const QJsonValue &v : QJsonDocument::fromJson(body).object().value("data").toObject().value("Page").toObject().value("media").toArray())
                job->anilist[v.toObject().value("id").toInt()] = v.toObject();
            done();
        });
        if (!job->imdb.isEmpty())
            get("https://v3-cinemeta.strem.io/meta/series/" + job->imdb + ".json", [job, done](const QByteArray &body, bool) {
                job->cinemeta = QJsonDocument::fromJson(body).object().value("meta").toObject();
                done();
            });
    }
    static QString clean(QString text) {
        text.replace(QRegularExpression("<[^>]+>|\\(Source:[^)]*\\)"), " ");
        return text.simplified();
    }

    static QPair<QVariantMap, QVariantMap> build(const Job &job) {
        const QJsonObject &cm = job.cinemeta;
        const QString showLogo = cm.value("logo").toString(), showBackdrop = cm.value("background").toString();
        struct Part { int kitsu, tvdb; bool appended, film; QJsonObject meta, ids; QString first; };
        QVector<Part> parts;
        for (const QJsonValue &v : job.entries) {
            const QJsonObject e = v.toObject();
            const int k = e.value("kitsu").toInt();
            if (!k || !job.kitsu.contains(k)) continue;
            const QJsonObject meta = job.kitsu[k];
            QString first;
            for (const QJsonValue &x : meta.value("videos").toArray()) { const QString r = x.toObject().value("released").toString().left(10); if (r > "1970-01-01" && (first.isEmpty() || r < first)) first = r; }
            parts.append({ k, e.value("thetvdb-season").toInt(-1), e.value("appended").toBool(),
                           e.value("media").toString() == "MOVIE" || meta.value("type").toString() == "movie", meta, e, first.isEmpty() ? QString("9999") : first });
        }
        // the order: long runners (-1), numbered seasons, unplaced sequels, then season 0 (films, specials)
        auto rank = [](const Part &p) { return p.tvdb == 0 ? 3 : p.appended ? 2 : p.tvdb < 0 ? 0 : 1; };
        std::stable_sort(parts.begin(), parts.end(), [&rank](const Part &a, const Part &b) {
            if (rank(a) != rank(b)) return rank(a) < rank(b);
            if (rank(a) == 1 && a.tvdb != b.tvdb) return a.tvdb < b.tvdb;
            return a.first < b.first;
        });
        // where you are: the member watched last
        QString current; QString lastWatched;
        for (const Part &p : parts) {
            const QJsonObject st = job.library.value("kitsu:" + QString::number(p.kitsu)).toObject();
            const QString at = st.value("lastWatched").toString();
            if (!st.value("video_id").toString().isEmpty() && at > lastWatched) { lastWatched = at; current = st.value("video_id").toString(); }
        }
        QVariantList entries, seasons, films, specials, episodes;
        int number = 0, offset = 0, lastKey = INT_MIN; QString pickedFirst;
        auto close = [&] { if (!episodes.isEmpty()) seasons << QVariantMap { { "season", ++number }, { "episodes", episodes } }; episodes.clear(); offset = 0; };
        for (const Part &p : parts) {
            const QString id = "kitsu:" + QString::number(p.kitsu);
            const QJsonObject al = job.anilist.value(p.ids.value("anilist").toInt());
            const QJsonObject title = al.value("title").toObject();
            const QJsonArray aliases = p.meta.value("aliases").toArray();
            const QString name = title.value("english").toString(!aliases.isEmpty() ? aliases.first().toString() : p.meta.value("name").toString());
            const QString kind = rank(p) == 3 ? (p.film ? "film" : "special") : "season";
            const int entry = entries.size();
            entries << QVariantMap {
                { "id", id }, { "kind", kind }, { "title", name },
                { "logo", p.meta.value("logo").toString(showLogo) }, { "backdrop", p.meta.value("background").toString(showBackdrop) },
                { "poster", p.meta.value("poster").toString() }, { "year", p.meta.value("year").toVariant().toString() },
                { "runtime", p.meta.value("runtime").toString() }, { "genres", p.meta.value("genres").toArray().toVariantList() },
                // IMDb's, as the franchise's; AniList's score only where IMDb has none
                { "rating", !p.meta.value("imdbRating").toVariant().toString().isEmpty() ? p.meta.value("imdbRating").toVariant().toString()
                          : al.value("averageScore").toInt() ? QString::number(al.value("averageScore").toInt()) + "%" : QString() },
                { "description", clean(al.value("description").toString(p.meta.value("description").toString())) } };
            // this member's watch state (its own library item)
            const QJsonObject st = job.library.value(id).toObject();
            QStringList ids; for (const QJsonValue &x : p.meta.value("videos").toArray()) ids << x.toObject().value("id").toString();
            const QSet<QString> seen = Live::watched(st.value("watched").toString(), ids);
            const QString stCurrent = st.value("video_id").toString();
            const double offsetMs = st.value("timeOffset").toDouble(), duration = st.value("duration").toDouble();
            QVariantList mine;
            for (const QJsonValue &x : p.meta.value("videos").toArray()) {
                const QJsonObject e = x.toObject();
                const QString vid = p.film ? id : e.value("id").toString();
                const QString released = e.value("released").toString().left(10);
                mine << QVariantMap { { "id", vid }, { "episode", e.value("episode").toInt() }, { "title", p.film ? name : e.value("title").toString() },
                                      { "overview", p.film ? entries.last().toMap().value("description") : e.value("overview").toString() },
                                      { "released", released == "1970-01-01" ? QString() : released }, { "runtime", e.value("runtime").toString() },
                                      { "thumb", p.film ? p.meta.value("background").toString() : e.value("thumbnail").toString() },
                                      { "type", p.film ? "movie" : "series" }, { "entry", entry },
                                      { "watched", seen.contains(vid) }, { "progress", vid == stCurrent && duration > 0 ? qRound(1000 * offsetMs / duration) / 10.0 : 0 } };
                if (p.film) break;
            }
            if (mine.isEmpty()) continue;
            // where the page opens in the picked entry: the episode you were on in it (the next one if you'd
            // finished it), else its first
            if (p.kitsu == job.picked) {
                pickedFirst = mine.first().toMap().value("id").toString();
                for (int i = 0; i < mine.size(); i++) {
                    const QVariantMap e = mine[i].toMap();
                    if (e["id"].toString() != stCurrent) continue;
                    const bool finished = e["watched"].toBool() && e["progress"].toDouble() <= 0;
                    pickedFirst = (finished && i + 1 < mine.size() ? mine[i + 1] : mine[i]).toMap().value("id").toString();
                }
            }
            if (kind == "film") { QVariantMap f = mine.first().toMap(); f["episode"] = films.size() + 1; films << f; continue; }
            if (kind == "special") { for (const QVariant &m : mine) { QVariantMap e = m.toMap(); e["episode"] = specials.size() + 1; specials << e; } continue; }
            const int key = rank(p) == 1 ? p.tvdb : -1000 - p.kitsu;
            if (key != lastKey) close();
            lastKey = key;
            for (const QVariant &m : mine) { QVariantMap e = m.toMap(); e["episode"] = offset + e["episode"].toInt(); episodes << e; }
            offset += mine.size();
        }
        close();
        if (!films.isEmpty()) seasons << QVariantMap { { "season", 0 }, { "label", "Movies" }, { "kind", "films" }, { "episodes", films } };
        if (!specials.isEmpty()) seasons << QVariantMap { { "season", 0 }, { "label", "Specials" }, { "kind", "specials" }, { "episodes", specials } };
        QVariantMap item = job.source;
        item["id"] = "kitsu:" + QString::number(job.picked);
        if (item["video"].toString().isEmpty()) item["video"] = pickedFirst;
        QString year = cm.value("releaseInfo").toVariant().toString(); while (year.endsWith('-') || year.endsWith(QChar(0x2013))) year.chop(1);
        const QVariantMap show { { "name", cm.value("name").toString(item["name"].toString()) }, { "logo", showLogo }, { "backdrop", showBackdrop },
                                 { "description", clean(cm.value("description").toString(item["description"].toString())) },
                                 { "genres", cm.value("genres").toArray().toVariantList() }, { "year", year },
                                 { "rating", cm.value("imdbRating").toVariant().toString() }, { "current", current },
                                 { "entries", entries }, { "seasons", seasons } };
        return qMakePair(item, show);
    }
    // a show Kitsu doesn't have, from Cinemeta by its IMDb id (Torrentio answers IMDb seasons too)
    void cinemetaOnly(std::shared_ptr<Job> job, const QString &imdb) {
        if (imdb.isEmpty()) { emit failed(job->sourceId, "Not on Kitsu yet"); return; }
        get("https://v3-cinemeta.strem.io/meta/series/" + imdb + ".json", [this, job, imdb](const QByteArray &body, bool ok) {
            const QJsonObject meta = QJsonDocument::fromJson(body).object().value("meta").toObject();
            if (!ok || meta.isEmpty()) { emit failed(job->sourceId, "Couldn't load its episodes"); return; }
            QJsonObject s = Live::show(meta, m_library.value(imdb).toObject());
            QVariantMap show = s.toVariantMap();
            show["logo"] = meta.value("logo").toString(); show["backdrop"] = meta.value("background").toString();
            QVariantMap item = job->source; item["id"] = imdb;
            emit ready(job->sourceId, item, show);
        });
    }
};
