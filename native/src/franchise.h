#pragma once
// Franchise: an anime as one show however it's reached (an AniList id from the Anime tab, a Kitsu id from
// Continue Watching or the calendar), with every season, part, film and special as an entry of its own: its
// English title, logo, backdrop, poster, description, year and score. docs/anime-seasons.md has the survey
// behind it.
//  1. ARM maps the id to Kitsu, AniList and the TVDB show, then lists the show's entries with their TVDB
//     season (0: specials and films; none: a long runner Kitsu keeps whole).
//  2. AniList's SEQUEL links from the newest season add seasons ARM can't place yet; an entry with no TVDB
//     show of its own (a film ARM never mapped, as Dragon Ball Super: Super Hero) joins the show of its
//     AniList prequel or sequel, and so do unmapped films and specials linked to any of the show's entries.
//  3. In parallel: each entry's Kitsu meta (episodes, logo, backdrop, poster, year), AniList for all the
//     entries at once (English titles, scores, descriptions), and Cinemeta for the franchise (its name, logo,
//     backdrop).
//  4. Seasons: long runners first, the TVDB seasons in order (split parts joined, numbered on), unplaced
//     sequels, then Movies and Specials. Every episode names its entry, and an entry without its own logo or
//     backdrop takes the franchise's.
//  Related: the other series AniList links to its entries that TVDB keeps as shows of their own (Naruto to
//  Shippuden, Dragon Ball Super to Daima and its remake), for the page to link to.
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
            if (tvdb) show(job, tvdb, ids); else adopt(job, ids);
        });
    }
signals:
    void ready(const QString &sourceId, const QVariantMap &item, const QVariantMap &show);
    void failed(const QString &sourceId, const QString &reason);

private:
    struct Job {
        QVariantMap source; QString sourceId, imdb; int picked = 0, tail = 0, pending = 0, tvdb = 0; QVariantList related;
        QJsonArray entries; QHash<int, QJsonObject> kitsu; QHash<int, QJsonObject> anilist; QJsonObject cinemeta; QJsonObject library;
        QVector<int> relatedKitsu;                       // the related shows' Kitsu ids, their metas in `kitsu` too
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

    static bool shortForm(const QString &format) { return format == "MOVIE" || format == "OVA" || format == "SPECIAL"; }
    // the TVDB show's entries (ARM), with `ids` among them if ARM doesn't list it there (a film or special as
    // a special, anything else after the seasons)
    void show(std::shared_ptr<Job> job, int tvdb, QJsonObject ids) {
        job->tvdb = tvdb;
        get("https://arm.haglund.dev/api/v2/thetvdb?id=" + QString::number(tvdb), [this, job, ids](const QByteArray &body, bool ok) mutable {
            job->entries = ok ? QJsonDocument::fromJson(body).array() : QJsonArray();
            bool has = false; int best = -1;
            // the franchise's name and art are the show's (Cinemeta by a season's IMDb id), not a film's
            for (const QJsonValue &v : job->entries) if (v.toObject().value("thetvdb-season").toInt(0) != 0 || v.toObject().value("thetvdb-season").isNull())
                if (!v.toObject().value("imdb").toString().isEmpty()) { job->imdb = v.toObject().value("imdb").toString(); break; }
            for (const QJsonValue &v : job->entries) {
                const QJsonObject e = v.toObject();
                has = has || e.value("kitsu").toInt() == job->picked;
                if (job->imdb.isEmpty()) job->imdb = e.value("imdb").toString();
                const int season = e.value("thetvdb-season").toInt(-1);
                if (season > best && e.value("anilist").toInt()) { best = season; job->tail = e.value("anilist").toInt(); }
            }
            if (!has) {
                if (ids.value("thetvdb").toInt() != job->tvdb) { if (shortForm(ids.value("media").toString())) ids["thetvdb-season"] = 0; else ids["appended"] = true; }
                job->entries.append(ids);
            }
            if (!job->tail) job->tail = ids.value("anilist").toInt();
            sequels(job, 0);
        });
    }
    // no TVDB show of its own: the show of what it belongs to on AniList, by its parent, then what it follows,
    // then what follows it, then a side story's; only released ones (a film can't follow a show that hasn't
    // aired: AniList puts Super Hero after the unreleased Galactic Patrol). Failing those, the TV anime of
    // its source (Super Hero's manga is Dragon Ball Super's).
    void adopt(std::shared_ptr<Job> job, QJsonObject ids) {
        const int anilist = ids.value("anilist").toInt();
        auto alone = [this, job, ids] { job->entries = QJsonArray { ids }; job->tail = ids.value("anilist").toInt(); sequels(job, 0); };
        if (!anilist) { alone(); return; }
        send("https://graphql.anilist.co", graphql("{ Media(id:" + QString::number(anilist) + "){ relations{ edges{ relationType node{ id type format status "
                                                    "relations{ edges{ relationType node{ id type format status } } } } } } } }"),
             [this, job, ids, alone](const QByteArray &body, bool) {
            static const QStringList order { "PARENT", "PREQUEL", "SEQUEL", "SIDE_STORY" };
            auto released = [](const QJsonObject &n) { return n.value("type").toString() == "ANIME" && n.value("status").toString() != "NOT_YET_RELEASED" && n.value("status").toString() != "CANCELLED"; };
            QVector<QPair<int, int>> ranked;                                  // (preference, AniList id)
            for (const QJsonValue &v : QJsonDocument::fromJson(body).object().value("data").toObject().value("Media").toObject().value("relations").toObject().value("edges").toArray()) {
                const QJsonObject e = v.toObject(), n = e.value("node").toObject();
                const int rank = order.indexOf(e.value("relationType").toString());
                if (rank >= 0 && released(n)) ranked << qMakePair(rank, n.value("id").toInt());
                // its source (a manga, a novel): that source's TV anime, after all of the above
                if (e.value("relationType").toString() == "ADAPTATION" || e.value("relationType").toString() == "SOURCE")
                    for (const QJsonValue &w : n.value("relations").toObject().value("edges").toArray()) {
                        const QJsonObject m = w.toObject().value("node").toObject();
                        const QString f = m.value("format").toString();
                        if (released(m) && (f == "TV" || f == "TV_SHORT" || f == "ONA") && m.value("id").toInt() != ids.value("anilist").toInt()) ranked << qMakePair(order.size(), m.value("id").toInt());
                    }
            }
            if (ranked.isEmpty()) { alone(); return; }
            std::stable_sort(ranked.begin(), ranked.end(), [](const QPair<int, int> &a, const QPair<int, int> &b) { return a.first < b.first; });
            QJsonArray ask; for (const auto &r : ranked) ask << QJsonObject { { "anilist", r.second } };
            send("https://arm.haglund.dev/api/v2/ids", QJsonDocument(ask).toJson(QJsonDocument::Compact), [this, job, ids, alone](const QByteArray &body, bool) {
                for (const QJsonValue &v : QJsonDocument::fromJson(body).array())                // in the order asked
                    if (const int host = v.toObject().value("thetvdb").toInt()) { show(job, host, ids); return; }
                alone();
            });
        });
    }
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
        auto done = [this, job] { if (--job->pending == 0) extras(job); };
        for (int k : kitsu)
            get("https://anime-kitsu.strem.fun/meta/series/kitsu:" + QString::number(k) + ".json", [job, k, done](const QByteArray &body, bool ok) {
                if (ok) job->kitsu[k] = QJsonDocument::fromJson(body).object().value("meta").toObject();
                done();
            });
        send("https://graphql.anilist.co", graphql("{ Page(perPage:50){ media(id_in:[" + anilist.join(',') + "]){ id title{ english romaji } averageScore description(asHtml:false) "
                    "relations{ edges{ relationType node{ id type format title{ english romaji } coverImage{ large } } } } } } }"),
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
    // What AniList links to the entries that ARM doesn't place in this show: unmapped films and specials join
    // it (their Kitsu metas fetched too), other series are its related shows. Then the show.
    void extras(std::shared_ptr<Job> job) {
        QSet<int> known; for (const QJsonValue &v : job->entries) known << v.toObject().value("anilist").toInt();
        QHash<int, QJsonObject> nodes; QHash<int, QString> relation; QJsonArray ask;
        for (const QJsonObject &a : job->anilist)
            for (const QJsonValue &v : a.value("relations").toObject().value("edges").toArray()) {
                const QJsonObject e = v.toObject(), n = e.value("node").toObject();
                const int id = n.value("id").toInt();
                if (n.value("type").toString() != "ANIME" || known.contains(id) || nodes.contains(id)) continue;
                const QString r = e.value("relationType").toString();
                const bool film = shortForm(n.value("format").toString()) && (r == "PREQUEL" || r == "SEQUEL" || r == "SIDE_STORY" || r == "PARENT");
                const bool series = !shortForm(n.value("format").toString()) && (r == "PREQUEL" || r == "SEQUEL" || r == "SPIN_OFF" || r == "ALTERNATIVE" || r == "SIDE_STORY" || r == "PARENT");
                if (!film && !series) continue;
                nodes[id] = n; relation[id] = r; ask << QJsonObject { { "anilist", id } };
            }
        if (ask.isEmpty()) { finish(job); return; }
        send("https://arm.haglund.dev/api/v2/ids", QJsonDocument(ask).toJson(QJsonDocument::Compact), [this, job, nodes, relation](const QByteArray &body, bool) {
            const QJsonArray ids = QJsonDocument::fromJson(body).array();
            QVector<int> fetch; QSet<int> shows;
            for (const QJsonValue &v : ids) {
                QJsonObject e = v.toObject();
                const int a = e.value("anilist").toInt(), k = e.value("kitsu").toInt(), tv = e.value("thetvdb").toInt();
                if (!nodes.contains(a)) continue;
                const QJsonObject n = nodes[a];
                if (shortForm(n.value("format").toString())) {
                    if (tv || !k) continue;                                   // another show's, or not playable
                    e["thetvdb-season"] = 0; e["media"] = n.value("format").toString();
                    job->entries.append(e); fetch << k;
                } else if (k && tv != job->tvdb && !(tv && shows.contains(tv))) {     // another show, playable
                    if (tv) shows << tv;
                    const QJsonObject t = n.value("title").toObject();
                    job->related << QVariantMap { { "id", "kitsu:" + QString::number(k) }, { "title", t.value("english").toString(t.value("romaji").toString()) },
                                                  { "poster", n.value("coverImage").toObject().value("large").toString() }, { "relation", relation[a] } };
                    job->relatedKitsu << k; fetch << k;
                }
            }
            if (fetch.isEmpty()) { finish(job); return; }
            job->pending = fetch.size();
            for (int k : fetch)
                get("https://anime-kitsu.strem.fun/meta/series/kitsu:" + QString::number(k) + ".json", [this, job, k](const QByteArray &body, bool ok) {
                    if (ok) job->kitsu[k] = QJsonDocument::fromJson(body).object().value("meta").toObject();
                    if (--job->pending == 0) finish(job);
                });
        });
    }
    void finish(std::shared_ptr<Job> job) {
        if (!job->kitsu.contains(job->picked)) { emit failed(job->sourceId, "Couldn't load its episodes"); return; }
        job->library = m_library;
        auto out = std::make_shared<QPair<QVariantMap, QVariantMap>>();
        QThread *worker = QThread::create([out, job] { *out = build(*job); });
        connect(worker, &QThread::finished, this, [this, out, job] { emit ready(job->sourceId, out->first, out->second); });
        connect(worker, &QThread::finished, worker, &QObject::deleteLater);
        worker->start();
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
                // `number`: its place in its own entry (a calendar release names its episode so); `episode` becomes
                // its number in the season the entry is joined into
                mine << QVariantMap { { "id", vid }, { "episode", e.value("episode").toInt() }, { "number", e.value("episode").toInt() }, { "title", p.film ? name : e.value("title").toString() },
                                      { "overview", p.film ? entries.last().toMap().value("description") : e.value("overview").toString() },
                                      { "released", released == "1970-01-01" ? QString() : released }, { "runtime", e.value("runtime").toString() },
                                      { "thumb", p.film ? p.meta.value("background").toString() : e.value("thumbnail").toString() },
                                      { "type", p.film ? "movie" : "series" }, { "entry", entry }, { "poster", p.film ? p.meta.value("poster").toString() : QString() },
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
        // Related: the other shows AniList links (each an entry too, so the page wears it when it's focused)
        QVariantList related;
        for (const QVariant &v : job.related) {
            const QVariantMap r = v.toMap();
            const QJsonObject m = job.kitsu.value(r["id"].toString().section(':', 1).toInt());
            if (m.isEmpty()) continue;
            const int entry = entries.size();
            entries << QVariantMap { { "id", r["id"] }, { "kind", "related" }, { "title", r["title"] }, { "logo", m.value("logo").toString() },
                                     { "backdrop", m.value("background").toString() }, { "poster", r["poster"] }, { "year", m.value("year").toVariant().toString() },
                                     { "runtime", QString() }, { "genres", m.value("genres").toArray().toVariantList() },
                                     { "rating", m.value("imdbRating").toVariant().toString() }, { "description", clean(m.value("description").toString()) },
                                     { "episodes", m.value("videos").toArray().size() } };
            related << QVariantMap { { "id", r["id"] }, { "type", "show" }, { "relation", r["relation"] }, { "episode", related.size() + 1 }, { "title", r["title"] },
                                     { "thumb", m.value("background").toString() }, { "poster", r["poster"] }, { "overview", clean(m.value("description").toString()) },
                                     { "released", QString() }, { "entry", entry } };
        }
        if (!related.isEmpty()) seasons << QVariantMap { { "season", 0 }, { "label", "Related" }, { "kind", "related" }, { "episodes", related } };
        QVariantMap item = job.source;
        item["id"] = "kitsu:" + QString::number(job.picked);
        if (item["video"].toString().isEmpty()) item["video"] = pickedFirst;
        QString year = cm.value("releaseInfo").toVariant().toString(); while (year.endsWith('-') || year.endsWith(QChar(0x2013))) year.chop(1);
        const QVariantMap show { { "name", cm.value("name").toString(item["name"].toString()) }, { "logo", showLogo }, { "backdrop", showBackdrop },
                                 { "imdb", job.imdb },             // the series there, whose seasons the numbered ones here follow
                                 { "description", clean(cm.value("description").toString(item["description"].toString())) },
                                 { "genres", cm.value("genres").toArray().toVariantList() }, { "year", year },
                                 { "rating", cm.value("imdbRating").toVariant().toString() }, { "current", current },
                                 { "entries", entries }, { "seasons", seasons }, { "related", job.related } };
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
