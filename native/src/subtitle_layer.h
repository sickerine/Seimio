#pragma once
// SubtitleLayer: draws the chosen subtitle track over the video with libass. Its `source` is the Tee,
// which hands over every text subtitle track's header and blocks as the player's bytes pass through, and
// the file's fonts; the layer keeps every track's blocks, so switching tracks is instant and needs no
// download. Matroska ASS blocks go to libass as they are (ass_process_chunk, as mpv feeds it); SRT text
// becomes the same with a plain style (as stremio-webos service/srt-ass.js did).
//
// The clock is the player's `position`, moved on smoothly between its updates while `playing`, minus
// `delay` (ms; positive shows subtitles later). It draws only while there's a track: libass reports
// when a frame changes, and only then is the image blended and uploaded.
#include <QtQml>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSGSimpleTextureNode>
#include <QElapsedTimer>
#include <QTimer>
#include <QImage>
#include <ass/ass.h>
#include "tee.h"

class SubtitleLayer : public QQuickItem {
    Q_OBJECT
    Q_PROPERTY(QObject *source READ source WRITE setSource NOTIFY sourceChanged)
    Q_PROPERTY(int track READ track WRITE setTrack NOTIFY trackChanged)         // a track number, or -1 for none
    Q_PROPERTY(double position READ position WRITE setPosition)                 // the player's position, ms
    Q_PROPERTY(bool playing READ playing WRITE setPlaying)
    Q_PROPERTY(int delay READ delay WRITE setDelay NOTIFY delayChanged)
public:
    // for the lab: tracks, blocks, frames drawn
    Q_INVOKABLE QString info() const {
        int blocks = 0; for (const Track &t : m_tracks) blocks += t.blocks.size();
        return QString("tracks %1 blocks %2 track %3 frames %4 fonts %5").arg(m_tracks.size()).arg(blocks).arg(m_trackNumber).arg(m_frames).arg(m_fonts);
    }
    SubtitleLayer() {
        setFlag(ItemHasContents);
        m_lib = ass_library_init();
        ass_set_extract_fonts(m_lib, 1);
        m_renderer = ass_renderer_init(m_lib);
        ass_set_frame_size(m_renderer, 1920, 1080);
        ass_set_storage_size(m_renderer, 1920, 1080);
        m_tick.setInterval(16);
        connect(&m_tick, &QTimer::timeout, this, [this] { render(); });
    }
    ~SubtitleLayer() override {
        if (m_track) ass_free_track(m_track);
        ass_renderer_done(m_renderer);
        ass_library_done(m_lib);
    }
    QObject *source() const { return m_source; }
    void setSource(QObject *o) {
        if (o == m_source) return;
        if (m_source) disconnect(m_source, nullptr, this, nullptr);
        m_source = o;
        if (auto tee = qobject_cast<Tee *>(o)) {
            connect(tee, &Tee::subtitleHeader, this, &SubtitleLayer::addHeader);
            connect(tee, &Tee::subtitleBlock, this, &SubtitleLayer::addBlock);
            connect(tee, &Tee::font, this, &SubtitleLayer::addFont);
        }
        emit sourceChanged();
    }
    int track() const { return m_trackNumber; }
    void setTrack(int n) { if (n == m_trackNumber) return; m_trackNumber = n; rebuild(); emit trackChanged(); }
    double position() const { return m_position; }
    void setPosition(double ms) { m_position = ms; m_since.restart(); if (!m_playing) render(); }
    bool playing() const { return m_playing; }
    void setPlaying(bool on) { if (on == m_playing) return; m_playing = on; m_since.restart(); updateTick(); }
    int delay() const { return m_delay; }
    void setDelay(int ms) { if (ms == m_delay) return; m_delay = ms; render(); emit delayChanged(); }

    // A new stream: forget its tracks and fonts.
    Q_INVOKABLE void reset() {
        m_tracks.clear(); m_trackNumber = -1;
        if (m_track) { ass_free_track(m_track); m_track = nullptr; }
        ass_clear_fonts(m_lib); m_fontsChanged = true;
        clearImage(); updateTick();
    }

signals:
    void sourceChanged();
    void trackChanged();
    void delayChanged();

private:
    struct Block { qint64 start, duration; QByteArray data; };
    struct Track { QByteArray header; bool srt = false; QVector<Block> blocks; QSet<QByteArray> seen; int readOrder = 0; };

    void addHeader(int number, const QString &codec, const QByteArray &header) {
        Track &t = m_tracks[number];
        t.srt = codec.startsWith("S_TEXT/UTF8");
        t.header = t.srt ? srtHeader() : header;
        if (number == m_trackNumber) rebuild();
    }
    void addBlock(int number, qint64 start, qint64 duration, const QByteArray &payload) {
        auto it = m_tracks.find(number);
        if (it == m_tracks.end() || it->header.isEmpty()) return;                // image tracks have no header
        // the same block comes again after a seek: keep one
        const QByteArray key = QByteArray::number(start) + ':' + payload.left(48);
        if (it->seen.contains(key)) return;
        it->seen.insert(key);
        QByteArray data = it->srt ? srtChunk(it->readOrder++, payload) : payload;
        if (data.isEmpty()) return;
        it->blocks.append({ start, qMax<qint64>(duration, it->srt ? 60 : 0), data });
        if (number == m_trackNumber && m_track) { Block &b = it->blocks.last(); ass_process_chunk(m_track, b.data.data(), b.data.size(), b.start, b.duration); render(); }
    }
    void addFont(const QString &name, const QByteArray &data) {
        ass_add_font(m_lib, name.toUtf8().constData(), data.constData(), data.size()); m_fonts++;
        m_fontsChanged = true;
    }
    void rebuild() {
        if (m_track) { ass_free_track(m_track); m_track = nullptr; }
        auto it = m_tracks.find(m_trackNumber);
        if (it != m_tracks.end() && !it->header.isEmpty()) {
            m_track = ass_new_track(m_lib);
            ass_process_codec_private(m_track, it->header.data(), it->header.size());
            for (const Block &b : it->blocks) ass_process_chunk(m_track, const_cast<char *>(b.data.data()), b.data.size(), b.start, b.duration);
        }
        clearImage(); updateTick(); render();
    }
    void updateTick() { if (m_playing && m_track) m_tick.start(); else m_tick.stop(); }
    void render() {
        if (!m_track) return;
        if (m_fontsChanged) { ass_set_fonts(m_renderer, "/usr/share/fonts/DroidSans.ttf", "sans-serif", ASS_FONTPROVIDER_NONE, nullptr, 0); m_fontsChanged = false; }
        const qint64 now = qint64(m_position) + (m_playing ? m_since.elapsed() : 0) - m_delay;
        int changed = 0;
        ASS_Image *img = ass_render_frame(m_renderer, m_track, now, &changed);
        if (!changed) return;
        QRect box;
        for (ASS_Image *p = img; p; p = p->next) box |= QRect(p->dst_x, p->dst_y, p->w, p->h);
        QImage out;
        if (!box.isEmpty()) {
            out = QImage(box.size(), QImage::Format_ARGB32_Premultiplied);
            out.fill(0);
            for (ASS_Image *p = img; p; p = p->next) blend(out, box.topLeft(), p);
        }
        m_image = out; m_box = box; m_dirty = true; m_frames++;
        update();
    }
    void clearImage() { m_image = QImage(); m_box = QRect(); m_dirty = true; update(); }

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
        t.replace(QRegularExpression("<\\s*i\\s*>", QRegularExpression::CaseInsensitiveOption), "{\\i1}").replace(QRegularExpression("<\\s*/\\s*i\\s*>", QRegularExpression::CaseInsensitiveOption), "{\\i0}")
         .replace(QRegularExpression("<\\s*b\\s*>", QRegularExpression::CaseInsensitiveOption), "{\\b1}").replace(QRegularExpression("<\\s*/\\s*b\\s*>", QRegularExpression::CaseInsensitiveOption), "{\\b0}")
         .replace(QRegularExpression("<\\s*u\\s*>", QRegularExpression::CaseInsensitiveOption), "{\\u1}").replace(QRegularExpression("<\\s*/\\s*u\\s*>", QRegularExpression::CaseInsensitiveOption), "{\\u0}")
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
protected:
    QSGNode *updatePaintNode(QSGNode *old, UpdatePaintNodeData *) override {
        auto node = static_cast<QSGSimpleTextureNode *>(old);
        if (!m_dirty) return node;
        m_dirty = false;
        if (m_image.isNull()) { delete node; return nullptr; }
        if (!node) { node = new QSGSimpleTextureNode; node->setOwnsTexture(true); }
        node->setTexture(window()->createTextureFromImage(m_image));
        node->setRect(QRectF(m_box.x() * width() / 1920, m_box.y() * height() / 1080, m_box.width() * width() / 1920, m_box.height() * height() / 1080));
        return node;
    }
private:
    QPointer<QObject> m_source;
    ASS_Library *m_lib = nullptr;
    ASS_Renderer *m_renderer = nullptr;
    ASS_Track *m_track = nullptr;
    QHash<int, Track> m_tracks;
    int m_trackNumber = -1, m_delay = 0, m_frames = 0, m_fonts = 0;
    double m_position = 0;
    bool m_playing = false, m_fontsChanged = true, m_dirty = false;
    QElapsedTimer m_since;
    QTimer m_tick;
    QImage m_image;
    QRect m_box;
};
