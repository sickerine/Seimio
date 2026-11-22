#pragma once
// The player on Android: mpv (libmpv), which reads the stream, decodes it (MediaCodec where the TV has the
// codec, software otherwise: DTS, TrueHD and 10-bit H.264 play here) and draws the subtitles itself.
// `Mpv` is the one player of the app, for QML a singleton (Seimio.Android); `MpvVideo` is its picture,
// drawn into the scene with mpv's OpenGL render API, under whatever the player screen shows over it.
// The LG's player types (NativePlayer, Tee, SubtitleLayer) are QML over these on Android
// (android/imports/Seimio/Native), so PlayerScreen is the same file on both.
#include <QtQml>
#include <QQuickFramebufferObject>
#include <QQuickWindow>
#include <QQuickOpenGLUtils>
#include <QOpenGLFramebufferObject>
#include <QOpenGLContext>
#include <QStandardPaths>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <mpv/client.h>
#include <mpv/render_gl.h>

class Mpv : public QObject {
    Q_OBJECT
public:
    static Mpv *instance() { static Mpv *one = new Mpv; return one; }
    mpv_handle *handle() const { return m_mpv; }

    // a command as mpv's input takes it (["loadfile", url, "replace", "-1", "start=10"]), sent without waiting
    Q_INVOKABLE void command(const QStringList &args) {
        QList<QByteArray> bytes; for (const QString &a : args) bytes << a.toUtf8();
        QVector<const char *> argv; for (const QByteArray &b : bytes) argv << b.constData();
        argv << nullptr;
        mpv_command_async(m_mpv, 0, argv.data());
    }
    Q_INVOKABLE void set(const QString &name, const QVariant &value) {
        const QByteArray v = value.typeId() == QMetaType::Bool ? QByteArray(value.toBool() ? "yes" : "no") : value.toString().toUtf8();
        const char *s = v.constData();
        mpv_set_property_async(m_mpv, 0, name.toUtf8().constData(), MPV_FORMAT_STRING, &s);      // (mpv copies it)
    }
    Q_INVOKABLE QVariant get(const QString &name) const {
        mpv_node n;
        if (mpv_get_property(m_mpv, name.toUtf8().constData(), MPV_FORMAT_NODE, &n) < 0) return QVariant();
        const QVariant v = toVariant(n);
        mpv_free_node_contents(&n);
        return v;
    }

signals:
    void changed(const QString &name, const QVariant &value);     // an observed property (below)
    void fileLoaded();
    void restarted();                       // frames again: the file's first, or the first after a seek
    void ended(const QString &reason, const QString &error);       // "eof", "stop", "error" (with mpv's words)

private:
    Mpv() {
        m_mpv = mpv_create();
        auto opt = [this](const char *k, const char *v) { mpv_set_option_string(m_mpv, k, v); };
        opt("vo", "libmpv");
        opt("hwdec", "mediacodec-copy");    // the TV's decoder, its frames copied back for the render API
        opt("profile", "fast");             // (the TV's GPU: mpv's default scaling and dithering dropped frames)
        opt("idle", "yes"); opt("keep-open", "yes");          // played out, it holds its last frame and says eof-reached
        opt("input-default-bindings", "no"); opt("input-vo-keyboard", "no"); opt("osc", "no");
        opt("cache", "yes"); opt("demuxer-max-bytes", "48MiB"); opt("demuxer-max-back-bytes", "16MiB");   // the TV has 2.4 GB for everything
        opt("network-timeout", "20");
        opt("ytdl", "no");                 // (links are files: nothing for youtube-dl to resolve)
        // curl verifies the streams' hosts against the TV's own trust store (it has none of its own here)
        opt("tls-verify", "yes"); opt("tls-ca-file", trustStore().toUtf8().constData());
        mpv_request_log_messages(m_mpv, "warn");
        for (const char *p : { "time-pos", "duration", "pause", "paused-for-cache", "seeking", "eof-reached", "track-list", "chapter-list", "aid", "sid" })
            mpv_observe_property(m_mpv, 0, p, MPV_FORMAT_NODE);
        mpv_set_wakeup_callback(m_mpv, [](void *self) { QMetaObject::invokeMethod(static_cast<Mpv *>(self), &Mpv::drain, Qt::QueuedConnection); }, this);
        if (mpv_initialize(m_mpv) < 0) qWarning("mpv: could not start");
    }
    // Android's certificates (the conscrypt module's since Android 14, else the system's), one PEM file each,
    // as one file for curl, made at each start so it follows the TV's updates
    static QString trustStore() {
        const QString out = QStandardPaths::writableLocation(QStandardPaths::CacheLocation) + "/cacerts.pem";
        QDir().mkpath(QFileInfo(out).path());
        QDir dir("/apex/com.android.conscrypt/cacerts");
        if (!dir.exists()) dir.setPath("/system/etc/security/cacerts");
        QFile f(out);
        if (f.open(QIODevice::WriteOnly))
            for (const QString &name : dir.entryList(QDir::Files)) { QFile c(dir.filePath(name)); if (c.open(QIODevice::ReadOnly)) f.write(c.readAll() + "\n"); }
        return out;
    }
    void drain() {
        while (m_mpv) {
            mpv_event *e = mpv_wait_event(m_mpv, 0);
            if (e->event_id == MPV_EVENT_NONE) return;
            switch (e->event_id) {
            case MPV_EVENT_PROPERTY_CHANGE: {
                auto *p = static_cast<mpv_event_property *>(e->data);
                emit changed(QString::fromUtf8(p->name), p->format == MPV_FORMAT_NODE ? toVariant(*static_cast<mpv_node *>(p->data)) : QVariant());
                break;
            }
            case MPV_EVENT_FILE_LOADED: emit fileLoaded(); break;
            case MPV_EVENT_PLAYBACK_RESTART: emit restarted(); break;
            case MPV_EVENT_END_FILE: {
                auto *f = static_cast<mpv_event_end_file *>(e->data);
                emit ended(f->reason == MPV_END_FILE_REASON_EOF ? "eof" : f->reason == MPV_END_FILE_REASON_ERROR ? "error" : "stop",
                           f->reason == MPV_END_FILE_REASON_ERROR ? QString::fromUtf8(mpv_error_string(f->error)) : QString());
                break;
            }
            case MPV_EVENT_LOG_MESSAGE: {
                auto *m = static_cast<mpv_event_log_message *>(e->data);
                qWarning("mpv %s: %s", m->prefix, QByteArray(m->text).trimmed().constData());
                break;
            }
            default: break;
            }
        }
    }
    static QVariant toVariant(const mpv_node &n) {
        switch (n.format) {
        case MPV_FORMAT_STRING: return QString::fromUtf8(n.u.string);
        case MPV_FORMAT_FLAG: return bool(n.u.flag);
        case MPV_FORMAT_INT64: return qlonglong(n.u.int64);
        case MPV_FORMAT_DOUBLE: return n.u.double_;
        case MPV_FORMAT_NODE_ARRAY: { QVariantList l; for (int i = 0; i < n.u.list->num; i++) l << toVariant(n.u.list->values[i]); return l; }
        case MPV_FORMAT_NODE_MAP: { QVariantMap m; for (int i = 0; i < n.u.list->num; i++) m.insert(QString::fromUtf8(n.u.list->keys[i]), toVariant(n.u.list->values[i])); return m; }
        default: return QVariant();
        }
    }
    mpv_handle *m_mpv = nullptr;
};

// mpv's picture, drawn at the item's size (the screen's: the window is unscaled, main.cpp).
class MpvVideo : public QQuickFramebufferObject {
    Q_OBJECT
    class Renderer : public QQuickFramebufferObject::Renderer {
    public:
        explicit Renderer(MpvVideo *item) : m_item(item) {
            mpv_opengl_init_params gl { [](void *, const char *name) -> void * {
                QOpenGLContext *c = QOpenGLContext::currentContext();
                return c ? reinterpret_cast<void *>(c->getProcAddress(name)) : nullptr;
            }, nullptr };
            mpv_render_param params[] { { MPV_RENDER_PARAM_API_TYPE, const_cast<char *>(MPV_RENDER_API_TYPE_OPENGL) },
                                        { MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl }, { MPV_RENDER_PARAM_INVALID, nullptr } };
            if (mpv_render_context_create(&m_ctx, Mpv::instance()->handle(), params) < 0) { qWarning("mpv: no render context"); return; }
            mpv_render_context_set_update_callback(m_ctx, [](void *item) { QMetaObject::invokeMethod(static_cast<MpvVideo *>(item), &QQuickItem::update, Qt::QueuedConnection); }, item);
        }
        ~Renderer() override { if (m_ctx) mpv_render_context_free(m_ctx); }
        QOpenGLFramebufferObject *createFramebufferObject(const QSize &size) override { return new QOpenGLFramebufferObject(size); }
        void render() override {
            if (!m_ctx) return;
            QOpenGLFramebufferObject *fbo = framebufferObject();
            mpv_opengl_fbo target { int(fbo->handle()), fbo->width(), fbo->height(), 0 };
            int flip = 0;
            mpv_render_param params[] { { MPV_RENDER_PARAM_OPENGL_FBO, &target }, { MPV_RENDER_PARAM_FLIP_Y, &flip }, { MPV_RENDER_PARAM_INVALID, nullptr } };
            mpv_render_context_render(m_ctx, params);
            QQuickOpenGLUtils::resetOpenGLState();
        }
    private:
        MpvVideo *m_item;
        mpv_render_context *m_ctx = nullptr;
    };
public:
    Renderer *createRenderer() const override { return new Renderer(const_cast<MpvVideo *>(this)); }
};

// The OpenSubtitles addon's subtitles for the video playing (addon_subtitles.h), for Android's SubtitleLayer:
// mpv loads the one chosen (`url`) itself.
#include "addon_subtitles.h"
class AddonList : public QObject {
    Q_OBJECT
public:
    AddonList() : m_queries(new query::Queries(this)), m_http(new Net(m_queries, this)),
                  m_addon(m_queries, m_http, [this](const QVariantList &subtitles) { emit listed(subtitles); }) {}
    Q_INVOKABLE void fetch(const QString &type, const QString &videoId) { m_addon.fetch(type, videoId); }
    Q_INVOKABLE void stop() { m_addon.stop(); }
    Q_INVOKABLE QString url(int number) const { return m_addon.url(number); }
signals:
    void listed(const QVariantList &subtitles);
private:
    query::Queries *m_queries;
    Net *m_http;
    AddonSubtitles m_addon;
};
