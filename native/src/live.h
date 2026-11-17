#pragma once
// Live: everything the catalog shows, fetched when the app starts, from the services themselves. Nothing is
// baked into the app. The one stand-in is the Stremio account: until the app signs in, its continue-watching
// list and library state are the Stremio core's own files (cw.out.json, library_recent.json), copied from
// the TV's core probe by tools/fetch-library.sh into app/stremio/.
//   rows     Cinemeta's top movies and series; posters, backdrops and logos from metahub
//   cw       Stremio's continue-watching list, each title's art and facts from Cinemeta or the Kitsu addon
//   series   those shows' episodes, from the same metas, with watch state from Stremio's (the watched bitfield)
//   season   AniList's current season and the shows still airing from earlier ones (AniChart's leftovers),
//            each with its Kitsu fanart and logo (ARM maps AniList to Kitsu)
//   airing   the calendar's anime: those shows' episode air times (AniList, in the same pages)
// The documents keep the shapes the catalog parses (Catalog::Data::load).
//
// The Mac's visual check needs the same data every run: with SEIMIO_REPLAY set to a folder, answers come from
// recordings there (by request), and SEIMIO_RECORD=1 records what's missing (tools/preview/shots.sh --record).
// The app on the TV never sets them.
#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QRegularExpression>
#include <QSet>
#include <QTimer>
#include <QUrl>
#include <functional>
#include <memory>

class Live : public QObject {
    Q_OBJECT
public:
    // `library`: every Stremio library item's state by id (where you are, the watched bitfield, when last
    // watched), for anything that needs watch state beyond Continue Watching (a franchise's other seasons)
    struct Docs { QJsonArray cw, rows, airing; QJsonObject series, season, library; };
    explicit Live(QObject *parent = nullptr) : QObject(parent) {}

    // Home's documents (rows, cw, series, and the calendar's anime from the season pages), then `home`; the
    // season's art (a Kitsu meta a show) after, then `anime`: each screen gets its data whole, once
    void fetch(const QString &stremioDir, std::function<void(Docs)> home, std::function<void(Docs)> anime) {
        auto docs = std::make_shared<Docs>();
        auto homeLeft = std::make_shared<int>(3);
        auto homeDone = [docs, homeLeft, home] { if (--*homeLeft == 0) home(*docs); };
        rows(docs, homeDone);
        continueWatching(stremioDir, docs, homeDone);
        season(docs, homeDone, [docs, anime] { anime(*docs); });
    }

private:
    QNetworkAccessManager m_net { this };
    static constexpr const char *kCinemeta = "https://v3-cinemeta.strem.io";
    static constexpr const char *kKitsu = "https://anime-kitsu.strem.fun";

    // every request goes through here: GET when `body` is empty, else a JSON POST; `done(body, ok, status)`
    void request(const QString &url, const QByteArray &body, std::function<void(const QByteArray &, bool, int)> done) {
        static const QString replay = qEnvironmentVariable("SEIMIO_REPLAY");
        const QString file = replay.isEmpty() ? QString() : replay + "/" + QCryptographicHash::hash(url.toUtf8() + body, QCryptographicHash::Sha1).toHex() + ".json";
        if (!file.isEmpty()) {
            QFile f(file);
            if (f.open(QIODevice::ReadOnly)) { const QByteArray data = f.readAll(); QTimer::singleShot(0, this, [done, data] { done(data, true, 200); }); return; }
            if (qEnvironmentVariableIsEmpty("SEIMIO_RECORD")) { QTimer::singleShot(0, this, [done] { done(QByteArray(), false, 0); }); return; }
        }
        QNetworkRequest r { QUrl(url) };
        r.setHeader(QNetworkRequest::UserAgentHeader, "seimio/0.1");
        r.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
        if (!body.isEmpty()) { r.setHeader(QNetworkRequest::ContentTypeHeader, "application/json"); r.setRawHeader("Accept", "application/json"); }
        QNetworkReply *reply = body.isEmpty() ? m_net.get(r) : m_net.post(r, body);
        QTimer::singleShot(20000, reply, &QNetworkReply::abort);
        connect(reply, &QNetworkReply::finished, this, [reply, done, file] {
            reply->deleteLater();
            const QByteArray data = reply->readAll();
            const bool ok = reply->error() == QNetworkReply::NoError;
            if (ok && !file.isEmpty()) { QDir().mkpath(QFileInfo(file).path()); QFile f(file); if (f.open(QIODevice::WriteOnly)) f.write(data); }
            done(data, ok, reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt());
        });
    }
    void get(const QString &url, std::function<void(const QJsonDocument &, bool)> done) {
        request(url, QByteArray(), [done](const QByteArray &data, bool ok, int) { done(QJsonDocument::fromJson(data), ok); });
    }
    // AniList's GraphQL; a 429 (about 30 requests a minute) waits a little and tries again
    void anilist(const QByteArray &query, const QJsonObject &variables, std::function<void(const QJsonObject &)> done, int attempt = 0) {
        const QByteArray body = QJsonDocument(QJsonObject { { "query", QString::fromUtf8(query) }, { "variables", variables } }).toJson(QJsonDocument::Compact);
        request("https://graphql.anilist.co", body, [this, query, variables, done, attempt](const QByteArray &data, bool, int status) {
            if (status == 429 && attempt < 3) {
                QTimer::singleShot(20000, this, [this, query, variables, done, attempt] { anilist(query, variables, done, attempt + 1); });
                return;
            }
            done(QJsonDocument::fromJson(data).object().value("data").toObject());
        });
    }
    static QString metahub(const QString &kind, const QString &id) { return "https://images.metahub.space/" + kind + "/medium/" + id + "/img"; }
    static QJsonArray firstN(const QJsonArray &a, int n) { QJsonArray out; for (int i = 0; i < a.size() && i < n; i++) out << a[i]; return out; }

    // ---- Home ----------------------------------------------------------------------------------------------
    void rows(std::shared_ptr<Docs> docs, std::function<void()> done) {
        auto left = std::make_shared<int>(2);
        auto rows = std::make_shared<QVector<QJsonObject>>(2);
        const QStringList kinds { "movie", "series" }, titles { "Popular movies", "Popular series" };
        for (int k = 0; k < 2; k++)
            get(QString(kCinemeta) + "/catalog/" + kinds[k] + "/top.json", [=](const QJsonDocument &d, bool) {
                QJsonArray items;
                for (const QJsonValue &v : d.object().value("metas").toArray()) {
                    const QJsonObject m = v.toObject();
                    if (m.value("poster").toString().isEmpty() || m.value("background").toString().isEmpty()) continue;
                    const QString id = m.value("id").toString();
                    items << QJsonObject { { "id", id }, { "name", m.value("name") }, { "year", m.value("releaseInfo").toVariant().toString() },
                                           { "genres", firstN(m.value("genres").toArray(), 2) }, { "rating", m.value("imdbRating").toVariant().toString() },
                                           { "runtime", m.value("runtime") }, { "description", m.value("description").toString().left(220) },
                                           { "poster", metahub("poster", id) }, { "backdrop", metahub("background", id) }, { "logo", metahub("logo", id) } };
                    if (items.size() == 14) break;
                }
                (*rows)[k] = QJsonObject { { "title", titles[k] }, { "items", items } };
                if (--*left == 0) { docs->rows = QJsonArray { (*rows)[0], (*rows)[1] }; done(); }
            });
    }
    // Stremio's list (the stand-in for the account), each title's meta live; a show's meta also gives its
    // episodes, with Stremio's watch state laid over them
    void continueWatching(const QString &dir, std::shared_ptr<Docs> docs, std::function<void()> done) {
        auto read = [&dir](const QString &name) { QFile f(dir + "/" + name); return f.open(QIODevice::ReadOnly) ? QJsonDocument::fromJson(f.readAll()) : QJsonDocument(); };
        const QJsonArray list = firstN(read("cw.out.json").array(), 10);
        QHash<QString, QJsonObject> library;
        const QJsonDocument lib = read("library_recent.json");
        const QJsonValue items = lib.isObject() && lib.object().contains("items") ? lib.object().value("items") : (lib.isArray() ? QJsonValue(lib.array()) : QJsonValue(lib.object()));
        auto add = [&library](const QJsonValue &v) { const QJsonObject i = v.toObject(); library[i.value("_id").toString()] = i.value("state").toObject(); };
        if (items.isArray()) for (const QJsonValue &v : items.toArray()) add(v); else for (const QJsonValue &v : items.toObject()) add(v);
        for (auto it = library.begin(); it != library.end(); ++it) docs->library[it.key()] = it.value();
        if (list.isEmpty()) { done(); return; }
        auto left = std::make_shared<int>(list.size());
        auto out = std::make_shared<QVector<QJsonObject>>(list.size());
        for (int n = 0; n < list.size(); n++) {
            const QJsonObject i = list[n].toObject();
            const QString id = i.value("id").toString(), type = i.value("type").toString();
            get((id.startsWith("kitsu:") ? QString(kKitsu) : QString(kCinemeta)) + "/meta/" + type + "/" + id + ".json", [=](const QJsonDocument &d, bool) {
                const QJsonObject m = d.object().value("meta").toObject();
                const QString vid = i.value("videoId").toString();
                const QStringList parts = vid.split(':');
                QString episode;
                if (type == "series" && parts.size() == 3) episode = id.startsWith("kitsu:") ? "E" + parts[2] : "S" + parts[1] + " E" + parts[2];
                const QString backdrop = m.value("background").toString(id.startsWith("tt") ? metahub("background", id) : QString());
                const QString logo = m.value("logo").toString(id.startsWith("tt") ? metahub("logo", id) : QString());
                (*out)[n] = QJsonObject { { "id", id }, { "name", i.value("name") }, { "type", type }, { "episode", episode },
                                          { "progress", qRound(i.value("progress").toDouble() * 10) / 10.0 }, { "backdrop", backdrop }, { "logo", logo },
                                          { "description", m.value("description").toString().left(220) }, { "genres", firstN(m.value("genres").toArray(), 2) },
                                          { "year", m.value("releaseInfo").toVariant().toString() } };
                if (type == "series" && !m.isEmpty()) docs->series[id] = show(m, library.value(id));
                if (--*left) return;
                for (const QJsonObject &o : *out) docs->cw << o;
                done();
            });
        }
    }
public:
    // a show's seasons from its meta: watched episodes from Stremio's bitfield, progress on the current one
    static QJsonObject show(const QJsonObject &meta, const QJsonObject &state) {
        QVector<QJsonObject> videos;
        for (const QJsonValue &v : meta.value("videos").toArray()) videos << v.toObject();
        auto num = [](const QJsonObject &v, const char *k) { return v.value(k).toVariant().toInt(); };
        std::stable_sort(videos.begin(), videos.end(), [&num](const QJsonObject &a, const QJsonObject &b) {
            const int sa = num(a, "season"), sb = num(b, "season");
            return sa != sb ? sa < sb : qMax(num(a, "episode"), num(a, "number")) < qMax(num(b, "episode"), num(b, "number"));
        });
        QStringList ids; for (const QJsonObject &v : videos) ids << v.value("id").toString();
        const QSet<QString> seen = watched(state.value("watched").toString(), ids);
        const QString current = state.value("video_id").toString();
        const double offset = state.value("timeOffset").toDouble(), duration = state.value("duration").toDouble();
        QMap<int, QJsonArray> seasons;
        for (const QJsonObject &v : videos) {
            const int s = num(v, "season"), e = qMax(num(v, "episode"), num(v, "number"));
            if (s == 0 && !meta.value("id").toString().startsWith("kitsu:")) continue;          // Cinemeta's specials
            const QString id = v.value("id").toString();
            QString released = v.value("released").toString(); if (released.isEmpty()) released = v.value("firstAired").toString();
            seasons[qMax(1, s)] << QJsonObject { { "id", id }, { "episode", e }, { "title", v.value("title").toString(v.value("name").toString()) },
                                                 { "overview", v.value("overview").toString().left(260) }, { "released", released.left(10) },
                                                 { "runtime", v.value("runtime").toString(meta.value("runtime").toString()) }, { "thumb", v.value("thumbnail").toString() },
                                                 { "watched", seen.contains(id) }, { "progress", id == current && duration > 0 ? qRound(1000 * offset / duration) / 10.0 : 0 } };
        }
        QJsonArray list;
        for (auto it = seasons.begin(); it != seasons.end(); ++it) list << QJsonObject { { "season", it.key() }, { "episodes", it.value() } };
        QString year = meta.value("releaseInfo").toVariant().toString(); if (year.isEmpty()) year = meta.value("year").toVariant().toString();
        while (year.endsWith('-') || year.endsWith(QChar(0x2013))) year.chop(1);
        return QJsonObject { { "name", meta.value("name") }, { "current", current }, { "description", meta.value("description").toString().left(260) },
                             { "genres", firstN(meta.value("genres").toArray(), 2) }, { "year", year },
                             { "rating", meta.value("imdbRating").toVariant().toString() }, { "seasons", list } };
    }
    // Stremio's watched bitfield, "anchorId:anchorLength:base64(zlib(bits))": bit i is the i-th video in
    // season-then-episode order, shifted so the anchor video sits at anchorLength - 1
    static QSet<QString> watched(const QString &field, const QStringList &ids) {
        QSet<QString> out;
        const QStringList parts = field.split(':');
        if (parts.size() < 3) return out;
        const QByteArray z = QByteArray::fromBase64(parts.last().toLatin1());
        QByteArray sized(4, '\0'); const quint32 hint = quint32(qMax(64, z.size() * 64));
        sized[0] = char(hint >> 24); sized[1] = char(hint >> 16); sized[2] = char(hint >> 8); sized[3] = char(hint);
        const QByteArray bits = qUncompress(sized + z);
        const int anchorLen = parts[parts.size() - 2].toInt();
        const int anchor = ids.indexOf(parts.mid(0, parts.size() - 2).join(':'));
        if (anchor < 0 || bits.isEmpty()) return out;
        const int shift = anchorLen - anchor - 1;
        for (int i = 0; i < ids.size(); i++) {
            const int b = i + shift;
            if (b >= 0 && b < bits.size() * 8 && (uchar(bits[b / 8]) >> (b % 8) & 1)) out << ids[i];
        }
        return out;
    }
private:

    // ---- the Anime tab ---------------------------------------------------------------------------------------
    // AniList's season now (Winter is December to February), as AniChart lists it: the season's shows from
    // 3000 members up, and the ones still airing from earlier seasons from 9000 up (TV, TV short, ONA)
    void season(std::shared_ptr<Docs> docs, std::function<void()> listed, std::function<void()> done) {
        const QDate today = QDate::currentDate();
        const int m = today.month();
        const QString name = m == 12 || m <= 2 ? "WINTER" : m <= 5 ? "SPRING" : m <= 8 ? "SUMMER" : "FALL";
        const int year = m == 12 ? today.year() + 1 : today.year();
        static const QByteArray fields = "id isAdult popularity averageScore format episodes duration status source "
            "title { romaji english } bannerImage coverImage { extraLarge color } description(asHtml: false) genres "
            "studios(isMain: true) { nodes { name } } startDate { year month day } nextAiringEpisode { episode airingAt } "
            "airingSchedule(perPage: 50) { nodes { episode airingAt } }";
        const QByteArray seasonQ = "query ($page: Int, $season: MediaSeason, $year: Int) { Page(page: $page, perPage: 50) { pageInfo { hasNextPage } media(season: $season, seasonYear: $year, type: ANIME, sort: POPULARITY_DESC) { " + fields + " } } }";
        const QByteArray leftoverQ = "query ($page: Int) { Page(page: $page, perPage: 50) { pageInfo { hasNextPage } media(status: RELEASING, type: ANIME, sort: POPULARITY_DESC) { " + fields + " } } }";
        auto shows = std::make_shared<QJsonArray>();
        auto seen = std::make_shared<QSet<int>>();
        auto take = [shows, seen](const QJsonObject &md, bool leftover) {
            const int id = md.value("id").toInt();
            const QString format = md.value("format").toString();
            if (md.value("isAdult").toBool() || seen->contains(id) || (leftover && format != "TV" && format != "TV_SHORT" && format != "ONA")) return;
            seen->insert(id);
            const QJsonObject title = md.value("title").toObject(), start = md.value("startDate").toObject(), next = md.value("nextAiringEpisode").toObject();
            QStringList studios; for (const QJsonValue &n : md.value("studios").toObject().value("nodes").toArray()) if (studios.size() < 2) studios << n.toObject().value("name").toString();
            QString description = md.value("description").toString();
            description.replace(QRegularExpression("<[^>]+>|\\(Source:[^)]*\\)"), " ");
            description = description.simplified().left(320);
            QJsonArray airing; for (const QJsonValue &n : md.value("airingSchedule").toObject().value("nodes").toArray()) airing << n;
            shows->append(QJsonObject {
                { "id", "anilist:" + QString::number(id) }, { "anilist", id }, { "name", title.value("english").toString(title.value("romaji").toString()) },
                { "format", format }, { "episodes", md.value("episodes").toInt() }, { "duration", md.value("duration").toInt() },
                { "studio", studios.join(", ") }, { "genres", firstN(md.value("genres").toArray(), 4) }, { "score", md.value("averageScore").toInt() },
                { "popularity", md.value("popularity").toInt() }, { "leftover", leftover },
                { "start", QString("%1-%2-%3").arg(start.value("year").toInt(), 4, 10, QChar('0')).arg(start.value("month").toInt(), 2, 10, QChar('0')).arg(start.value("day").toInt(), 2, 10, QChar('0')) },
                { "next", next.isEmpty() ? QJsonValue() : QJsonValue(QJsonObject { { "episode", next.value("episode") }, { "at", next.value("airingAt") } }) },
                { "color", md.value("coverImage").toObject().value("color").toString() }, { "cover", md.value("coverImage").toObject().value("extraLarge").toString() },
                { "banner", md.value("bannerImage").toString() }, { "description", description }, { "airing", airing } });
        };
        // pages until the popularity falls under the floor
        auto pages = std::make_shared<std::function<void(QByteArray, QJsonObject, int, int, bool, std::function<void()>)>>();
        *pages = [this, take, pages](QByteArray q, QJsonObject vars, int page, int floor, bool leftover, std::function<void()> then) {
            vars["page"] = page;
            anilist(q, vars, [=](const QJsonObject &data) {
                const QJsonObject p = data.value("Page").toObject();
                bool more = p.value("pageInfo").toObject().value("hasNextPage").toBool();
                for (const QJsonValue &v : p.value("media").toArray()) {
                    if (v.toObject().value("popularity").toInt() < floor) { more = false; break; }
                    take(v.toObject(), leftover);
                }
                if (more && page < 8) (*pages)(q, vars, page + 1, floor, leftover, then); else then();
            });
        };
        (*pages)(seasonQ, QJsonObject { { "season", name }, { "year", year } }, 1, 3000, false, [=] {
            (*pages)(leftoverQ, QJsonObject(), 1, 9000, true, [=] {
                docs->season = QJsonObject { { "season", name }, { "year", year } };
                docs->airing = airingOf(*shows);
                listed();
                art(shows, [docs, shows, done] { QJsonObject s = docs->season; s["shows"] = *shows; docs->season = s; done(); });
            });
        });
    }
    // the calendar's anime: every episode's air time (local date and time), with the show's banner or cover
    static QJsonArray airingOf(const QJsonArray &shows) {
        QJsonArray out;
        for (const QJsonValue &v : shows) {
            const QJsonObject s = v.toObject();
            const QString art = s.value("banner").toString(s.value("cover").toString());
            for (const QJsonValue &n : s.value("airing").toArray()) {
                const QDateTime at = QDateTime::fromSecsSinceEpoch(n.toObject().value("airingAt").toVariant().toLongLong());
                out << QJsonObject { { "id", s.value("id") }, { "name", s.value("name") }, { "episode", n.toObject().value("episode") },
                                     { "date", at.toString("yyyy-MM-dd") }, { "time", at.toString("HH:mm") }, { "art", art },
                                     { "description", s.value("description").toString().left(260) } };
            }
        }
        return out;
    }
    // each show's full-screen fanart and logo: ARM maps AniList to Kitsu (100 at a time), the Kitsu addon has them
    void art(std::shared_ptr<QJsonArray> shows, std::function<void()> done) {
        if (shows->isEmpty()) { done(); return; }
        auto left = std::make_shared<int>(0);
        auto finish = [left, done] { if (--*left == 0) done(); };
        for (int from = 0; from < shows->size(); from += 100) {
            QJsonArray ask;
            for (int i = from; i < shows->size() && i < from + 100; i++) ask << QJsonObject { { "anilist", (*shows)[i].toObject().value("anilist") } };
            ++*left;
            request("https://arm.haglund.dev/api/v2/ids", QJsonDocument(ask).toJson(QJsonDocument::Compact), [this, shows, from, left, finish](const QByteArray &data, bool, int) {
                const QJsonArray ids = QJsonDocument::fromJson(data).array();
                for (int k = 0; k < ids.size(); k++) {
                    const int kitsu = ids[k].toObject().value("kitsu").toInt();
                    if (!kitsu) continue;
                    ++*left;
                    const int at = from + k;
                    get(QString(kKitsu) + "/meta/series/kitsu:" + QString::number(kitsu) + ".json", [shows, at, finish](const QJsonDocument &d, bool) {
                        const QJsonObject m = d.object().value("meta").toObject();
                        QJsonObject s = (*shows)[at].toObject();
                        s["background"] = m.value("background").toString();
                        s["logo"] = m.value("logo").toString();
                        (*shows)[at] = s;
                        finish();
                    });
                }
                finish();
            });
        }
    }
};
