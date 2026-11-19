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
#include <QRegularExpression>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QUrlQuery>
#include <QTimer>
#include "net.h"
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
// Surround the TV plays only the front pair of, losing the dialogue (playback.h): FLAC in 5.1 or 7.1 and
// Opus in 7.1, when it is the release's one named codec. Returns that name ("Opus 7.1"), or "".
inline QString lostSurround(const QString &t) {
    static const RE after = re("(^|[^a-z0-9])(opus|flac)[ ._-]?([57])[ .]?1(?=[^0-9]|$)"), before = re("(^|[^0-9])([57])[ .]1[ ._-]?(opus|flac)(?=[^a-z]|$)");
    auto m = after.match(t);
    QString codec = m.captured(2).toLower(), wide = m.captured(3);
    if (!m.hasMatch()) { m = before.match(t); codec = m.captured(3).toLower(); wide = m.captured(2); }
    if (!m.hasMatch() || (codec == "opus" && wide == "5")) return QString();
    return (codec == "opus" ? "Opus " : "FLAC ") + wide + ".1";
}
// Video the TV doesn't show (playback.h): 10-bit H.264 fails to start (10-bit x265 is ordinary HDR), and
// Dolby Vision in AV1 (profile 10) decodes to a broken picture. Returns which, or "".
inline QString badVideo(const QString &t) {
    static const RE hi10 = re("(^|[^a-z0-9])(hi10p?|hi444pp?|10-?bits?[ ._-]?(x264|h\\.?264|avc)|(x264|h\\.?264|avc)[ ._-]?10-?bits?)(?=[^a-z]|$)");
    static const RE av1 = re("(^|[^a-z0-9])av1(?=[^a-z0-9]|$)"), dv = re("(^|[^a-z0-9])(dv|dovi|dolby[ ._-]?vision)(?=[^a-z0-9]|$)");
    return hi10.match(t).hasMatch() ? "10-bit H.264" : av1.match(t).hasMatch() && dv.match(t).hasMatch() ? "AV1 Dolby Vision" : QString();
}
// Anime without subtitles as a track: a raw (the Japanese broadcast or disc: Kawaiika-Raws, Beatrice-Raws;
// Erai-raws is a subtitle group despite its name, and a release that names its subtitles has them), or
// subtitles burned into the picture: a hardsub, or an MP4 (it can't carry ASS: NoobSubs' Blu-ray MP4s).
// The online subtitles the player adds would show twice over burned ones.
inline bool noSubtitleTrack(const QString &t, const QString &file) {
    static const RE raw = re("(^|[^a-z0-9])raws?(?=[^a-z]|$)"), subbed = re("erai-raws|(^|[^a-z])(multi-?|e|eng-?)?subs?(?=[^a-z]|$)"),
                    burned = re("(^|[^a-z])(hard-?sub(s|bed)?|hc|mp4)(?=[^a-z]|$)");
    return (raw.match(t).hasMatch() && !subbed.match(t).hasMatch()) || burned.match(t).hasMatch() || burned.match(file).hasMatch();
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
    const QString video = badVideo(blob), surround = codecs.size() <= 1 ? lostSurround(blob) : QString();     // no other codec named
    const QString support = !video.isEmpty() || !surround.isEmpty() ? "unsupported" : audioSupport(blob);
    QString why = support != "unsupported" ? "" : !video.isEmpty() ? video : !surround.isEmpty() ? surround : "Audio";
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
        { "noSubtitleTrack", anime && noSubtitleTrack(blob, fileInPack) },
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
// picker). Links come straight from TorBox (add the torrent, find the file, request its link), and fall
// back to the addon's own link, which redirects through its resolver.
// A video's list, the model's decision and a stream's link are queries of its own cache (query.h), each
// watched by one observer: a newer request points the observer elsewhere, and an answer to an older one
// is the cache's and no longer shown. The decision's three tries are the query's.
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
            // (work for the cache like any other: what follows comes back here, or nowhere if this is gone)
            m_queries.fetch<bool>({ "tls" }, query::onWorker<bool>([] { QSslSocket::supportsSsl(); QSslConfiguration::defaultConfiguration().caCertificates(); return true; }),
                                  query::Options(), [this](std::shared_ptr<const bool>, const query::Failure &) {
                for (const QString &host : { QUrl(m_addon).host(), QString("api.torbox.app"), QString("openrouter.ai") })
                    if (!host.isEmpty()) m_wire.connectToHostEncrypted(host);
            });
        });
        m_quick.idleMs = 4000;
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
        if (m_ahead == videoId) return;
        m_ahead = videoId;
        m_queries.fetch<Listed>({ "streams", videoId }, listing(type, videoId), kept(kAhead), [](std::shared_ptr<const Listed>, const query::Failure &) {});
    }
    // Up next: makes the next episode playable ahead, from its prefetched streams. The stream play()
    // would pick by rule (the binge match, then the anime rule) gets its link now, kept for resolve(),
    // so Next goes straight to loading the video. When only the AI could pick, nothing is prepared.
    Q_INVOKABLE void prepare(const QString &videoId, const QString &bingeGroup) {
        const auto ahead = m_ahead == videoId ? m_queries.peek<Listed>({ "streams", videoId }) : nullptr;
        if (!ahead || m_prepared == videoId) return;
        m_prepared = videoId;
        const int i = ruled(ahead->items, candidates(ahead->items, ahead->anime), bingeGroup, ahead->anime);
        if (i < 0) return;
        m_aheadLink = ahead->items[i].url;
        m_queries.fetch<QString>({ "link", m_aheadLink }, linking(m_aheadLink), kept(kLinkMs), [](std::shared_ptr<const QString>, const query::Failure &) {});
    }
    // Resolves the listed stream at `row` (the picker's choice).
    Q_INVOKABLE void playRow(int row) {
        if (row < 0 || row >= m_rows.size()) return;
        m_auto = false; m_decision.stop(); m_chosen = m_all[m_rows[row]].fields; resolve(m_all[m_rows[row]]);
    }
    // The pick turned out not to be one to watch, which its name didn't say: the TV failed to start it
    // (Kaleido-Flax's Demon Slayer BDs are 10-bit H.264), or the player read its tracks and found no sound
    // the TV plays or no subtitles (`why`, shown in the list). Its release (the torrent: one encode for
    // every episode in it) is left out and the next candidate is picked: for good (`forGood`) when the
    // file itself said so (its tracks, its video's profile), and until the app closes when the player
    // only failed or never started, which a bad connection does to a good release too (LG reports a
    // decoder's failure as "Network Error" as often as not). Only for our own pick (`ownPick`): a stream
    // chosen from the list plays as it is. `playable` or `failed` follow, maybe before this returns (a
    // link got ahead), so the caller clears the old stream first.
    Q_INVOKABLE bool ownPick() const { return m_auto; }
    Q_INVOKABLE void leaveOut(const QString &url, const QString &why, bool forGood) {
        if (!m_auto) return;
        const QString hash = hashOf(url);
        if (!hash.isEmpty() && forGood) { m_failed.setDir(m_dataDir); m_failed.data()[hash] = why; m_failed.save(); }
        else if (!hash.isEmpty()) m_leftOut[hash] = why;
        if (aiPicks().value(m_videoId).toString() == url) { aiPicks().remove(m_videoId); m_picks.save(); }
        leaveOutFailed();
        refilter();
        m_binge.clear();                                    // the release the episode before played is this one
        choose();
    }
    Q_INVOKABLE void cancel() { m_list.stop(); m_decision.stop(); m_link.stop(); m_auto = false; setStage(""); }
    // lab: what its cache holds and fetched (as Catalog.queries)
    Q_INVOKABLE QVariantMap queries() const { return m_queries.summary(); }
    // the listed row of the stream with this addon link, or -1
    Q_INVOKABLE int rowOf(const QString &url) const { for (int r = 0; r < m_rows.size(); r++) if (m_all[m_rows[r]].url == url) return r; return -1; }
    // tests: the anime rule's pick from an addon response (Torrentio's JSON), as play() would make it
    Q_INVOKABLE QVariantMap ruledPick(const QString &json) const {
        const QVector<Item> all = items(json.toUtf8(), true);
        const int i = ruled(all, candidates(all, true), QString(), true);
        return i >= 0 ? all[i].fields : QVariantMap();
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
    struct Listed { QVector<Item> items; bool anime = false; };             // a video's streams, and whether it is anime
    struct Decision { int index = -1; double confidence = 0; };            // the model's pick, by its place in the list
    using Read = std::shared_ptr<const Answer>;
    // What was asked for ahead is used as it is when its turn comes (a list for three hours, longer than
    // an episode; a link for one: TorBox's last hours); anything else is asked for each time.
    static constexpr qint64 kAhead = 3 * 60 * 60 * 1000, kLinkMs = 60 * 60 * 1000;
    static query::Options kept(qint64 freshMs) {
        query::Options o; o.freshMs = freshMs; o.keepMs = qMax<qint64>(freshMs, 5 * 60 * 1000); o.retries = 0;
        return o;
    }
    QString m_ahead, m_aheadLink;                       // the video whose list was asked for ahead, and the stream whose link was
    QString m_prepared;                                 // the video prepare() last ran for
    QString m_binge;

    // The decision model's instructions; the state names the video and whether it's anime.
    static QString rules() {
        return QStringLiteral(
            "Pick one stream to play on an LG C5 OLED TV. Every option plays on it and is cached. Rules, in order:\n"
            "1. Anime (it comes to you only when there is a Blu-ray): 1080p, not 4K. The best 1080p Blu-ray (BD, BDRip, BDRemux) from an established encoding group, with English subtitles as a track (MKV). Dual-audio and multi-subtitle releases are fine: the player switches to the Japanese track itself. Seeders show which releases people trust: a well-seeded release from a known group beats an obscure one with a handful. Prefer single-episode files to whole-series packs when quality is equal.\n"
            "2. Not anime: the best 4K HDR (Dolby Vision or HDR10), preferably Blu-ray; else the best 1080p.\n"
            "3. The original-language audio must be in a codec this TV plays: Dolby Digital, Dolby Digital Plus (Atmos and 7.1 too), AAC, MP3, Opus up to 5.1, or FLAC in stereo. It plays no DTS of any kind and no TrueHD, and loses the dialogue of FLAC 5.1 and Opus 7.1. A remux whose main track is TrueHD or DTS-HD is fine when it also carries a Dolby Digital track, which the player picks. The player switches to the original-language track wherever it sits. Skip foreign-market releases whose names are mainly another language (MVO, AVO, Cyrillic titles) or that carry only a dub.\n"
            "4. A re-release (v2, v3, REPACK, PROPER) fixes its original: prefer it to the same release without it.\n"
            "5. Among equals, more seeders.");
    }

    static bool good(const Read &a) { return a && a->status >= 200 && a->status < 300; }
    // why a read gave nothing: what Qt said of the service's no, or the failure as it came
    static query::Failure wrong(const Read &a, const query::Failure &why) { return a ? query::Failure { a->status, a->error } : why; }

    // The list being looked at or played from: its observer is pointed at the video. One asked for ahead
    // (`prefetch`) is there with no wait; any other is asked for now.
    void load(const QString &type, const QString &videoId) {
        m_decision.stop(); m_link.stop();                   // (a choice or a link on its way is the video's before)
        m_videoId = videoId;
        beginResetModel(); m_all.clear(); m_rows.clear(); endResetModel();
        const auto known = m_queries.peek<bool>({ "anime", videoId.section(':', 0, 0) });
        m_anime = videoId.startsWith("kitsu:") || (known && *known); m_loading = true; m_failure.clear(); m_mix.clear();
        emit listChanged();
        m_list.watch({ "streams", videoId }, listing(type, videoId), kept(videoId == m_ahead ? kAhead : 0));
        m_list.retell();                                    // (each asking is answered, the same video asked for again too)
    }
    void took(const query::Result<Listed> &r) {
        if (r.fetching || (!r.data && r.status != query::Error)) return;
        if (r.status == query::Error) { listed({}, r.error.reason); return; }
        m_anime = r.data->anime;
        listed(r.data->items, QString());
    }
    // A video's list as a query: the addon's streams read into items on a worker, and whether the video is
    // anime, asked alongside. (The ranking, the AI's rules and whose track choices the player uses go by
    // that: a Kitsu id is anime; an IMDb id is when the community anime mapping, Fribb's anime-lists
    // through ARM, lists it.)
    query::Fetch<Listed> listing(const QString &type, const QString &videoId) {
        return [this, type, videoId](query::Call<Listed> call) {
            struct Got { QByteArray body; query::Failure why; bool ok = false, anime = false; };
            auto got = std::make_shared<Got>();
            query::All all;
            const QString imdb = videoId.section(':', 0, 0);
            got->anime = videoId.startsWith("kitsu:");
            if (imdb.startsWith("tt")) isAnime(imdb, [got, in = all.part()](bool anime) { got->anime = anime; in(); });
            query::Options once; once.keepMs = 0; once.retries = 2;
            m_net.read(m_addon + "stream/" + type + "/" + videoId + ".json", QByteArray(), once, [got, in = all.part()](Read a, const query::Failure &why) {
                got->ok = good(a); got->why = wrong(a, why);
                if (a) got->body = a->body;
                in();
            });
            all.then([got, call] {
                if (!got->ok) { call.fail(got->why); return; }
                query::onWorker<Listed>([got] { return Listed { items(got->body, got->anime), got->anime }; })(call);
            });
        };
    }
    // An IMDb id's show is anime or not, as the mapping answers: kept for the session, and when it
    // couldn't be asked (ARM is given four seconds) not anime this once.
    void isAnime(const QString &imdb, std::function<void(bool)> done) {
        query::Options session; session.freshMs = session.keepMs = 24 * 60 * 60 * 1000; session.retries = 0;
        m_queries.fetch<bool>({ "anime", imdb }, [this, imdb](query::Call<bool> call) {
            query::Options once; once.keepMs = 0; once.retries = 0;
            m_quick.read("https://arm.haglund.dev/api/v2/imdb?id=" + imdb, QByteArray(), once, [call](Read a, const query::Failure &why) {
                if (good(a)) call.ok(!QJsonDocument::fromJson(a->body).array().isEmpty()); else call.fail(wrong(a, why));
            });
        }, session, [done](std::shared_ptr<const bool> anime, const query::Failure &) { done(anime && *anime); });
    }
    // an addon's response as stream items
    static QVector<Item> items(const QByteArray &body, bool anime) {
        QVector<Item> out;
        for (const QJsonValue &v : QJsonDocument::fromJson(body).object().value("streams").toArray()) {
            const QJsonObject s = v.toObject();
            const QString name = s.value("name").toString(), title = s.value("title").toString(), url = s.value("url").toString();
            const QString file = s.value("behaviorHints").toObject().value("filename").toString();
            QVariantMap fields = releases::read(name, title, url, anime);
            fields["bingeGroup"] = s.value("behaviorHints").toObject().value("bingeGroup").toString();
            out.append({ fields, QString(name).replace('\n', ' ') + " | " + QString(title).replace('\n', " | ") + " | file: " + file, url, file });
        }
        return out;
    }
    void listed(const QVector<Item> &all, const QString &failure) {
        m_all = all; m_loading = false; m_failure = failure;
        leaveOutFailed();
        const QString picked = aiPicks().value(m_videoId).toString();
        for (Item &it : m_all) it.fields["aiPick"] = !picked.isEmpty() && it.url == picked;
        m_kind = m_anime ? 0 : 1;
        refilter();
        if (m_auto) choose();
    }
    static QString hashOf(const QString &url) { static const QRegularExpression re("/([0-9a-f]{40})/"); return re.match(url).captured(1); }
    void leaveOutFailed() {
        m_failed.setDir(m_dataDir);
        for (Item &it : m_all) {
            const QString hash = hashOf(it.url);
            const QJsonValue why = m_failed.data().value(hash);
            if (!why.isUndefined() || m_leftOut.contains(hash)) { it.fields["support"] = "unsupported"; it.fields["why"] = m_leftOut.value(hash, why.toString("Didn't play")); }
        }
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

    // The candidates: what plays here and is cached (and, for anime, carries its subtitles as a track), best first. The decision model is asked about the
    // first 255 (what a choice question takes); the rules before it see them all.
    static QVector<int> candidates(const QVector<Item> &all, bool anime) {
        QVector<int> c;
        for (int i = 0; i < all.size(); i++) if (all[i].fields["support"] != "unsupported" && all[i].fields["cached"].toBool() && !all[i].fields["noSubtitleTrack"].toBool()) c << i;
        // anime: 1080p first, then 4K; anything else: 4K first. A re-release (v2, REPACK) beats its original.
        auto rank = [&all, anime](int i) { const QVariantMap &f = all[i].fields; const QString r = f["res"].toString();
                                    const int res = anime ? (r == "1080p" ? 2 : r == "4K" ? 1 : 0) : (r == "4K" ? 2 : r == "1080p" ? 1 : 0);
                                    return res * 2000000 + (f["version"].toString().isEmpty() ? 0 : 1000000) + qMin(f["seeders"].toInt(), 999999); };
        std::stable_sort(c.begin(), c.end(), [&](int a, int b) { return rank(a) > rank(b); });
        return c;
    }
    void choose() {
        m_decision.stop(); m_link.stop();                   // (a choice or a link on its way is the pick's before)
        const QVector<int> c = candidates(m_all, m_anime);
        if (c.isEmpty()) { fail(m_all.isEmpty() ? (m_failure.isEmpty() ? "No streams yet" : m_failure) : "Nothing cached plays on this TV"); return; }
        // the release the episode before played; else the one picked for this video before (an episode
        // played again is the same file again, not whatever the model says this time); else the rule
        int i = ruled(m_all, c, m_binge, false);
        const QString before = aiPicks().value(m_videoId).toString();
        for (int k = 0; i < 0 && !before.isEmpty() && k < c.size(); k++) if (m_all[c[k]].url == before) i = c[k];
        if (i < 0) i = ruled(m_all, c, QString(), m_anime);
        if (i >= 0) { pick(i); return; }
        // one candidate needs no decision; without a key (the lab's tours) the best by rank plays
        if (c.size() == 1 || m_openrouter.isEmpty() || m_decider.isEmpty()) { pick(c[0]); return; }
        setStage("choosing");
        const QVector<int> asked = c.mid(0, 255);
        QJsonObject criteria;
        for (int i : asked) criteria["s" + QString::number(i)] = m_all[i].option;
        const QByteArray body = QJsonDocument(QJsonObject {
            { "model", m_decider },
            { "state", QJsonObject { { "video", m_title + (m_anime ? " (anime)" : "") }, { "rules", rules() } } },
            { "questions", QJsonObject { { "pick", QJsonObject { { "type", "choice" }, { "instructions", "Which stream should play, following the rules?" }, { "criteria", criteria } } } } } }).toJson(QJsonDocument::Compact);
        // The decision is a query by what was asked: an answer that names no stream asked about is a
        // failure like one that never came, tried again twice (0.4 s, then 0.8 s on) before it shows.
        // Left (cancelled, another pick), it is asked no more.
        query::Options o; o.keepMs = 0; o.retries = 2; o.finishUnobserved = false;
        o.retryDelay = [](int n, const query::Failure &) { return 400 * n; };
        m_decision.watch({ "decision", m_videoId, QString::fromLatin1(QCryptographicHash::hash(body, QCryptographicHash::Sha1).toHex()) }, [this, body, asked](query::Call<Decision> call) {
            const Net::Headers with { { "Authorization", "Bearer " + m_openrouter.toUtf8() }, { "X-Title", "Seimio" } };
            m_net.send("https://openrouter.ai/api/alpha/decisions", body, [call, asked](const QByteArray &data, bool ok, int status) {
                const QJsonObject a = QJsonDocument::fromJson(data).object().value("answers").toObject().value("pick").toObject();
                const QString choice = a.value("choice").toString();
                const int i = choice.mid(1).toInt();
                if (ok && choice.startsWith('s') && asked.contains(i)) { call.ok(Decision { i, a.value("probabilities").toObject().value(choice).toDouble() }); return; }
                const QString why = ok ? QString("no usable choice") : QString::number(status) + " " + QString::fromUtf8(data.left(200));
                qWarning("decision attempt %d failed: %s", call.attempt(), qPrintable(why));
                call.fail(query::Failure { status, why });
            }, true, with);
        }, o);
        m_decision.retell();
    }
    void decided(const query::Result<Decision> &r) {
        if (r.fetching || (!r.data && r.status != query::Error)) return;
        if (r.status == query::Error) { fail("The AI pick didn't answer"); return; }
        const int i = r.data->index;
        m_all[i].fields["confidence"] = r.data->confidence;
        remember(i);
        pick(i);
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
    void pick(int i) { m_chosen = m_all[i].fields; resolve(m_all[i]); }

    // the AI picks so far, by video id: { videoId: the stream's addon url }
    QJsonObject &aiPicks() { m_picks.setDir(m_dataDir); return m_picks.data(); }
    void remember(int i) {
        aiPicks()[m_videoId] = m_all[i].url;
        m_picksStatus = m_picks.save();
        for (int k = 0; k < m_all.size(); k++) m_all[k].fields["aiPick"] = k == i;
        if (!m_rows.isEmpty()) emit dataChanged(index(0), index(m_rows.size() - 1));
    }

    // The pick without the AI, or -1: the same release as the episode before (the first in the addon's
    // order with its binge group), then, for anime with no Blu-ray, the anime rule
    static int ruled(const QVector<Item> &all, const QVector<int> &c, const QString &binge, bool anime) {
        if (!binge.isEmpty()) for (int i = 0; i < all.size(); i++) if (all[i].fields["bingeGroup"].toString() == binge && c.contains(i)) return i;
        if (!anime) return -1;
        QVector<QVariantMap> fields; for (const Item &it : all) fields << it.fields;
        return animeRule(fields, c);
    }
    // The pick's link, watched: the one got ahead (Up next) is there within the hour, any other is asked
    // for now. With no link from TorBox the stream's own address plays, through the addon's resolver.
    void resolve(const Item &item) {
        setStage("resolving");
        const bool ahead = item.url == m_aheadLink;
        m_aheadLink.clear();                                // (once: played again, its link is asked for again)
        m_link.watch({ "link", item.url }, linking(item.url), kept(ahead ? kLinkMs : 0));
        m_link.retell();                                    // (each asking is answered, the same stream picked again too)
    }
    void linked(const query::Result<QString> &r) {
        if (r.fetching || (!r.data && r.status != query::Error)) return;
        setStage("");
        emit playable(m_chosen, r.data ? *r.data : m_chosen.value("url").toString());
    }
    // TorBox's direct link for a Torrentio stream, as a query: add the torrent, find the file, request its
    // link. Without one it fails, and nothing is kept of that.
    query::Fetch<QString> linking(const QString &streamUrl) {
        return [this, streamUrl](query::Call<QString> call) {
            // (why, in the lab's list: which step gave nothing, and what TorBox said there)
            const auto none = [call](const QString &why) { query::Failure f; f.reason = why.left(160); f.final = true; call.fail(f); };
            const QString hash = hashOf(streamUrl);
            if (hash.isEmpty() || m_torbox.isEmpty()) { none("no TorBox link to get"); return; }
            const QString want = QUrl::fromPercentEncoding(streamUrl.section('/', -1).toUtf8());
            QUrlQuery form; form.addQueryItem("magnet", "magnet:?xt=urn:btih:" + hash); form.addQueryItem("allow_zip", "false");
            torbox("torrents/createtorrent", form.toString(QUrl::FullyEncoded).toUtf8(), [this, want, call, none](const QJsonObject &o, const QString &err) {
                const int id = o.value("data").toObject().value("torrent_id").toInt();
                if (!err.isEmpty() || !id) { qWarning("torbox add failed: %s", qPrintable(err)); none("the torrent wasn't added: " + err); return; }
                torbox(QString("torrents/mylist?bypass_cache=true&id=%1").arg(id), QByteArray(), [this, id, want, call, none](const QJsonObject &o, const QString &err) {
                    QJsonObject best; double size = -1;
                    for (const QJsonValue &v : o.value("data").toObject().value("files").toArray()) {
                        const QJsonObject f = v.toObject();
                        if (f.value("short_name").toString() == want || f.value("name").toString().endsWith(want)) { best = f; break; }
                        if (f.value("size").toDouble() > size) { size = f.value("size").toDouble(); best = f; }
                    }
                    if (!err.isEmpty() || best.isEmpty()) {
                        const QJsonObject t = o.value("data").toObject();
                        none("its file wasn't found: " + (err.isEmpty() ? t.value("download_state").toString("no state") + ", " + QString::number(t.value("files").toArray().size()) + " files" : err));
                        return;
                    }
                    torbox(QString("torrents/requestdl?token=%1&torrent_id=%2&file_id=%3&redirect=false").arg(m_torbox).arg(id).arg(best.value("id").toInt()), QByteArray(),
                           [call, none](const QJsonObject &o, const QString &err) {
                        const QString link = err.isEmpty() ? o.value("data").toString() : QString();
                        if (link.isEmpty()) none("no link came: " + err); else call.ok(link);
                    });
                });
            });
        };
    }
    // one request of TorBox's API (a form posted when `form` has one): `done(its JSON, "" or what went wrong)`
    void torbox(const QString &path, const QByteArray &form, std::function<void(const QJsonObject &, const QString &)> done) {
        Net::Headers with { { "Authorization", "Bearer " + m_torbox.toUtf8() } };
        if (!form.isEmpty()) with << qMakePair(QByteArray("Content-Type"), QByteArray("application/x-www-form-urlencoded"));
        m_net.send("https://api.torbox.app/v1/api/" + path, form, [done](const QByteArray &body, bool ok, int status) {
            done(QJsonDocument::fromJson(body).object(), ok ? QString() : QString::number(status) + " " + QString::fromUtf8(body.left(200)));
        }, true, with);
    }
    void fail(const QString &reason) { setStage(""); m_auto = false; emit failed(reason); }
    void setStage(const QString &s) { if (s != m_stage) { m_stage = s; emit stageChanged(); } }

    QNetworkAccessManager m_wire;                       // wire: Net's to go out through, and where the connections opened ahead are kept
    query::Queries m_queries { this };
    // (never from a preview's recordings: what it asks for carries the account's keys)
    Net m_net { &m_queries, this, &m_wire, false };
    Net m_quick { &m_queries, this, &m_wire, false };   // ARM's: given four seconds, the list waits no longer for it
    query::Observer<Listed> m_list { &m_queries, [this](const query::Result<Listed> &r) { took(r); } };
    query::Observer<Decision> m_decision { &m_queries, [this](const query::Result<Decision> &r) { decided(r); } };
    query::Observer<QString> m_link { &m_queries, [this](const query::Result<QString> &r) { linked(r); } };
    QString m_addon, m_torbox, m_openrouter, m_decider = "typesafe/jev-1.14", m_title, m_failure, m_stage, m_videoId;
    JsonStore m_picks { "ai-picks.json" };
    JsonStore m_failed { "failed-releases.json" };      // torrent hash -> why: picks whose file said it's unwatchable (leaveOut)
    QHash<QString, QString> m_leftOut;                  // the same for this run: picks that failed or never started
    QString m_dataDir, m_picksStatus;
    QVector<Item> m_all;
    QVector<int> m_rows;
    QVariantMap m_mix, m_chosen;
    int m_kind = 0;
    bool m_anime = false, m_loading = false, m_auto = false;
};
