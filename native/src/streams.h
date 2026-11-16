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
    return {
        { "release", lines.value(0) },
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
    };
}

} // namespace releases

class Streams : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString addon MEMBER m_addon NOTIFY addonChanged)     // the addon's base URL, ending in /
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
public:
    bool loading() const { return m_loading; }
    // Fetches the streams for a video ("movie", "tt..." or "series", "kitsu:N:E"); `ready` follows, with
    // an empty list and a reason when it failed. A newer fetch replaces an older one.
    Q_INVOKABLE void fetch(const QString &type, const QString &videoId) {
        const int ticket = ++m_ticket;
        setLoading(true);
        QNetworkRequest request(QUrl(m_addon + "stream/" + type + "/" + videoId + ".json"));
        request.setHeader(QNetworkRequest::UserAgentHeader, "seimio/0.1");
        request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
        QNetworkReply *reply = m_net.get(request);
        const bool anime = videoId.startsWith("kitsu:");
        connect(reply, &QNetworkReply::finished, this, [this, reply, ticket, anime] {
            reply->deleteLater();
            if (ticket != m_ticket) return;
            if (reply->error() != QNetworkReply::NoError) { setLoading(false); emit ready({}, reply->errorString()); return; }
            auto out = std::make_shared<QVariantList>();
            QThread *worker = QThread::create([out, body = reply->readAll(), anime] {
                for (const QJsonValue &v : QJsonDocument::fromJson(body).object().value("streams").toArray()) {
                    const QJsonObject s = v.toObject();
                    out->append(releases::read(s.value("name").toString(), s.value("title").toString(), s.value("url").toString(), anime));
                }
            });
            connect(worker, &QThread::finished, this, [this, out, ticket] { if (ticket == m_ticket) { setLoading(false); emit ready(*out, QString()); } });
            connect(worker, &QThread::finished, worker, &QObject::deleteLater);
            worker->start();
        });
    }
    // reads one stream's text, for tests
    Q_INVOKABLE QVariantMap read(const QString &name, const QString &title, bool anime) const { return releases::read(name, title, QString(), anime); }
signals:
    void addonChanged();
    void loadingChanged();
    void ready(const QVariantList &streams, const QString &failure);
private:
    void setLoading(bool on) { if (m_loading != on) { m_loading = on; emit loadingChanged(); } }
    QNetworkAccessManager m_net;
    QString m_addon;
    bool m_loading = false;
    int m_ticket = 0;
};
