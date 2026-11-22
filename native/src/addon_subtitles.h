#pragma once
// Subtitles for files without them, from Stremio's OpenSubtitles addon: fetch() lists a video's (up to three
// per language) as external tracks numbered from 1000, and url() is one's file. The addon knows IMDb ids
// only; an anime's Kitsu episode is mapped to its IMDb season and episode by Stremio's Kitsu addon (as
// Torrentio maps them), once per show. What it asks of the network are queries of its owner's cache
// (query.h): a show's ids kept a day, a video's list ten minutes, and only the video asked for last
// answers. The LG's SubtitleLayer (subtitle_layer.h) and Android's (mpv) both list through this.
#include <functional>
#include <memory>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QVariant>
#include "net.h"

class AddonSubtitles {
public:
    using Read = std::shared_ptr<const Answer>;
    static bool good(const Read &a) { return a && a->status >= 200 && a->status < 300; }

    AddonSubtitles(query::Queries *queries, Net *http, std::function<void(const QVariantList &)> listed)
        : m_queries(queries), m_http(http), m_told(std::move(listed)) {
        m_listing.reset(new query::Observer<QJsonArray>(m_queries, [this](const query::Result<QJsonArray> &r) { this->listed(r); }));
    }
    // lists the addon's subtitles for a video: ("movie", "tt…"), ("series", "tt…:1:2"), or a Kitsu id
    // ("kitsu:N:episode", "kitsu:N" for a film), mapped to IMDb first
    void fetch(const QString &type, const QString &videoId) {
        query::Options kept; kept.freshMs = kept.keepMs = 10 * 60 * 1000; kept.retries = 0;
        m_listing->watch({ "subtitles", type, videoId }, [this, type, videoId](query::Call<QJsonArray> call) { list(type, videoId, call); }, kept);
        m_listing->retell();                            // (each asking is answered, the same video asked for again too)
    }
    void stop() { m_external.clear(); m_listing->stop(); }
    bool has(int number) const { return m_external.contains(number); }
    QString url(int number) const { return m_external.value(number); }

private:
    using Ids = QHash<QString, QString>;
    // (a read that went wrong is not kept: the list or the ids are asked for again the next time)
    static query::Failure wrong(const Read &a, const query::Failure &why) { return a ? query::Failure { a->status, "refused" } : why; }
    void list(const QString &type, const QString &videoId, query::Call<QJsonArray> call) {
        if (!videoId.startsWith("kitsu:")) { listAddon(type, videoId, call); return; }
        const QString show = videoId.section(':', 0, 1);
        query::Options day; day.freshMs = day.keepMs = 24 * 60 * 60 * 1000; day.retries = 0;
        m_queries->fetch<Ids>({ "kitsu-imdb", show }, [this, show](query::Call<Ids> ids) {
            query::Options once; once.keepMs = 0; once.retries = 2;
            m_http->read("https://anime-kitsu.strem.fun/meta/series/" + show + ".json", QByteArray(), once, [ids, show](Read a, const query::Failure &why) {
                if (!good(a)) { ids.fail(wrong(a, why)); return; }
                const QJsonObject meta = QJsonDocument::fromJson(a->body).object().value("meta").toObject();
                // kitsu id -> IMDb ("tt…" for a film, "tt…:season:episode" per episode); only the ids are kept
                Ids map;
                const QString imdb = meta.value("imdb_id").toString();
                for (const QJsonValue &v : meta.value("videos").toArray()) {
                    const QJsonObject e = v.toObject();
                    const QString id = e.value("imdb_id").toString(imdb);
                    if (!id.isEmpty() && e.contains("imdbSeason") && e.value("imdbEpisode").toInt() > 0)     // season 0: specials
                        map.insert(e.value("id").toString(), id + ":" + QString::number(e.value("imdbSeason").toInt()) + ":" + QString::number(e.value("imdbEpisode").toInt()));
                }
                // (last: a film's one video has the film's own id and is numbered 1:1, and as an episode
                // the addon lists nothing for it, where it had nine for the film)
                if (!imdb.isEmpty()) map.insert(show, imdb);
                ids.ok(map);
            });
        }, day, [this, show, videoId, call](std::shared_ptr<const Ids> map, const query::Failure &why) {
            if (!map) { call.fail(why); return; }
            const QString to = map->value(videoId, videoId == show ? map->value(show) : QString());
            if (to.isEmpty()) { call.ok(QJsonArray()); return; }                // (the addon knows IMDb ids only)
            listAddon(to.contains(':') ? "series" : "movie", to, call);
        });
    }
    void listAddon(const QString &type, const QString &videoId, query::Call<QJsonArray> call) {
        query::Options once; once.keepMs = 0; once.retries = 2;
        m_http->read("https://opensubtitles-v3.strem.io/subtitles/" + type + "/" + videoId + ".json", QByteArray(), once, [call](Read a, const query::Failure &why) {
            if (good(a)) call.ok(QJsonDocument::fromJson(a->body).object().value("subtitles").toArray()); else call.fail(wrong(a, why));
        });
    }
    // the video's list is in (or couldn't be had: none)
    void listed(const query::Result<QJsonArray> &r) {
        if (r.fetching) return;
        QVariantList out; QHash<QString, int> perLang;
        m_external.clear();
        for (const QJsonValue &v : r.data ? *r.data : QJsonArray()) {
            const QJsonObject s = v.toObject();
            // OpenSubtitles' own codes outside ISO 639 (its export_languages.php table), as BCP 47
            static const QHash<QString, QString> own { { "pob", "pt-BR" }, { "zht", "zh-Hant" }, { "scc", "srp" } };
            const QString lang = own.value(s.value("lang").toString(), s.value("lang").toString());
            if (perLang[lang]++ >= 3) continue;
            const int number = 1000 + m_external.size();
            m_external.insert(number, s.value("url").toString());
            out << QVariantMap { { "number", number }, { "lang", lang }, { "title", s.value("releaseGroup").toString() } };
        }
        m_told(out);
    }
    query::Queries *m_queries;
    Net *m_http;
    std::function<void(const QVariantList &)> m_told;
    std::unique_ptr<query::Observer<QJsonArray>> m_listing;     // the list of the video playing
    QHash<int, QString> m_external;
};
