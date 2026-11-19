#pragma once
// Live: everything the catalog shows, fetched when the app starts, from the services themselves. Nothing is
// baked into the app. The account's part (Continue Watching, every library item's watch state) comes from
// Stremio's core (core.h).
//   rows     Cinemeta's top movies and series; posters, backdrops and logos from metahub
//   cw       Stremio's continue-watching list and the library's other shows (`kept`), each title's art and
//            facts from Cinemeta or the Kitsu addon; `library`: it is in the library (a title can be watched
//            without being added)
//   series   those shows' episodes, from the same metas, with watch state from Stremio's (the watched bitfield)
//   season   AniList's current season and the shows still airing from earlier ones (AniChart's leftovers),
//            each with its Kitsu fanart and logo (ARM maps AniList to Kitsu)
//   airing   when those shows' episodes air (AniList, in the same pages), by the episode's id as Stremio has
//            it: the calendar's library anime take their air time from it
// The documents keep the shapes the catalog parses (Catalog::Data::load). Requests go through Net and the
// data thread's query cache (query.h): one fetch for an address asked twice at once, a failure tried
// again before it counts, and recordings in place of the network for the Mac's visual check.
#include <QDateTime>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QSet>
#include <functional>
#include <memory>
#include "core.h"
#include "pictures.h"
#include "resting.h"

class Live : public QObject {
    Q_OBJECT
public:
    // `library`: every Stremio library item's state by id (where you are, the watched bitfield, when last
    // watched), for anything that needs watch state beyond Continue Watching (a franchise's other seasons)
    struct Docs { QJsonArray cw, rows; QJsonObject series, season, library, airing; };
    // `cache`: the data thread's, which Franchise shares (a title's meta asked for by both is fetched once)
    explicit Live(query::Queries *cache, QObject *parent = nullptr) : QObject(parent), m_cache(cache), m_net(cache, this) {}

    // Home's documents, whole: rows, cw, series and library, and the calendar's anime from the season's
    // list (`airing`). Asked again (the account changed), only Continue Watching's part is new work: the
    // rows and the season's list are queries that stay fresh for hours, and each title's meta for ten
    // minutes.
    void home(std::function<void(Docs)> done) {
        auto docs = std::make_shared<Docs>();
        auto left = std::make_shared<int>(3);
        auto finish = [docs, left, done] { if (--*left == 0) done(*docs); };
        rows(docs, finish);
        continueWatching(docs, finish);
        const auto now = seasonAt(QDate::currentDate());
        chartList(now.first, now.second, [docs, finish, now](const QJsonArray &shows) {
            docs->season = QJsonObject { { "season", now.first }, { "year", now.second } };
            docs->airing = airingOf(shows);
            finish();
        });
    }
    static constexpr qint64 kHours = 6 * 60 * 60 * 1000;    // how long the lists that change by the day are fresh
    static QString metahub(const QString &kind, const QString &id) { return "https://images.metahub.space/" + kind + "/medium/" + id + "/img"; }
    // A Kitsu meta's logo or backdrop ("logo", "background") as the address the screens load: its own, and
    // after it the places the same title's picture comes quicker from. Its own is on fanart.tv, slow from
    // here; Stremio's image host has one by the title's IMDb id, and `more` are any others (AniList's).
    // The picture loader shows the first at hand (pictures.h). None of its own: the first of `more`.
    static QString picture(const QJsonObject &meta, const char *kind, const QStringList &more = QStringList()) {
        const QString own = meta.value(kind).toString(), imdb = meta.value("imdb_id").toString();
        if (own.isEmpty()) return more.value(0);
        return pictures::address(QStringList { own, imdb.isEmpty() || !own.contains("fanart.tv") ? QString() : metahub(kind, imdb) } + more);
    }
    static QJsonArray firstN(const QJsonArray &a, int n) { QJsonArray out; for (int i = 0; i < a.size() && i < n; i++) out << a[i]; return out; }
    // AniList's fields for a show, and the show as the catalog's documents carry it
    static QByteArray fields() {
        return "id isAdult popularity averageScore format episodes duration status source "
            "title { romaji english } bannerImage coverImage { extraLarge color } description(asHtml: false) genres "
            "studios(isMain: true) { nodes { name } } startDate { year month day } nextAiringEpisode { episode airingAt } "
            "airingSchedule(perPage: 50) { nodes { episode airingAt } }";
    }
    static QJsonObject shown(const QJsonObject &md, bool leftover) {
        const int id = md.value("id").toInt();
        const QString format = md.value("format").toString();
        const QJsonObject title = md.value("title").toObject(), start = md.value("startDate").toObject(), next = md.value("nextAiringEpisode").toObject();
        QStringList studios; for (const QJsonValue &n : md.value("studios").toObject().value("nodes").toArray()) if (studios.size() < 2) studios << n.toObject().value("name").toString();
        QString description = md.value("description").toString();
        description.replace(QRegularExpression("<[^>]+>|\\(Source:[^)]*\\)"), " ");
        description = description.simplified().left(320);
        QJsonArray airing; for (const QJsonValue &n : md.value("airingSchedule").toObject().value("nodes").toArray()) airing << n;
        return QJsonObject {
            { "id", "anilist:" + QString::number(id) }, { "anilist", id }, { "name", title.value("english").toString(title.value("romaji").toString()) },
            { "format", format }, { "episodes", md.value("episodes").toInt() }, { "duration", md.value("duration").toInt() },
            { "studio", studios.join(", ") }, { "genres", firstN(md.value("genres").toArray(), 4) }, { "score", md.value("averageScore").toInt() },
            { "popularity", md.value("popularity").toInt() }, { "leftover", leftover },
            { "start", QString("%1-%2-%3").arg(start.value("year").toInt(), 4, 10, QChar('0')).arg(start.value("month").toInt(), 2, 10, QChar('0')).arg(start.value("day").toInt(), 2, 10, QChar('0')) },
            { "next", next.isEmpty() ? QJsonValue() : QJsonValue(QJsonObject { { "episode", next.value("episode") }, { "at", next.value("airingAt") } }) },
            { "color", md.value("coverImage").toObject().value("color").toString() }, { "cover", md.value("coverImage").toObject().value("extraLarge").toString() },
            { "banner", md.value("bannerImage").toString() }, { "description", description }, { "airing", airing } };
    }
    // A Cinemeta meta or preview as the screens show a title
    static QVariantMap item(const QJsonObject &meta) {
        const QString id = meta.value("id").toString();
        QString year = meta.value("releaseInfo").toVariant().toString();
        while (year.endsWith('-') || year.endsWith(QChar(0x2013))) year.chop(1);
        QStringList chips { year, meta.value("runtime").toString() };
        for (const QJsonValue &g : firstN(meta.value("genres").toArray(), 2)) chips << g.toString();
        chips.removeAll(QString());
        const QString poster = meta.value("poster").toString(metahub("poster", id));
        return QVariantMap { { "id", id }, { "type", meta.value("type").toString() }, { "name", meta.value("name").toString() }, { "title", meta.value("name").toString() },
            { "art", poster }, { "poster", poster }, { "backdrop", meta.value("background").toString(metahub("background", id)) },
            { "logo", meta.value("logo").toString(metahub("logo", id)) }, { "description", meta.value("description").toString().left(220) },
            { "chips", chips }, { "rating", meta.value("imdbRating").toVariant().toString() }, { "episode", QString() }, { "progress", -1 } };
    }
    // Titles by name: Cinemeta's films and series, and anime from AniList, the most popular of the matches
    // first (Kitsu's own search ranks poorly: "demon slayer" starts with "Onigiri"). `done({ movies, series,
    // anime, animeMore })`: two lists of Cinemeta previews and one of shows as a season's. Cinemeta gives
    // twenty of a kind and no more when asked; the anime are a page of fifty, `animeMore` when another
    // follows (`searchAnime`).
    void search(const QString &query, std::function<void(QJsonObject)> done) {
        auto out = std::make_shared<QJsonObject>();
        auto left = std::make_shared<int>(3);
        auto finish = [out, left, done] { if (--*left == 0) done(*out); };
        for (const char *type : { "movie", "series" })
            get(QString(kCinemeta) + "/catalog/" + type + "/top/search=" + QString::fromUtf8(QUrl::toPercentEncoding(query)) + ".json", [this, out, finish, type](const QJsonDocument &d, bool) {
                withPosters(d.object().value("metas").toArray(), [out, finish, type](const QJsonArray &metas) {
                    (*out)[type == QByteArray("movie") ? "movies" : "series"] = metas; finish();
                });
            });
        searchAnime(query, 1, [out, finish](const QJsonArray &shows, bool more, bool) { (*out)["anime"] = shows; (*out)["animeMore"] = more; finish(); });
    }
    // A page of the anime a name finds on AniList, the most popular of the matches first: `done(shows,
    // more, had)`, fifty a page, `more` when another page follows, `had` false when the page couldn't be
    // had (which is no end of the list). A page is a query too, kept as long.
    void searchAnime(const QString &query, int page, std::function<void(QJsonArray, bool, bool)> done) {
        query::Options kept; kept.freshMs = kept.keepMs = kKept; kept.retries = 0;
        m_cache->fetch<QJsonObject>({ "search-anime", query, QString::number(page) }, [this, query, page](query::Call<QJsonObject> call) {
            anilist("query ($q: String, $page: Int) { Page(page: $page, perPage: 50) { pageInfo { hasNextPage } media(search: $q, type: ANIME, sort: POPULARITY_DESC) { " + fields() + " } } }",
                    QJsonObject { { "q", query }, { "page", page } }, [this, call](const QJsonObject &data) {
                const QJsonObject found = data.value("Page").toObject();
                // (nothing came: not kept, so the next asking tries the network again)
                if (found.isEmpty()) { query::Failure none; none.reason = "no answer"; none.final = true; call.fail(none); return; }
                const bool more = found.value("pageInfo").toObject().value("hasNextPage").toBool();
                auto shows = std::make_shared<QJsonArray>();
                for (const QJsonValue &v : found.value("media").toArray()) if (!v.toObject().value("isAdult").toBool()) *shows << shown(v.toObject(), false);
                kitsuIds(shows, [shows, more, call] { call.ok(QJsonObject { { "shows", *shows }, { "more", more } }); });       // (what a result's watched check goes by)
            });
        }, kept, [done](std::shared_ptr<const QJsonObject> page, const query::Failure &) {
            done(page ? page->value("shows").toArray() : QJsonArray(), page && page->value("more").toBool(), !!page);
        });
    }
    // One title's meta (a film, a series), from the Kitsu addon or Cinemeta by its id, or nothing. Kept ten
    // minutes: Home is taken again whenever the account's watch state changes (an episode marked, a title
    // off Continue Watching), and asking for every title's meta again was 2 s before the screen followed.
    void title(const QString &type, const QString &id, std::function<void(QJsonObject)> done) {
        const QString url = QString(id.startsWith("kitsu:") ? kKitsu : kCinemeta) + "/meta/" + type + "/" + id + ".json";
        query::Options kept; kept.freshMs = kept.keepMs = kKept; kept.retries = 0;        // (the request under it has its own tries)
        m_cache->fetch<QJsonObject>({ "title", type, id }, [this, url](query::Call<QJsonObject> call) {
            get(url, [call](const QJsonDocument &d, bool) {
                const QJsonObject meta = d.object().value("meta").toObject();
                if (!meta.isEmpty()) { call.ok(meta); return; }
                query::Failure none; none.reason = "no such title"; none.final = true;     // (not kept: asked again the next time)
                call.fail(none);
            });
        }, kept, [done](std::shared_ptr<const QJsonObject> meta, const query::Failure &) { done(meta ? *meta : QJsonObject()); });
    }
    static constexpr qint64 kKept = 10 * 60 * 1000;         // how long what was fetched is kept (Franchise's too)
    // the season a day is in, as AniList names it: Winter is December to February, under the year it ends in
    static QPair<QString, int> seasonAt(const QDate &day) {
        const int m = day.month();
        return { m == 12 || m <= 2 ? "WINTER" : m <= 5 ? "SPRING" : m <= 8 ? "SUMMER" : "FALL", m == 12 ? day.year() + 1 : day.year() };
    }
    // Any season's chart with its art, whole: { season, year, shows } (no shows: it couldn't be had). Its
    // list is a query of its own (Home's calendar needs only that), which this asks first.
    void seasonChart(const QString &name, int year, std::function<void(QJsonObject)> done) {
        chartList(name, year, [this, name, year, done](const QJsonArray &list) {
            if (list.isEmpty()) { done(QJsonObject()); return; }
            auto shows = std::make_shared<QJsonArray>(list);
            art(shows, [shows, name, year, done] { done(QJsonObject { { "season", name }, { "year", year }, { "shows", *shows } }); });
        });
    }

private:
    query::Queries *m_cache;
    Net m_net;
    static constexpr const char *kCinemeta = "https://v3-cinemeta.strem.io";
    static constexpr const char *kKitsu = "https://anime-kitsu.strem.fun";

    void request(const QString &url, const QByteArray &body, Net::Done done) { m_net.request(url, body, done); }
    void get(const QString &url, std::function<void(const QJsonDocument &, bool)> done) {
        request(url, QByteArray(), [done](const QByteArray &data, bool ok, int) { done(QJsonDocument::fromJson(data), ok); });
    }
    // AniList's GraphQL (a 429, at about 30 requests a minute, waits and tries again: Net)
    void anilist(const QByteArray &query, const QJsonObject &variables, std::function<void(const QJsonObject &)> done) {
        const QByteArray body = QJsonDocument(QJsonObject { { "query", QString::fromUtf8(query) }, { "variables", variables } }).toJson(QJsonDocument::Compact);
        request("https://graphql.anilist.co", body, [done](const QByteArray &data, bool, int) { done(QJsonDocument::fromJson(data).object().value("data").toObject()); });
    }

    // ---- Home ----------------------------------------------------------------------------------------------
    void rows(std::shared_ptr<Docs> docs, std::function<void()> done) {
        query::Options kept; kept.freshMs = kHours; kept.keepMs = 4 * kHours; kept.retries = 0;
        m_cache->fetch<QJsonArray>({ "rows" }, [this](query::Call<QJsonArray> call) { rows(call); }, kept,
                                   [docs, done](std::shared_ptr<const QJsonArray> rows, const query::Failure &) { if (rows) docs->rows = *rows; done(); });
    }
    void rows(query::Call<QJsonArray> call) {
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
                if (--*left) return;
                // (neither list came: not kept, so the next Home asks again)
                if ((*rows)[0].value("items").toArray().isEmpty() && (*rows)[1].value("items").toArray().isEmpty()) { query::Failure none; none.reason = "no lists"; none.final = true; call.fail(none); }
                else call.ok(QJsonArray { (*rows)[0], (*rows)[1] });
            });
    }
    // Stremio's Continue Watching, each title's meta live; a show's meta also gives its episodes, with
    // Stremio's watch state laid over them. The library's other shows come the same way (`kept`): they
    // aren't being watched, but their episodes belong on the calendar.
public:
    void continueWatching(std::shared_ptr<Docs> docs, std::function<void()> done) {
        QJsonArray list = firstN(Core::view("watching").array(), 10);
        QSet<QString> listed, mine;                         // (`mine`: the titles in the library, which the calendar shows)
        for (const QJsonValue &v : list) listed << v.toObject().value("id").toString();
        QHash<QString, QJsonObject> library;
        for (const QJsonValue &v : Core::view("library").array()) {
            const QJsonObject i = v.toObject();
            const QString id = i.value("_id").toString();
            library[id] = i.value("state").toObject();
            if (!i.value("removed").toBool()) mine << id;
            if (!i.value("removed").toBool() && i.value("type") == "series" && !listed.contains(id))
                list << QJsonObject { { "id", id }, { "type", "series" }, { "name", i.value("name") }, { "kept", true } };
        }
        docs->cw = QJsonArray(); docs->series = QJsonObject(); docs->library = QJsonObject();
        for (auto it = library.begin(); it != library.end(); ++it) docs->library[it.key()] = it.value();
        if (list.isEmpty()) { done(); return; }
        auto left = std::make_shared<int>(list.size());
        auto out = std::make_shared<QVector<QJsonObject>>(list.size());
        // eight metas at a time, however long the library is
        auto at = std::make_shared<int>(0);
        auto ask = std::make_shared<std::function<void()>>();
        *ask = [=] {
            if (*at >= list.size()) return;
            const int n = (*at)++;
            const QJsonObject i = list[n].toObject();
            const QString id = i.value("id").toString(), type = i.value("type").toString();
            title(type, id, [=](const QJsonObject &m) {
                const QString backdrop = id.startsWith("tt") ? m.value("background").toString(metahub("background", id)) : picture(m, "background");
                const QString logo = id.startsWith("tt") ? m.value("logo").toString(metahub("logo", id)) : picture(m, "logo");
                // (a show's card names the episode it rests on, with that one's progress: Catalog, from `series`;
                // `progress` here is a film's)
                (*out)[n] = QJsonObject { { "id", id }, { "name", i.value("name") }, { "type", type }, { "poster", i.value("poster") },
                                          { "progress", qRound(i.value("progress").toDouble() * 10) / 10.0 }, { "backdrop", backdrop }, { "logo", logo },
                                          { "description", m.value("description").toString().left(220) }, { "genres", firstN(m.value("genres").toArray(), 2) },
                                          { "year", m.value("releaseInfo").toVariant().toString() }, { "kept", i.value("kept").toBool() },
                                          { "library", mine.contains(id) } };
                if (type == "series" && !m.isEmpty()) docs->series[id] = show(m, library.value(id));
                if (--*left) { (*ask)(); return; }
                for (const QJsonObject &o : *out) docs->cw << o;
                *ask = nullptr;                             // (it holds itself)
                done();
            });
        };
        for (int k = 0; k < 8; k++) (*ask)();
    }
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
        // (`rest`: the episode you are on, by the one rule for it: resting.h)
        return QJsonObject { { "name", meta.value("name") }, { "current", current }, { "rest", Episodes::rest(list.toVariantList(), current) },
                             { "description", meta.value("description").toString().left(260) },
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
    // An AniList season as AniChart lists it: its shows from 3000 members up and, for the season now
    // (`leftovers`), the ones still airing from earlier seasons from 9000 up (TV, TV short, ONA). A season
    // that is over has gathered members since, so it is its 150 most popular. Each show comes with its
    // Kitsu id (the calendar matches the library's anime to their air times by it). `done(shows)`, none
    // when it couldn't be had. A query, fresh for hours: Home's calendar and the Anime tab's chart both
    // start from it, and Home asked for again finds it there.
    void chartList(const QString &name, int year, std::function<void(QJsonArray)> done) {
        query::Options kept; kept.freshMs = kHours; kept.keepMs = 4 * kHours; kept.retries = 0;
        m_cache->fetch<QJsonArray>({ "chart-list", name, QString::number(year) }, [this, name, year](query::Call<QJsonArray> call) {
            const auto now = seasonAt(QDate::currentDate());
            const bool leftovers = name == now.first && year == now.second;
            const int lastPage = leftovers ? 8 : 3;
            const QByteArray seasonQ = "query ($page: Int, $season: MediaSeason, $year: Int) { Page(page: $page, perPage: 50) { pageInfo { hasNextPage } media(season: $season, seasonYear: $year, type: ANIME, sort: POPULARITY_DESC) { " + fields() + " } } }";
            const QByteArray leftoverQ = "query ($page: Int) { Page(page: $page, perPage: 50) { pageInfo { hasNextPage } media(status: RELEASING, type: ANIME, sort: POPULARITY_DESC) { " + fields() + " } } }";
            auto shows = std::make_shared<QJsonArray>();
            auto seen = std::make_shared<QSet<int>>();
            auto take = [shows, seen](const QJsonObject &md, bool leftover) {
                const int id = md.value("id").toInt();
                const QString format = md.value("format").toString();
                if (md.value("isAdult").toBool() || seen->contains(id) || (leftover && format != "TV" && format != "TV_SHORT" && format != "ONA")) return;
                seen->insert(id);
                shows->append(shown(md, leftover));
            };
            pages(seasonQ, QJsonObject { { "season", name }, { "year", year } }, 1, 3000, lastPage, [take](const QJsonObject &md) { take(md, false); }, [=] {
                auto finish = [=] {
                    kitsuIds(shows, [shows, call] {
                        if (!shows->isEmpty()) { call.ok(*shows); return; }
                        query::Failure none; none.reason = "no shows"; none.final = true;      // (not kept: asked again the next time)
                        call.fail(none);
                    });
                };
                if (leftovers) pages(leftoverQ, QJsonObject(), 1, 9000, lastPage, [take](const QJsonObject &md) { take(md, true); }, finish); else finish();
            });
        }, kept, [done](std::shared_ptr<const QJsonArray> shows, const query::Failure &) { done(shows ? *shows : QJsonArray()); });
    }
    // AniList's pages of `q` from `page` on, until the popularity falls under `floor` or `lastPage` is
    // read: each show to `take`, then `then`. (A method that asks for itself: the lambda that did, held
    // by itself to be able to, was never let go, and each season fetched stayed in memory with it.)
    void pages(const QByteArray &q, QJsonObject vars, int page, int floor, int lastPage, std::function<void(const QJsonObject &)> take, std::function<void()> then) {
        vars["page"] = page;
        anilist(q, vars, [=](const QJsonObject &data) {
            const QJsonObject p = data.value("Page").toObject();
            bool more = p.value("pageInfo").toObject().value("hasNextPage").toBool();
            for (const QJsonValue &v : p.value("media").toArray()) {
                if (v.toObject().value("popularity").toInt() < floor) { more = false; break; }
                take(v.toObject());
            }
            if (more && page < lastPage) pages(q, vars, page + 1, floor, lastPage, take, then); else then();
        });
    }
    // When the season's episodes air, by the episode's id as Stremio has it ("kitsu:N:E"): { date, time },
    // local. The calendar shows the library's titles; an anime among them takes its air time from here.
    static QJsonObject airingOf(const QJsonArray &shows) {
        QJsonObject out;
        for (const QJsonValue &v : shows) {
            const QJsonObject s = v.toObject();
            const QString kitsu = s.value("kitsu").toString();
            if (kitsu.isEmpty()) continue;
            for (const QJsonValue &n : s.value("airing").toArray()) {
                const QDateTime at = QDateTime::fromSecsSinceEpoch(n.toObject().value("airingAt").toVariant().toLongLong());
                out[kitsu + ":" + QString::number(n.toObject().value("episode").toInt())] = QJsonObject { { "date", at.toString("yyyy-MM-dd") }, { "time", at.toString("HH:mm") } };
            }
        }
        return out;
    }
    // The titles among `metas` that have a poster, in their order. Cinemeta gives every search result a
    // poster's address, and behind a fan upload's or a reaction video's there is no picture: its card was
    // blank with a name on. The image host is asked once a title, all at once (a search has some twenty).
    void withPosters(const QJsonArray &metas, std::function<void(QJsonArray)> done) {
        if (metas.isEmpty()) { done(metas); return; }
        auto there = std::make_shared<QVector<bool>>(metas.size(), true);
        auto left = std::make_shared<int>(metas.size());
        for (int i = 0; i < metas.size(); i++) {
            const QJsonObject m = metas[i].toObject();
            m_net.exists(m.value("poster").toString(metahub("poster", m.value("id").toString())), [metas, there, left, done, i](bool ok) {
                (*there)[i] = ok;
                if (--*left) return;
                QJsonArray kept;
                for (int k = 0; k < metas.size(); k++) if ((*there)[k]) kept << metas[k];
                done(kept);
            });
        }
    }
    // each show's Kitsu id (`kitsu`: "kitsu:N", the title Stremio's library knows it by; none when Kitsu
    // doesn't have it): ARM maps AniList to Kitsu, 100 at a time
    void kitsuIds(std::shared_ptr<QJsonArray> shows, std::function<void()> done) {
        if (shows->isEmpty()) { done(); return; }
        auto left = std::make_shared<int>((shows->size() + 99) / 100);
        for (int from = 0; from < shows->size(); from += 100) {
            QJsonArray ask;
            for (int i = from; i < shows->size() && i < from + 100; i++) ask << QJsonObject { { "anilist", (*shows)[i].toObject().value("anilist") } };
            request("https://arm.haglund.dev/api/v2/ids", QJsonDocument(ask).toJson(QJsonDocument::Compact), [shows, from, left, done](const QByteArray &data, bool, int) {
                const QJsonArray ids = QJsonDocument::fromJson(data).array();
                for (int k = 0; k < ids.size(); k++) {
                    const int kitsu = ids[k].toObject().value("kitsu").toInt();
                    if (!kitsu) continue;
                    QJsonObject s = (*shows)[from + k].toObject();
                    s["kitsu"] = "kitsu:" + QString::number(kitsu);
                    (*shows)[from + k] = s;
                }
                if (--*left == 0) done();
            });
        }
    }
    // each show's full-screen fanart and logo, which the Kitsu addon has (by its `kitsu`: kitsuIds first)
    void art(std::shared_ptr<QJsonArray> shows, std::function<void()> done) {
        auto left = std::make_shared<int>(1);
        auto finish = [left, done] { if (--*left == 0) done(); };
        for (int at = 0; at < shows->size(); at++) {
            const QString kitsu = (*shows)[at].toObject().value("kitsu").toString();
            if (kitsu.isEmpty()) continue;
            ++*left;
            get(QString(kKitsu) + "/meta/series/" + kitsu + ".json", [shows, at, finish](const QJsonDocument &d, bool) {
                const QJsonObject m = d.object().value("meta").toObject();
                QJsonObject s = (*shows)[at].toObject();
                // (the backdrop's places end with AniList's own wide strip, or its cover: there for every show)
                const QString banner = s.value("banner").toString();
                s["background"] = m.value("background").toString().isEmpty() ? QString() : picture(m, "background", { banner.isEmpty() ? s.value("cover").toString() : banner });
                s["logo"] = picture(m, "logo");
                (*shows)[at] = s;
                finish();
            });
        }
        finish();
    }
};
