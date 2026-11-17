#pragma once
// Streams: fetches a video's streams from a Stremio stream addon (Torrentio through TorBox) and reads
// each release name into plain fields for the stream picker:
//   release, file      the release (a pack's first line) and the episode's file inside a pack
//   res, hdr           4K | 1080p | 720p | 480p | "", and DV | HDR10+ | HDR | ""
//   audio              up to two codecs named (TrueHD, DTS-HD, DTS:X, DTS, DD+, DD, FLAC, Opus, AAC, PCM)
//   bd, seasonal       Blu-ray sourced; a simulcast/web release (anime only)
//   version            V2.. or REPACK, a re-release
//   support, why       supported | unsupported | unknown on this TV, and what won't play
//   seeders, size, source, langs, cached, url
// The rules are the patched Stremio app's (stremio-webos service/overlay/stream-filters.js and the
// stream badges), ported as they are, plus Opus: LG's native player rejects it, and a rejected Opus
// track jammed the TV's audio. A release that names no codec is "unknown" and stays under Supported.
// Parsing and reading run on a worker thread; `ready` hands QML the list once.
#include <QtQml>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QRegularExpression>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QThread>
#include <QUrlQuery>
#include <QTimer>
#include "store.h"
#include <QSslSocket>
#include <QSslConfiguration>
#include <QAbstractListModel>
#include <memory>

namespace releases {

using RE = QRegularExpression;
inline RE re(const char *p) { return RE(QString::fromUtf8(p), RE::CaseInsensitiveOption); }

inline bool isBD(const QString &t) {
    static const RE bd = re("(^|[^a-z0-9])(bd(-?(rips?|mv|remux|mux|r|iso|box))?|remux|(jp|us|it|eu|de|fr|ger|uk)bd|brrip)(?=[^a-z]|$)|blu-?ray");
    return bd.match(t).hasMatch();
}

inline bool isWeb(const QString &t) {
    static const RE tag = re("(^|[^a-z0-9])(web-?dl|web-?rip|webmux|crunchyroll|hidive|amzn|dsnp|netflix|b-?global|bilibili|bili|funimation|adn|hulu|hmax|atvp|pcok|itunes)(?=[^a-z]|$)");
    static const RE bare = re("(^|[^a-z0-9])(web|cr|nf)(?=[ ._-]*(\\d{3,4}[pi](?![a-z])|x26[45]|h\\.?26[45]|av1|vp9|hevc|avc|aac|opus|flac|ddp?a?(?![a-z])|dd\\+|e?ac-?3|dolby|atmos|dl(?![a-z])|rip(?![a-z])|web(?![a-z])|cr(?![a-z])|\\]|\\)))");
    static const RE afterRes = re("(\\d{3,4}[pi]|x26[45]|h\\.?26[45]|hevc|avc|av1)[ ._-]*(web|cr|nf)(?![a-z])");
    return tag.match(t).hasMatch() || bare.match(t).hasMatch() || afterRes.match(t).hasMatch();
}

// Simulcast and web releases: known fansub and rip groups (bracketed at the start of a line, as Nyaa
// names them), a few that appear inline, or a web source tag. Anything Blu-ray is never seasonal.
inline bool isSeasonal(const QString &t) {
    static const QStringList groups = { "subsplease", "erai-raws", "erai raws", "judas", "asw", "yameii", "toonshub", "dkb", "anime time",
        "horriblesubs", "ember", "asakura", "ironclad", "feibanyama", "nc-raws", "ohys-raws", "lazy", "cr-raws",
        "sokudo", "breeze", "cleo", "arg0", "doomdos", "dubs-empire" };
    static const QStringList inlineGroups = { "varyg", "tsundere-raws", "tsundere raws" };
    static const RE bracket("^\\[([^\\]]+)\\]");
    if (isBD(t)) return false;
    const QString tl = t.toLower();
    for (const QString &line : tl.split('\n')) {
        auto m = bracket.match(line.trimmed());
        if (m.hasMatch()) for (const QString &g : groups) if (m.captured(1).startsWith(g)) return true;
    }
    for (const QString &g : inlineGroups) if (tl.contains(g)) return true;
    return isWeb(t);
}

// A codec-looking word right before a year is a title ("Opus (2025)"), not a track.
inline QString stripTitleWords(QString t) {
    static const RE word = re("(^|[^a-z0-9])(opus|flac|aac|pcm|mp3|dd|dts|atmos)(?=[ ._(-]*(19|20)\\d\\d(?!\\d))");
    return t.replace(word, "\\1");
}

inline QString audioSupport(const QString &text) {
    static const RE ok = re("(^|[^a-z0-9])(ddpa?|dd\\+|dd|e[ ._-]?ac[ ._-]?3|eac3|ac[ ._-]?3|dolby[ ._-]?digital([ ._-]?plus)?|he-?aac|aac|flac|opus|vorbis|mp3|l?pcm)(?=[^a-z]|$)");
    static const RE no = re("(^|[^a-z0-9])(dts(-?(hd|x|es|ma|hdma|hd[ ._-]?ma|d))?|dts[ ._:-]?x|true-?hd)(?=[^a-z]|$)");
    static const RE atmos = re("(^|[^a-z0-9])atmos(?=[^a-z]|$)");
    static const RE truehd = re("true-?hd");
    const QString t = stripTitleWords(text);
    bool good = ok.match(t).hasMatch();
    // Atmos with no carrier named: TrueHD on disc releases, Dolby Digital Plus on web ones
    if (!good && atmos.match(t).hasMatch() && !truehd.match(t).hasMatch()) {
        if (isBD(t)) return "unsupported";
        if (isWeb(t)) good = true; else if (!no.match(t).hasMatch()) return "unknown";
    }
    const bool bad = no.match(t).hasMatch();
    if (bad && !good) return "unsupported";
    return good ? "supported" : "unknown";
}
// only 10-bit H.264 is a problem; 10-bit x265 is ordinary HDR
inline bool badVideo(const QString &t) {
    static const RE no = re("(^|[^a-z0-9])(hi10p?|hi444pp?|10-?bits?[ ._-]?(x264|h\\.?264|avc)|(x264|h\\.?264|avc)[ ._-]?10-?bits?)(?=[^a-z]|$)");
    return no.match(t).hasMatch();
}

inline QString resolution(const QString &t) {
    static const QList<QPair<QString, RE>> res = {
        { "4K", re("(?:^|[^a-z0-9])(?:2160p|4k|uhd)(?:[^a-z0-9]|$)") }, { "1080p", re("(?:^|[^a-z0-9])1080p(?:[^a-z0-9]|$)") },
        { "720p", re("(?:^|[^a-z0-9])720p(?:[^a-z0-9]|$)") }, { "480p", re("(?:^|[^a-z0-9])480p(?:[^a-z0-9]|$)") } };
    for (const auto &r : res) if (r.second.match(t).hasMatch()) return r.first;
    return QString();
}
inline QString hdr(const QString &t) {
    static const RE dv = re("(?:^|[^a-z0-9])(?:dv|dovi|dolby[ ._-]?vision)(?:[^a-z0-9]|$)"), plus = re("hdr10\\+|hdr10plus"), any = re("(?:^|[^a-z0-9])hdr(?:10)?(?:[^a-z0-9]|$)");
    return dv.match(t).hasMatch() ? "DV" : plus.match(t).hasMatch() ? "HDR10+" : any.match(t).hasMatch() ? "HDR" : "";
}
inline QStringList audio(const QString &t) {
    static const QList<QPair<QString, RE>> codecs = {
        { "TrueHD", re("true-?hd") }, { "DTS-HD", re("dts[ ._-]?hd|dts[ ._-]?ma") }, { "DTS:X", re("dts[ ._:-]?x(?![a-z0-9])") }, { "DTS", re("(?:^|[^a-z0-9])dts") },
        { "DD+", re("(?:^|[^a-z0-9])(?:ddpa?|dd\\+|e[ ._-]?ac[ ._-]?3|eac3)") }, { "DD", re("(?:^|[^a-z0-9])(?:dd|ac[ ._-]?3)(?=[^a-z]|$)") },
        { "FLAC", re("flac") }, { "Opus", re("(?:^|[^a-z0-9])opus(?:[^a-z0-9]|$)") }, { "AAC", re("aac") }, { "PCM", re("(?:^|[^a-z0-9])l?pcm") } };
    QStringList out;
    for (const auto &c : codecs) if (out.size() < 2 && c.second.match(t).hasMatch()) out << c.first;
    return out;
}
inline QString version(const QString &t) {
    static const RE numbered = re("\\b(?:s\\d{1,2}e\\d{1,4}|e\\d{1,4}|\\d{1,4})v(\\d{1,2})\\b"), bare = re("(?:^|[^a-z0-9])v(\\d{1,2})(?:[^a-z0-9]|$)");
    static const RE repack = re("(?:^|[^a-z0-9])repack(\\d*)(?:[^a-z0-9]|$)");
    auto n = numbered.match(t);
    if (!n.hasMatch()) n = bare.match(t);
    if (n.hasMatch() && n.captured(1).toInt() >= 2) return "V" + QString::number(n.captured(1).toInt());
    auto r = repack.match(t);
    return r.hasMatch() ? "REPACK" + r.captured(1) : QString();
}

// The release group: "[Group] Title …" (fansub style) or "Title.….-Group" (scene style), or "".
inline QString group(const QString &name) {
    static const RE bracket("^\\[([^\\]]+)\\]"), scene("-([A-Za-z0-9][A-Za-z0-9.]*?)(?:\\.(?:mkv|mp4|avi))?\\s*$");
    const QString first = name.section('\n', 0, 0).trimmed();
    const auto b = bracket.match(first);
    if (b.hasMatch()) return b.captured(1).trimmed().toLower();
    const auto sc = scene.match(first);
    return sc.hasMatch() ? sc.captured(1).toLower() : QString();
}
// a dub alone ("English Dub", "Dubbed"), with no original-language track beside it ("Dual Audio", "Multi-Audio")
inline bool dubOnly(const QString &text) {
    static const RE dub = re("(^|[^a-z])dub(bed)?([^a-z]|$)"), both = re("dual[ ._-]?audio|multi[ ._-]?audio|(^|[^a-z])dual([^a-z]|$)");
    return dub.match(text).hasMatch() && !both.match(text).hasMatch();
}

// A release name without the title in front: its group, then what follows the episode tag or year, when
// that leaves enough to tell releases apart.
inline QString shortName(const QString &name) {
    static const RE mark = re("\\bS\\d{1,2}E\\d{1,4}\\b|\\[S\\d{1,2}E\\d{1,4}\\]|\\s-\\s\\d{1,4}\\b|[(\\[ ](19|20)\\d\\d[)\\] ]");
    static const RE lead("^[\\s\\]\\)\\-:]+"), ext = re("\\s(mkv|mp4|avi)$"), group("^\\[[^\\]]+\\]");
    QString t = name; t.replace('.', ' ');
    const auto m = mark.match(t);
    if (!m.hasMatch() || m.capturedStart() < 4 || m.capturedStart() > t.size() * 0.6) return t;
    QString rest = t.mid(m.capturedEnd()); rest.remove(lead); rest.remove(ext);
    const auto g = group.match(t);
    return rest.size() > 12 ? (g.hasMatch() ? g.captured(0) + " " : QString()) + rest : t;
}

// One stream (Torrentio's name, title and url) read into the picker's fields.
inline QVariantMap read(const QString &name, const QString &title, const QString &url, bool anime) {
    static const RE seeders("👤\\s*(\\d+)"), size("💾\\s*([\\d.]+\\s*[KMGT]B)"), source("⚙️\\s*(.+)$");
    const QString blob = title + "\n\n" + name;
    const QStringList lines = title.split('\n'), nameLines = name.split('\n');
    int stats = 0;
    while (stats < lines.size() && !lines[stats].contains("👤")) stats++;
    const QString statLine = stats < lines.size() ? lines[stats] : QString();
    QStringList langs;
    for (const QString &l : lines.mid(stats + 1).join(' ').split('/')) {
        const QString x = l.trimmed();
        bool flag = false;
        for (uint c : x.toUcs4()) if (c >= 0x1F1E6 && c <= 0x1F1FF) flag = true;
        if (!x.isEmpty() && !flag) langs << x;
    }
    const QString quality = nameLines.mid(1).join(' ');
    const QStringList codecs = audio(blob);
    const bool opusOnly = !codecs.isEmpty() && codecs.count("Opus") == codecs.size();
    const QString support = opusOnly ? "unsupported" : badVideo(blob) ? "unsupported" : audioSupport(blob);
    QString why = support != "unsupported" ? "" : opusOnly ? "Opus" : badVideo(blob) ? "10-bit H.264" : "Audio";
    if (why == "Audio") for (const QString &c : codecs) if (c.startsWith("DTS") || c == "TrueHD") { why = c; break; }
    const QString res = resolution(quality);
    // the stream list's chips, in order: { text, icon, tag } (tag names a tinted kind: bd, version)
    QVariantList chips;
    auto chip = [&chips](const QString &text, const QString &icon = QString(), const QString &tag = QString()) {
        chips << QVariantMap { { "text", text }, { "icon", icon }, { "tag", tag } }; };
    const QString sizeText = size.match(statLine).captured(1), ver = version(blob);
    const QString fileInPack = lines.size() > 2 && !lines[1].contains("👤") ? lines[1].section('/', -1) : QString();
    chip(QString::number(seeders.match(statLine).captured(1).toInt()), "up");
    if (!sizeText.isEmpty()) chip(sizeText);
    for (const QString &c : codecs) chip(c);
    if (isBD(blob)) chip("BD", QString(), "bd");
    if (!ver.isEmpty()) chip(ver, QString(), "version");
    for (const QString &l : langs.mid(0, 2)) chip(l);
    if (!fileInPack.isEmpty()) chip("Pack");
    if (!nameLines.value(0).startsWith("[TB+]")) chip("Not cached", "down");
    return {
        { "chips", chips },
        { "release", lines.value(0) },
        { "shortName", shortName(lines.value(0)) },
        { "file", lines.size() > 2 && !lines[1].contains("👤") ? lines[1].section('/', -1) : QString() },
        { "res", res.isEmpty() ? resolution(blob) : res },
        { "hdr", hdr(quality + " " + blob) },
        { "bd", isBD(blob) },
        { "seasonal", anime && isSeasonal(blob) },
        { "version", version(blob) },
        { "audio", codecs },
        { "support", support },
        { "why", why },
        { "seeders", seeders.match(statLine).captured(1).toInt() },
        { "size", size.match(statLine).captured(1) },
        { "source", source.match(statLine).captured(1) },
        { "langs", langs },
        { "cached", nameLines.value(0).startsWith("[TB+]") },
        { "url", url },
        { "group", group(lines.value(0)) },
        { "dubOnly", dubOnly(blob) },
    };
}

} // namespace releases

// Streams: the stream picker's list (a model of the fetched streams, filtered and sorted by `kind`) and
// the AI pick (play): fetch, keep what plays here and is cached, let a decision model choose, resolve.
//   kind     anime: 0 All, 1 Seasonal, 2 BD; anything else: 0 All, 1 Supported, 2 Unsupported. Anime lists
//            by seeders, anything else keeps the addon's order (as in the patched Stremio app).
//   stage    what play() is doing: fetching | choosing | resolving, or "" when idle
//   chosen   the stream play() settled on, for the loading screen
// The AI pick for each video is kept (ai-picks.json in the app's data folder) and marked in the list
// (`aiPick`), so a pick that played badly can be told apart and avoided.
// play() and playRow() end in `playable(stream, url)` or `failed(reason)`; play() fails when nothing cached
// plays here, or when the decision model hasn't answered after three tries (the list stays loaded for the
// picker). A newer request replaces an
// older one. Links come straight from TorBox (add the torrent, find the file, request its link), and fall
// back to the addon's own link, which redirects through its resolver.
class Streams : public QAbstractListModel {
    Q_OBJECT
    Q_PROPERTY(QString addon MEMBER m_addon NOTIFY configChanged)
    Q_PROPERTY(QString torbox MEMBER m_torbox NOTIFY configChanged)
    Q_PROPERTY(QString openrouter MEMBER m_openrouter NOTIFY configChanged)
    Q_PROPERTY(QString decider MEMBER m_decider NOTIFY configChanged)      // the decision model
    Q_PROPERTY(int kind READ kind WRITE setKind NOTIFY listChanged)
    Q_PROPERTY(bool anime READ anime NOTIFY listChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY listChanged)
    Q_PROPERTY(QString failure READ failure NOTIFY listChanged)
    Q_PROPERTY(int total READ total NOTIFY listChanged)
    Q_PROPERTY(QVariantMap mix READ mix NOTIFY listChanged)                // listed streams per resolution
    Q_PROPERTY(QString stage READ stage NOTIFY stageChanged)
    Q_PROPERTY(QVariantMap chosen READ chosen NOTIFY stageChanged)
    Q_PROPERTY(QString dataDir MEMBER m_dataDir NOTIFY configChanged)       // where the AI picks are kept
    Q_PROPERTY(QString picksStatus MEMBER m_picksStatus NOTIFY stageChanged)  // the last save, for the lab
public:
    // The first HTTPS request loads OpenSSL and the system's certificates, which held the GUI thread
    // ~95 ms on the TV when the list opened. Load them on a worker thread once the app has started, then
    // open connections to the hosts a play uses, so the first fetch, decision and link are quick.
    explicit Streams(QObject *parent = nullptr) : QAbstractListModel(parent) {
        QTimer::singleShot(6000, this, [this] {
            QThread *warm = QThread::create([] { QSslSocket::supportsSsl(); QSslConfiguration::defaultConfiguration().caCertificates(); });
            connect(warm, &QThread::finished, this, [this] {
                for (const QString &host : { QUrl(m_addon).host(), QString("api.torbox.app"), QString("openrouter.ai") })
                    if (!host.isEmpty()) m_net.connectToHostEncrypted(host);
            });
            connect(warm, &QThread::finished, warm, &QObject::deleteLater);
            warm->start();
        });
    }
    static const QStringList &keys() {
        static const QStringList k = { "release", "shortName", "file", "res", "hdr", "bd", "seasonal", "version", "audio",
                                       "support", "why", "seeders", "size", "source", "langs", "cached", "url", "aiPick", "chips" };
        return k;
    }
    int rowCount(const QModelIndex &parent = QModelIndex()) const override { return parent.isValid() ? 0 : m_rows.size(); }
    QVariant data(const QModelIndex &index, int role) const override {
        if (!index.isValid() || index.row() >= m_rows.size()) return QVariant();
        return m_all[m_rows[index.row()]].fields.value(keys().value(role - Qt::UserRole));
    }
    QHash<int, QByteArray> roleNames() const override {
        QHash<int, QByteArray> r;
        for (int i = 0; i < keys().size(); i++) r[Qt::UserRole + i] = keys()[i].toUtf8();
        return r;
    }
    int kind() const { return m_kind; }
    void setKind(int k) { if (k != m_kind) { m_kind = k; refilter(); } }
    bool anime() const { return m_anime; }
    bool loading() const { return m_loading; }
    QString failure() const { return m_failure; }
    int total() const { return m_all.size(); }
    QVariantMap mix() const { return m_mix; }
    QString stage() const { return m_stage; }
    QVariantMap chosen() const { return m_chosen; }

    // Fetches the streams for a video ("movie", "tt..." or "series", "kitsu:N:E") into the list.
    Q_INVOKABLE void fetch(const QString &type, const QString &videoId) { m_auto = false; m_binge.clear(); setStage(""); load(type, videoId); }
    // The AI pick: fetches the video's streams, then chooses one and resolves it (`title` names the
    // video for the decision model, e.g. "Dexter: Resurrection S2 E3").
    // `bingeGroup`: the binge group of what was playing (an episode switch). As Stremio's player does
    // (stremio-core models/player.rs, next_stream_update and Stream::is_binge_match), the first stream in
    // the addon's order with the same group plays, here only if it's cached and plays on this TV;
    // otherwise the AI picks as usual.
    Q_INVOKABLE void play(const QString &type, const QString &videoId, const QString &title, const QString &bingeGroup = QString()) {
        m_auto = true; m_title = title; m_binge = bingeGroup; m_chosen.clear(); setStage("fetching"); load(type, videoId);
    }
    // Fetches a video's streams ahead, kept for its play() (stremio-core's next_streams_update: the next
    // episode's streams are asked for as soon as one plays). One video at a time.
    Q_INVOKABLE void prefetch(const QString &type, const QString &videoId) {
        if (m_ahead.videoId == videoId) return;
        m_ahead = { videoId, QByteArray(), false };
        QNetworkReply *reply = m_net.get(request(QUrl(m_addon + "stream/" + type + "/" + videoId + ".json")));
        connect(reply, &QNetworkReply::finished, this, [this, reply, videoId] {
            reply->deleteLater();
            if (m_ahead.videoId != videoId || reply->error() != QNetworkReply::NoError) return;
            m_ahead.body = reply->readAll(); m_ahead.ready = true;
        });
    }
    // Resolves the listed stream at `row` (the picker's choice).
    Q_INVOKABLE void playRow(int row) {
        if (row < 0 || row >= m_rows.size()) return;
        m_auto = false; ++m_ticket; m_chosen = m_all[m_rows[row]].fields; resolve(m_all[m_rows[row]], m_ticket);
    }
    Q_INVOKABLE void cancel() { ++m_ticket; m_auto = false; setStage(""); }
    // the listed row of the stream with this addon link, or -1
    Q_INVOKABLE int rowOf(const QString &url) const { for (int r = 0; r < m_rows.size(); r++) if (m_all[m_rows[r]].url == url) return r; return -1; }
    // tests: the anime rule's pick from an addon response (Torrentio's JSON), as play() would make it
    Q_INVOKABLE QVariantMap ruledPick(const QString &json) const {
        QVector<QVariantMap> all; QVector<int> c;
        for (const QJsonValue &v : QJsonDocument::fromJson(json.toUtf8()).object().value("streams").toArray()) {
            const QJsonObject o = v.toObject();
            QVariantMap f = releases::read(o.value("name").toString(), o.value("title").toString(), o.value("url").toString(), true);
            if (f["support"] != "unsupported" && f["cached"].toBool()) c << all.size();
            all << f;
        }
        const int i = animeRule(all, c);
        return i >= 0 ? all[i] : QVariantMap();
    }
    // reads one stream's text, for tests
    Q_INVOKABLE QVariantMap read(const QString &name, const QString &title, bool anime) const { return releases::read(name, title, QString(), anime); }

signals:
    void configChanged();
    void listChanged();
    void stageChanged();
    void playable(const QVariantMap &stream, const QString &url);
    void failed(const QString &reason);

private:
    struct Item { QVariantMap fields; QString option, url, file; };
    struct Ahead { QString videoId; QByteArray body; bool ready = false; };
    Ahead m_ahead;
    QString m_binge;

    // The decision model's instructions; the state names the video and whether it's anime.
    static QString rules() {
        return QStringLiteral(
            "Pick one stream to play on an LG C5 OLED TV. Every option plays on it and is cached. Rules, in order:\n"
            "1. Anime (it comes to you only when there is a Blu-ray): 1080p, not 4K. The most promising 1080p Blu-ray (BD, BDRip, BDRemux) release. Prefer single-episode files to whole-series packs when quality is equal.\n"
            "2. Not anime: the best 4K HDR (Dolby Vision or HDR10), preferably Blu-ray; else the best 1080p.\n"
            "3. The first audio track must be the original language in Dolby Digital, Dolby Digital Plus, AAC or LPCM. Skip foreign-market releases whose names are mainly another language or list dubs (DUB, MVO, AVO, Cyrillic titles): their first track is the dub. Prefer releases that name a supported codec over ones that name none.\n"
            "4. A re-release (v2, v3, REPACK, PROPER) fixes its original: prefer it to the same release without it.\n"
            "5. Among equals, more seeders.");
    }

    QNetworkRequest request(const QUrl &url) const {
        QNetworkRequest r(url);
        r.setHeader(QNetworkRequest::UserAgentHeader, "seimio/0.1");
        r.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
        return r;
    }
    // runs `done` with the reply's JSON (or an error) if the request is still the current one
    template <typename F> void call(QNetworkReply *reply, int ticket, F done) {
        connect(reply, &QNetworkReply::finished, this, [this, reply, ticket, done] {
            reply->deleteLater();
            if (ticket != m_ticket) return;
            const QByteArray body = reply->readAll();
            done(QJsonDocument::fromJson(body).object(), reply->error() == QNetworkReply::NoError ? QString() : reply->errorString() + " " + QString::fromUtf8(body.left(200)));
        });
    }

    // Anime or not (the ranking, the AI's rules, and whose track choices the player uses): a Kitsu id is
    // anime; an IMDb id is when the community anime mapping (Fribb's anime-lists, through ARM) lists it,
    // asked alongside the streams and kept per show for the session.
    void load(const QString &type, const QString &videoId) {
        const int ticket = ++m_ticket;
        m_videoId = videoId;
        beginResetModel(); m_all.clear(); m_rows.clear(); endResetModel();
        const QString imdb = videoId.section(':', 0, 0);
        m_anime = videoId.startsWith("kitsu:") || m_animeIds.value(imdb, false); m_loading = true; m_failure.clear(); m_mix.clear();
        emit listChanged();
        auto join = std::make_shared<Join>();
        if (imdb.startsWith("tt") && !m_animeIds.contains(imdb)) {
            join->pending++;
            QNetworkReply *arm = m_net.get(request(QUrl("https://arm.haglund.dev/api/v2/imdb?id=" + imdb)));
            QTimer::singleShot(4000, arm, &QNetworkReply::abort);
            connect(arm, &QNetworkReply::finished, this, [this, arm, ticket, imdb, join] {
                arm->deleteLater();
                if (arm->error() == QNetworkReply::NoError) m_animeIds.insert(imdb, !QJsonDocument::fromJson(arm->readAll()).array().isEmpty());
                if (ticket != m_ticket) return;
                m_anime = m_animeIds.value(imdb, false);
                if (--join->pending == 0) parse(join, ticket);
            });
        }
        // fetched ahead: no wait
        if (m_ahead.videoId == videoId && m_ahead.ready) {
            join->body = m_ahead.body;
            if (--join->pending == 0) parse(join, ticket);
            return;
        }
        QNetworkReply *reply = m_net.get(request(QUrl(m_addon + "stream/" + type + "/" + videoId + ".json")));
        connect(reply, &QNetworkReply::finished, this, [this, reply, ticket, join] {
            reply->deleteLater();
            if (ticket != m_ticket) return;
            if (reply->error() != QNetworkReply::NoError) join->failure = reply->errorString(); else join->body = reply->readAll();
            if (--join->pending == 0) parse(join, ticket);
        });
    }
    struct Join { int pending = 1; QByteArray body; QString failure; };
    void parse(const std::shared_ptr<Join> &join, int ticket) {
        if (!join->failure.isEmpty()) { listed({}, join->failure); return; }
        {
            auto out = std::make_shared<QVector<Item>>();
            QThread *worker = QThread::create([out, body = join->body, anime = m_anime] {
                for (const QJsonValue &v : QJsonDocument::fromJson(body).object().value("streams").toArray()) {
                    const QJsonObject s = v.toObject();
                    const QString name = s.value("name").toString(), title = s.value("title").toString(), url = s.value("url").toString();
                    const QString file = s.value("behaviorHints").toObject().value("filename").toString();
                    QVariantMap fields = releases::read(name, title, url, anime);
                    fields["bingeGroup"] = s.value("behaviorHints").toObject().value("bingeGroup").toString();
                    out->append({ fields,
                                  QString(name).replace('\n', ' ') + " | " + QString(title).replace('\n', " | ") + " | file: " + file, url, file });
                }
            });
            connect(worker, &QThread::finished, this, [this, out, ticket] { if (ticket == m_ticket) listed(*out, QString()); });
            connect(worker, &QThread::finished, worker, &QObject::deleteLater);
            worker->start();
        }
    }
    void listed(const QVector<Item> &items, const QString &failure) {
        m_all = items; m_loading = false; m_failure = failure;
        const QString picked = aiPicks().value(m_videoId).toString();
        for (Item &it : m_all) it.fields["aiPick"] = !picked.isEmpty() && it.url == picked;
        m_kind = m_anime ? 0 : 1;
        refilter();
        if (m_auto) choose(m_ticket);
    }
    void refilter() {
        beginResetModel();
        m_rows.clear();
        for (int i = 0; i < m_all.size(); i++) {
            const QVariantMap &f = m_all[i].fields;
            const bool keep = m_anime ? (m_kind == 1 ? f["seasonal"].toBool() : m_kind == 2 ? f["bd"].toBool() : true)
                                      : (m_kind == 1 ? f["support"] != "unsupported" : m_kind == 2 ? f["support"] == "unsupported" : true);
            if (keep) m_rows << i;
        }
        if (m_anime) std::stable_sort(m_rows.begin(), m_rows.end(), [this](int a, int b) { return m_all[a].fields["seeders"].toInt() > m_all[b].fields["seeders"].toInt(); });
        endResetModel();
        QVariantMap mix { { "4K", 0 }, { "1080p", 0 }, { "720p", 0 }, { "other", 0 } };
        for (int i : m_rows) { const QString r = m_all[i].fields["res"].toString(); mix[mix.contains(r) ? r : "other"] = mix.value(mix.contains(r) ? r : "other").toInt() + 1; }
        m_mix = mix;
        emit listChanged();
    }

    // The candidates: what plays here and is cached, best first. The decision model is asked about the
    // first 255 (what a choice question takes); the rules before it see them all.
    QVector<int> candidates() const {
        QVector<int> c;
        for (int i = 0; i < m_all.size(); i++) if (m_all[i].fields["support"] != "unsupported" && m_all[i].fields["cached"].toBool()) c << i;
        // anime: 1080p first, then 4K; anything else: 4K first. A re-release (v2, REPACK) beats its original.
        auto rank = [this](int i) { const QVariantMap &f = m_all[i].fields; const QString r = f["res"].toString();
                                    const int res = m_anime ? (r == "1080p" ? 2 : r == "4K" ? 1 : 0) : (r == "4K" ? 2 : r == "1080p" ? 1 : 0);
                                    return res * 2000000 + (f["version"].toString().isEmpty() ? 0 : 1000000) + qMin(f["seeders"].toInt(), 999999); };
        std::stable_sort(c.begin(), c.end(), [&](int a, int b) { return rank(a) > rank(b); });
        return c;
    }
    void choose(int ticket, int attempt = 1) {
        const QVector<int> c = candidates();
        if (c.isEmpty()) { fail(m_all.isEmpty() ? (m_failure.isEmpty() ? "No streams yet" : m_failure) : "Nothing cached plays on this TV"); return; }
        if (attempt == 1) {
            // the same release as the episode before: the first in the addon's order with its binge group
            if (!m_binge.isEmpty())
                for (int i = 0; i < m_all.size(); i++)
                    if (m_all[i].fields["bingeGroup"].toString() == m_binge && c.contains(i)) { pick(i, ticket); return; }
            // anime with no Blu-ray here leaves nothing to judge: picked directly, without the AI (animeRule)
            if (m_anime) {
                QVector<QVariantMap> fields; for (const Item &it : m_all) fields << it.fields;
                const int i = animeRule(fields, c);
                if (i >= 0) { pick(i, ticket); return; }
            }
        }
        // one candidate needs no decision; without a key (the lab's tours) the best by rank plays
        if (c.size() == 1 || m_openrouter.isEmpty() || m_decider.isEmpty()) { pick(c[0], ticket); return; }
        setStage("choosing");
        const QVector<int> asked = c.mid(0, 255);
        QJsonObject criteria;
        for (int i : asked) criteria["s" + QString::number(i)] = m_all[i].option;
        const QJsonObject body {
            { "model", m_decider },
            { "state", QJsonObject { { "video", m_title + (m_anime ? " (anime)" : "") }, { "rules", rules() } } },
            { "questions", QJsonObject { { "pick", QJsonObject { { "type", "choice" }, { "instructions", "Which stream should play, following the rules?" }, { "criteria", criteria } } } } } };
        QNetworkRequest r = request(QUrl("https://openrouter.ai/api/alpha/decisions"));
        r.setRawHeader("Authorization", "Bearer " + m_openrouter.toUtf8());
        r.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
        r.setRawHeader("X-Title", "Seimio");
        call(m_net.post(r, QJsonDocument(body).toJson(QJsonDocument::Compact)), ticket, [this, asked, ticket, attempt](const QJsonObject &o, const QString &err) {
            const QJsonObject a = o.value("answers").toObject().value("pick").toObject();
            const QString choice = a.value("choice").toString();
            const int i = choice.mid(1).toInt();
            if (!err.isEmpty() || !choice.startsWith('s') || !asked.contains(i)) {
                qWarning("decision attempt %d failed: %s", attempt, qPrintable(err.isEmpty() ? QString("no usable choice") : err));
                if (attempt >= 3) { fail("The AI pick didn't answer"); return; }
                QTimer::singleShot(400 * attempt, this, [this, ticket, attempt] { if (ticket == m_ticket) choose(ticket, attempt + 1); });
                return;
            }
            m_all[i].fields["confidence"] = a.value("probabilities").toObject().value(a.value("choice").toString()).toDouble();
            remember(i);
            pick(i, ticket);
        });
    }
    // The user's rule for anime with no Blu-ray among the candidates `c`: the most seeded, dub-only
    // releases left out, unless a v2 or REPACK of one of the three most seeded exists (the same group
    // and resolution), then the best seeded of those. -1 when there's a Blu-ray (the AI judges).
    static int animeRule(const QVector<QVariantMap> &all, const QVector<int> &c) {
        for (int i : c) if (all[i]["bd"].toBool()) return -1;
        QVector<int> bySeed;
        for (int i : c) if (!all[i]["dubOnly"].toBool()) bySeed << i;
        std::stable_sort(bySeed.begin(), bySeed.end(), [&all](int a, int b) { return all[a]["seeders"].toInt() > all[b]["seeders"].toInt(); });
        if (bySeed.isEmpty()) return -1;
        for (int t = 0; t < bySeed.size() && t < 3; t++) {
            const QVariantMap &top = all[bySeed[t]];
            if (!top["version"].toString().isEmpty()) return bySeed[t];             // a re-release among the top
            if (top["group"].toString().isEmpty()) continue;
            for (int v : bySeed) {
                const QVariantMap &f = all[v];
                if (!f["version"].toString().isEmpty() && f["group"] == top["group"] && f["res"] == top["res"]) return v;
            }
        }
        return bySeed[0];
    }
    void pick(int i, int ticket) { m_chosen = m_all[i].fields; resolve(m_all[i], ticket); }

    // the AI picks so far, by video id: { videoId: the stream's addon url }
    QJsonObject &aiPicks() { m_picks.setDir(m_dataDir); return m_picks.data(); }
    void remember(int i) {
        aiPicks()[m_videoId] = m_all[i].url;
        m_picksStatus = m_picks.save();
        for (int k = 0; k < m_all.size(); k++) m_all[k].fields["aiPick"] = k == i;
        if (!m_rows.isEmpty()) emit dataChanged(index(0), index(m_rows.size() - 1));
    }

    void resolve(const Item &item, int ticket) {
        setStage("resolving");
        static const QRegularExpression hashRe("/([0-9a-f]{40})/");
        const QString hash = hashRe.match(item.url).captured(1);
        const QString fallback = item.url;
        auto done = [this, fallback](const QString &url) { setStage(""); emit playable(m_chosen, url.isEmpty() ? fallback : url); };
        if (hash.isEmpty() || m_torbox.isEmpty()) { done(QString()); return; }
        const QString want = QUrl::fromPercentEncoding(item.url.section('/', -1).toUtf8());
        QNetworkRequest add = torbox("torrents/createtorrent");
        add.setHeader(QNetworkRequest::ContentTypeHeader, "application/x-www-form-urlencoded");
        QUrlQuery form; form.addQueryItem("magnet", "magnet:?xt=urn:btih:" + hash); form.addQueryItem("allow_zip", "false");
        call(m_net.post(add, form.toString(QUrl::FullyEncoded).toUtf8()), ticket, [this, ticket, want, done](const QJsonObject &o, const QString &err) {
            const int id = o.value("data").toObject().value("torrent_id").toInt();
            if (!err.isEmpty() || !id) { qWarning("torbox add failed: %s", qPrintable(err)); done(QString()); return; }
            call(m_net.get(torbox(QString("torrents/mylist?bypass_cache=true&id=%1").arg(id))), ticket, [this, ticket, id, want, done](const QJsonObject &o, const QString &err) {
                QJsonObject best; double size = -1;
                for (const QJsonValue &v : o.value("data").toObject().value("files").toArray()) {
                    const QJsonObject f = v.toObject();
                    if (f.value("short_name").toString() == want || f.value("name").toString().endsWith(want)) { best = f; break; }
                    if (f.value("size").toDouble() > size) { size = f.value("size").toDouble(); best = f; }
                }
                if (!err.isEmpty() || best.isEmpty()) { done(QString()); return; }
                call(m_net.get(torbox(QString("torrents/requestdl?token=%1&torrent_id=%2&file_id=%3&redirect=false").arg(m_torbox).arg(id).arg(best.value("id").toInt()))),
                     ticket, [done](const QJsonObject &o, const QString &err) { done(err.isEmpty() ? o.value("data").toString() : QString()); });
            });
        });
    }
    QNetworkRequest torbox(const QString &path) const {
        QNetworkRequest r = request(QUrl("https://api.torbox.app/v1/api/" + path));
        r.setRawHeader("Authorization", "Bearer " + m_torbox.toUtf8());
        return r;
    }
    void fail(const QString &reason) { setStage(""); m_auto = false; emit failed(reason); }
    void setStage(const QString &s) { if (s != m_stage) { m_stage = s; emit stageChanged(); } }

    QNetworkAccessManager m_net;
    QString m_addon, m_torbox, m_openrouter, m_decider = "typesafe/jev-1.14", m_title, m_failure, m_stage, m_videoId;
    JsonStore m_picks { "ai-picks.json" };
    QString m_dataDir, m_picksStatus;
    QVector<Item> m_all;
    QVector<int> m_rows;
    QVariantMap m_mix, m_chosen;
    int m_kind = 0, m_ticket = 0;
    bool m_anime = false, m_loading = false, m_auto = false;
    QHash<QString, bool> m_animeIds;                    // IMDb id -> anime, as the mapping answered
};
