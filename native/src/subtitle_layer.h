#pragma once
// SubtitleLayer: draws the chosen subtitle track over the video with libass. Its `source` is the Tee,
// which hands over every text subtitle track's header and blocks as the player's bytes pass through, and
// the file's fonts; every track's blocks are kept, so switching tracks is instant and needs no download.
// Matroska ASS blocks go to libass as they are (ass_process_chunk, as mpv feeds it); SRT text becomes the
// same with a plain style (as stremio-webos service/srt-ass.js did). Image subtitles, Blu-ray's PGS
// (pgs.h) and DVD's VobSub (vobsub.h), are decoded when the picture on screen changes.
//
// All the subtitle work happens on its own thread (SubtitleWorker): the blocks and fonts come straight
// from the Tee's thread, libass parses, lays out and draws there, and the GUI thread only receives the
// finished image when a frame changes. On the TV, doing this on the GUI thread cost 20-120 ms stalls
// (thousands of blocks arriving as the player reads ahead, font setup on the first frame).
//
// The clock is the player's `position`, moved on smoothly between its updates while `playing`, minus
// `delay` (ms; positive shows subtitles later).
//
// Subtitles for files without them come from Stremio's OpenSubtitles addon: fetchAddon() lists them
// (up to three per language) as external tracks numbered from 1000, and one is downloaded and read
// (SRT) only when it's chosen. The addon knows IMDb ids only; an anime's Kitsu episode is mapped to its
// IMDb season and episode by Stremio's Kitsu addon (as Torrentio maps them), once per show.
#include <QtQml>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSGSimpleTextureNode>
#include <QElapsedTimer>
#include <QTimer>
#include <QImage>
#include <QThread>
#include <atomic>
#include <ass/ass.h>
#include "net.h"
#include "tee.h"
#include "pgs.h"
#include "vobsub.h"

class SubtitleWorker : public QObject {
    Q_OBJECT
public:
    SubtitleWorker() {
        m_lib = ass_library_init();
        ass_set_extract_fonts(m_lib, 1);
        m_renderer = ass_renderer_init(m_lib);
        ass_set_frame_size(m_renderer, 1920, 1080);
        ass_set_storage_size(m_renderer, 1920, 1080);
    }
    ~SubtitleWorker() override {
        if (m_track) ass_free_track(m_track);
        ass_renderer_done(m_renderer);
        ass_library_done(m_lib);
    }
public slots:
    void start() {
        m_tick = new QTimer(this); m_tick->setInterval(16); connect(m_tick, &QTimer::timeout, this, [this] { render(); });
        // What it asks of the network are queries of this thread's own cache (query.h): a show's Kitsu
        // ids to IMDb kept a day, a video's list of subtitles ten minutes, and only the video asked for
        // last answers.
        m_queries = new query::Queries(this);
        m_http = new Net(m_queries, this);
        m_http->idleMs = 15000;
        m_listing.reset(new query::Observer<QJsonArray>(m_queries, [this](const query::Result<QJsonArray> &r) { listed(r); }));
    }
    // lists the addon's subtitles for a video: ("movie", "tt…"), ("series", "tt…:1:2"), or a Kitsu id
    // ("kitsu:N:episode", "kitsu:N" for a film), mapped to IMDb first
    void fetchAddon(const QString &type, const QString &videoId) {
        query::Options kept; kept.freshMs = kept.keepMs = 10 * 60 * 1000; kept.retries = 0;
        m_listing->watch({ "subtitles", type, videoId }, [this, type, videoId](query::Call<QJsonArray> call) { list(type, videoId, call); }, kept);
        m_listing->retell();                            // (each asking is answered, the same video asked for again too)
    }
private:
    using Ids = QHash<QString, QString>;
    using Read = std::shared_ptr<const Answer>;
    // (a read that went wrong is not kept: the list or the ids are asked for again the next time)
    static query::Failure wrong(const Read &a, const query::Failure &why) { return a ? query::Failure { a->status, "refused" } : why; }
    static bool good(const Read &a) { return a && a->status >= 200 && a->status < 300; }
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
        emit addonListed(out);
    }
public slots:
    void reset() {
        m_tracks.clear(); m_number = -1; m_external.clear(); if (m_listing) m_listing->stop();
        if (m_track) { ass_free_track(m_track); m_track = nullptr; }
        ass_clear_fonts(m_lib); m_fontsChanged = true; statTracks = 0; statBlocks = 0; statFonts = 0;
        emit frame(QImage(), QRect()); updateTick();
    }
    void addHeader(int number, const QString &codec, const QByteArray &header) {
        Track &t = m_tracks[number]; statTracks = m_tracks.size();
        t.srt = codec.startsWith("S_TEXT/UTF8") || codec == "tx3g";
        t.image = codec == "S_HDMV/PGS" ? 1 : codec == "S_VOBSUB" ? 2 : 0;
        if (t.image == 2) t.vob.setHeader(header);
        t.header = t.srt ? srtHeader() : header;
        if (number == m_number) rebuild();
    }
    void addBlock(int number, qint64 start, qint64 duration, const QByteArray &payload) {
        auto it = m_tracks.find(number);
        if (it != m_tracks.end() && it->image) {
            // a window around where the player reads (see pgs.h); the picture showing is picked up on the next tick
            if (it->image == 1 ? it->pgs.add(start, duration, payload) : it->vob.add(start, duration, payload)) {
                statBlocks++;
                if (number == m_number && start == m_shownSet) m_shownSet = -2;   // more of the set on screen
            }
            if (it->image == 1) it->pgs.keepNear(start); else it->vob.keepNear(start);
            if (number == m_number && !m_playing) render();
            return;
        }
        if (it == m_tracks.end() || it->header.isEmpty()) return;                // VobSub has no header
        // the same block comes again after a seek: keep one
        const QByteArray key = QByteArray::number(start) + ':' + payload.left(48);
        if (it->seen.contains(key)) return;
        it->seen.insert(key);
        QByteArray data = it->srt ? srtChunk(it->readOrder++, payload) : payload;
        if (data.isEmpty()) return;
        it->blocks.append({ start, qMax<qint64>(duration, it->srt ? 60 : 0), data }); statBlocks++;
        if (number == m_number && m_track) { Block &b = it->blocks.last(); ass_process_chunk(m_track, b.data.data(), b.data.size(), b.start, b.duration); }
    }
    void addFont(const QString &name, const QByteArray &data) {
        ass_add_font(m_lib, name.toUtf8().constData(), data.constData(), data.size());
        m_fontsChanged = true; statFonts++;
    }
    void setTrack(int number) {
        if (number == m_number) return;
        m_number = number;
        if (m_external.contains(number) && !m_tracks.contains(number)) download(number);
        rebuild();
    }
    // the player's clock: its position (ms) as of now, whether it's moving, and the delay
    void setClock(double position, bool playing, int delay) {
        m_position = position; m_playing = playing; m_delay = delay; m_since.restart();
        updateTick();
        if (!playing) render();
    }
public:
    // for the lab, read from the GUI thread without waiting on this one
    std::atomic<int> statTracks { 0 }, statBlocks { 0 }, statFrames { 0 }, statFonts { 0 };
signals:
    void frame(const QImage &image, const QRect &box);
    void addonListed(const QVariantList &subtitles);
private:
    struct Block { qint64 start, duration; QByteArray data; };
    // image: 1 PGS, 2 VobSub
    struct Track { QByteArray header; bool srt = false; int image = 0; QVector<Block> blocks; QSet<QByteArray> seen; int readOrder = 0; Pgs pgs; VobSub vob; };

    // An addon subtitle: SRT, read whole into a track like an embedded SRT one. (Its file is a query by its
    // address; it belongs to this video while the list still has it under this number.)
    void download(int number) {
        const QString url = m_external.value(number);
        query::Options kept; kept.freshMs = kept.keepMs = 10 * 60 * 1000; kept.retries = 2;
        m_http->read(url, QByteArray(), kept, [this, number, url](Read file, const query::Failure &) {
            if (m_external.value(number) != url || m_tracks.contains(number) || !good(file)) return;
            static const QRegularExpression cue("(\\d+):(\\d\\d):(\\d\\d)[,.](\\d{1,3})\\s*-->\\s*(\\d+):(\\d\\d):(\\d\\d)[,.](\\d{1,3})");
            auto ms = [](const QRegularExpressionMatch &m, int at) {
                return ((m.captured(at).toLongLong() * 60 + m.captured(at + 1).toLongLong()) * 60 + m.captured(at + 2).toLongLong()) * 1000
                       + QString(m.captured(at + 3) + "00").left(3).toLongLong(); };
            Track &t = m_tracks[number]; t.srt = true; t.header = srtHeader(); statTracks = m_tracks.size();
            const QStringList lines = QString::fromUtf8(file->body).remove('\r').split('\n');
            for (int i = 0; i < lines.size(); i++) {
                const auto m = cue.match(lines[i]);
                if (!m.hasMatch()) continue;
                QStringList text;
                while (i + 1 < lines.size() && !lines[i + 1].trimmed().isEmpty()) text << lines[++i];
                const QByteArray chunk = srtChunk(t.readOrder++, text.join('\n').toUtf8());
                if (!chunk.isEmpty()) { const qint64 a = ms(m, 1), b = ms(m, 5); t.blocks.append({ a, qMax<qint64>(b - a, 60), chunk }); statBlocks++; }
            }
            if (number == m_number) rebuild();
        });
    }
    void rebuild() {
        if (m_track) { ass_free_track(m_track); m_track = nullptr; }
        m_shownSet = -2;
        auto it = m_tracks.find(m_number);
        if (it != m_tracks.end() && !it->image && !it->header.isEmpty()) {
            m_track = ass_new_track(m_lib);
            ass_process_codec_private(m_track, it->header.data(), it->header.size());
            for (Block &b : it->blocks) ass_process_chunk(m_track, b.data.data(), b.data.size(), b.start, b.duration);
        }
        emit frame(QImage(), QRect()); updateTick(); render();
    }
    bool imageTrack() const { auto it = m_tracks.constFind(m_number); return it != m_tracks.constEnd() && it->image; }
    void updateTick() { if (!m_tick) return; if (m_playing && (m_track || imageTrack())) { if (!m_tick->isActive()) m_tick->start(); } else m_tick->stop(); }
    qint64 now() const { return qint64(m_position) + (m_playing ? m_since.elapsed() : 0) - m_delay; }
    void render() {
        if (imageTrack()) {                                                    // only when the picture on screen changes
            const Track &t = m_tracks[m_number];
            const qint64 set = t.image == 1 ? t.pgs.at(now()) : t.vob.at(now());
            if (set == m_shownSet) return;
            m_shownSet = set;
            QRect box; QImage out = set < 0 ? QImage() : t.image == 1 ? t.pgs.render(set, box) : t.vob.render(set, box);
            statFrames++;
            emit frame(out, box);
            return;
        }
        if (!m_track) return;
        // the default font is the one libass falls back to for any glyph a style's font lacks (there's no
        // font provider on the TV to find another): LG's UI face covers Latin, Cyrillic, CJK, Hangul,
        // Arabic and symbols (DroidSans drew ♪ and Japanese as boxes); FreeType reads it from the file
        if (m_fontsChanged) { ass_set_fonts(m_renderer, "/usr/share/fonts/LG_Display-Regular.ttf", "sans-serif", ASS_FONTPROVIDER_NONE, nullptr, 0); m_fontsChanged = false; }
        int changed = 0;
        ASS_Image *img = ass_render_frame(m_renderer, m_track, now(), &changed);
        if (!changed) return;
        QRect box;
        for (ASS_Image *p = img; p; p = p->next) box |= QRect(p->dst_x, p->dst_y, p->w, p->h);
        QImage out;
        if (!box.isEmpty()) {
            out = QImage(box.size(), QImage::Format_ARGB32_Premultiplied);
            out.fill(0);
            for (ASS_Image *p = img; p; p = p->next) blend(out, box.topLeft(), p);
        }
        statFrames++;
        emit frame(out, box);
    }
    static QByteArray srtHeader() {
        return "[Script Info]\nScriptType: v4.00+\nPlayResX: 1920\nPlayResY: 1080\nWrapStyle: 0\nScaledBorderAndShadow: yes\n\n"
               "[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n"
               "Style: Default,Liberation Sans,60,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,3,0,2,60,60,40,1\n\n"
               "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n";
    }
    // SRT text as a Matroska ASS block ("ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text")
    static QByteArray srtChunk(int readOrder, const QByteArray &payload) {
        QString t = QString::fromUtf8(payload).remove('\r');
        static const QRegularExpression braces("\\{([^}]*)\\}"), an("^\\\\an[1-9]$"), tag("<[^>]+>");
        for (auto m = braces.match(t); m.hasMatch(); m = braces.match(t, m.capturedStart() + 1))
            if (!an.match(m.captured(1).trimmed()).hasMatch()) t.remove(m.capturedStart(), m.capturedLength());
        const auto ci = QRegularExpression::CaseInsensitiveOption;
        t.replace(QRegularExpression("<\\s*i\\s*>", ci), "{\\i1}").replace(QRegularExpression("<\\s*/\\s*i\\s*>", ci), "{\\i0}")
         .replace(QRegularExpression("<\\s*b\\s*>", ci), "{\\b1}").replace(QRegularExpression("<\\s*/\\s*b\\s*>", ci), "{\\b0}")
         .replace(QRegularExpression("<\\s*u\\s*>", ci), "{\\u1}").replace(QRegularExpression("<\\s*/\\s*u\\s*>", ci), "{\\u0}")
         .remove(tag);
        t = t.trimmed().replace('\n', "\\N");
        return t.isEmpty() ? QByteArray() : (QString::number(readOrder) + ",0,Default,,0,0,0,," + t).toUtf8();
    }
    static void blend(QImage &out, QPoint origin, ASS_Image *p) {
        uint r = p->color >> 24, g = (p->color >> 16) & 255, b = (p->color >> 8) & 255, a = 255 - (p->color & 255);
        for (int y = 0; y < p->h; y++) {
            auto row = reinterpret_cast<uint *>(out.scanLine(p->dst_y - origin.y() + y)) + (p->dst_x - origin.x());
            const uchar *src = p->bitmap + y * p->stride;
            for (int x = 0; x < p->w; x++) {
                uint k = src[x] * a / 255;
                if (!k) continue;
                uint d = row[x], inv = 255 - k;
                row[x] = ((k + (d >> 24) * inv / 255) << 24) | ((r * k + ((d >> 16) & 255) * inv) / 255 << 16)
                       | ((g * k + ((d >> 8) & 255) * inv) / 255 << 8) | ((b * k + (d & 255) * inv) / 255);
            }
        }
    }
    ASS_Library *m_lib = nullptr;
    ASS_Renderer *m_renderer = nullptr;
    ASS_Track *m_track = nullptr;
    QHash<int, Track> m_tracks;
    QTimer *m_tick = nullptr;
    query::Queries *m_queries = nullptr;                // (made on the worker's thread: `start`)
    Net *m_http = nullptr;
    std::unique_ptr<query::Observer<QJsonArray>> m_listing;     // the list of the video playing
    QHash<int, QString> m_external;
    qint64 m_shownSet = -2;                 // the image subtitle on screen, by start (-1 none, -2 not drawn yet)
    QElapsedTimer m_since;
    double m_position = 0;
    int m_number = -1, m_delay = 0;
    bool m_playing = false, m_fontsChanged = true;
};

class SubtitleLayer : public QQuickItem {
    Q_OBJECT
    Q_PROPERTY(QObject *source READ source WRITE setSource NOTIFY sourceChanged)
    Q_PROPERTY(int track READ track WRITE setTrack NOTIFY trackChanged)         // a track number, or -1 for none
    Q_PROPERTY(double position READ position WRITE setPosition)                 // the player's position, ms
    Q_PROPERTY(bool playing READ playing WRITE setPlaying)
    Q_PROPERTY(int delay READ delay WRITE setDelay NOTIFY delayChanged)
    // px (of 1080) to raise lines in the lower part of the picture, clear of the player's controls; a
    // line placed high (a sign, a PGS line moved for the credits) stays where it is
    Q_PROPERTY(qreal lift READ lift WRITE setLift NOTIFY liftChanged)
public:
    SubtitleLayer() {
        setFlag(ItemHasContents);
        m_worker = new SubtitleWorker;
        m_worker->moveToThread(&m_thread);
        connect(&m_thread, &QThread::finished, m_worker, &QObject::deleteLater);
        connect(m_worker, &SubtitleWorker::frame, this, [this](const QImage &image, const QRect &box) { m_image = image; m_box = box; m_dirty = true; update(); });
        connect(m_worker, &SubtitleWorker::addonListed, this, &SubtitleLayer::addonListed);
        m_thread.start();
        QMetaObject::invokeMethod(m_worker, "start", Qt::QueuedConnection);
    }
    ~SubtitleLayer() override { m_thread.quit(); m_thread.wait(); }
    QObject *source() const { return m_source; }
    void setSource(QObject *o) {
        if (o == m_source) return;
        if (m_source) disconnect(m_source, nullptr, m_worker, nullptr);
        m_source = o;
        if (auto tee = qobject_cast<Tee *>(o)) {
            connect(tee, &Tee::subtitleHeader, m_worker, &SubtitleWorker::addHeader);
            connect(tee, &Tee::subtitleBlock, m_worker, &SubtitleWorker::addBlock);
            connect(tee, &Tee::font, m_worker, &SubtitleWorker::addFont);
        }
        emit sourceChanged();
    }
    int track() const { return m_track; }
    void setTrack(int n) { if (n == m_track) return; m_track = n; QMetaObject::invokeMethod(m_worker, "setTrack", Qt::QueuedConnection, Q_ARG(int, n)); emit trackChanged(); }
    double position() const { return m_position; }
    void setPosition(double ms) { m_position = ms; clock(); }
    bool playing() const { return m_playing; }
    void setPlaying(bool on) { if (on == m_playing) return; m_playing = on; clock(); }
    int delay() const { return m_delay; }
    qreal lift() const { return m_lift; }
    void setLift(qreal px) { if (px == m_lift) return; m_lift = px; m_moved = true; update(); emit liftChanged(); }
    void setDelay(int ms) { if (ms == m_delay) return; m_delay = ms; clock(); emit delayChanged(); }
    Q_INVOKABLE void fetchAddon(const QString &type, const QString &videoId) { QMetaObject::invokeMethod(m_worker, "fetchAddon", Qt::QueuedConnection, Q_ARG(QString, type), Q_ARG(QString, videoId)); }
    // a new stream: forget its tracks and fonts
    Q_INVOKABLE void reset() { m_track = -1; QMetaObject::invokeMethod(m_worker, "reset", Qt::QueuedConnection); emit trackChanged(); }
    // for the lab: tracks, blocks, frames drawn
    Q_INVOKABLE QString info() const {
        return QString("tracks %1 blocks %2 track %3 frames %4 fonts %5").arg(m_worker->statTracks).arg(m_worker->statBlocks).arg(m_track).arg(m_worker->statFrames).arg(m_worker->statFonts);
    }
signals:
    void addonListed(const QVariantList &subtitles);
    void sourceChanged();
    void trackChanged();
    void delayChanged();
    void liftChanged();
protected:
    QSGNode *updatePaintNode(QSGNode *old, UpdatePaintNodeData *) override {
        auto node = static_cast<QSGSimpleTextureNode *>(old);
        if (!m_dirty && !(m_moved && node)) return node;
        if (m_dirty) {
            m_dirty = false;
            if (m_image.isNull()) { delete node; return nullptr; }
            if (!node) { node = new QSGSimpleTextureNode; node->setOwnsTexture(true); }
            node->setTexture(window()->createTextureFromImage(m_image));
        }
        m_moved = false;
        const qreal up = m_box.bottom() > 760 ? m_lift : 0;
        node->setRect(QRectF(m_box.x() * width() / 1920, (m_box.y() - up) * height() / 1080, m_box.width() * width() / 1920, m_box.height() * height() / 1080));
        return node;
    }
private:
    void clock() { QMetaObject::invokeMethod(m_worker, "setClock", Qt::QueuedConnection, Q_ARG(double, m_position), Q_ARG(bool, m_playing), Q_ARG(int, m_delay)); }
    QThread m_thread;
    SubtitleWorker *m_worker;
    QPointer<QObject> m_source;
    int m_track = -1, m_delay = 0;
    double m_position = 0;
    bool m_playing = false, m_dirty = false, m_moved = false;
    qreal m_lift = 0;
    QImage m_image;
    QRect m_box;
};
