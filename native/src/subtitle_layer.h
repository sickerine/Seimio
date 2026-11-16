#pragma once
#include <QtQml>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSGSimpleTextureNode>
#include <QElapsedTimer>
#include <QImage>
#include <ass/ass.h>

// SubtitleLayer: draws an ASS subtitle file with libass. Setting `time` renders that moment on the GUI
// thread, blends the bitmaps into one image the size of their bounding box, and the scene graph
// uploads it as a texture. ponytail: CPU blend + full re-upload per change; per-bitmap alpha
// textures tinted on the GPU if the blend cost shows up on the TV.
class SubtitleLayer : public QQuickItem {
    Q_OBJECT
    Q_PROPERTY(QString file MEMBER m_file WRITE setFile)
    Q_PROPERTY(QString fontsDir MEMBER m_fontsDir)
    Q_PROPERTY(double time READ time WRITE setTime)
public:
    SubtitleLayer() { setFlag(ItemHasContents); }
    ~SubtitleLayer() override {
        if (m_track) ass_free_track(m_track);
        if (m_renderer) ass_renderer_done(m_renderer);
        if (m_lib) ass_library_done(m_lib);
    }
    double time() const { return m_time; }
    void setFile(const QString &f) {
        m_file = f;
        m_lib = ass_library_init();
        ass_set_fonts_dir(m_lib, m_fontsDir.toUtf8().constData());
        ass_set_extract_fonts(m_lib, 1);
        m_renderer = ass_renderer_init(m_lib);
        ass_set_frame_size(m_renderer, 1920, 1080);
        ass_set_storage_size(m_renderer, 1920, 1080);
        ass_set_fonts(m_renderer, "/usr/share/fonts/DroidSans.ttf", "sans-serif", ASS_FONTPROVIDER_NONE, nullptr, 0);
        m_track = ass_read_file(m_lib, f.toUtf8().data(), nullptr);
    }
    void setTime(double ms) {
        m_time = ms;
        if (!m_track) return;
        QElapsedTimer t; t.start();
        int changed = 0;
        ASS_Image *img = ass_render_frame(m_renderer, m_track, (long long)ms, &changed);
        if (!changed) return;
        QRect box;
        for (ASS_Image *p = img; p; p = p->next) box |= QRect(p->dst_x, p->dst_y, p->w, p->h);
        QImage out;
        if (!box.isEmpty()) {
            out = QImage(box.size(), QImage::Format_ARGB32_Premultiplied);
            out.fill(0);
            for (ASS_Image *p = img; p; p = p->next) blend(out, box.topLeft(), p);
        }
        m_cost << t.nsecsElapsed() / 1e6;
        m_image = out; m_box = box; m_dirty = true;
        update();
    }
    // render+blend ms: count, median, p95, max
    Q_INVOKABLE QString stats() {
        if (m_cost.isEmpty()) return "no frames";
        QVector<double> c = m_cost; std::sort(c.begin(), c.end());
        QString s = QString("frames %1 median %2 p95 %3 max %4").arg(c.size()).arg(c[c.size() / 2], 0, 'f', 2)
            .arg(c[c.size() * 95 / 100], 0, 'f', 2).arg(c.last(), 0, 'f', 2);
        m_cost.clear();
        return s;
    }
protected:
    QSGNode *updatePaintNode(QSGNode *old, UpdatePaintNodeData *) override {
        auto node = static_cast<QSGSimpleTextureNode *>(old);
        if (!m_dirty) return node;
        m_dirty = false;
        if (m_image.isNull()) { delete node; return nullptr; }
        if (!node) { node = new QSGSimpleTextureNode; node->setOwnsTexture(true); }
        node->setTexture(window()->createTextureFromImage(m_image));
        node->setRect(m_box);
        return node;
    }
private:
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
    QString m_file, m_fontsDir;
    double m_time = 0;
    ASS_Library *m_lib = nullptr;
    ASS_Renderer *m_renderer = nullptr;
    ASS_Track *m_track = nullptr;
    QImage m_image;
    QRect m_box;
    bool m_dirty = false;
    QVector<double> m_cost;
};
