// Lab.Native QML plugin. LunaClient: calls webOS Luna services from QML through luna-service2
// directly, since LG's QML Service type can't register on the bus from a dev-mode app.
#include <QQmlExtensionPlugin>
#include <QtQml>
#include <QWindow>
#include <QRegion>
#include <QTimer>
#include <atomic>
#include <QMutex>
#include <QLoggingCategory>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSGSimpleTextureNode>
#include <QElapsedTimer>
#include <QImage>
#include <QKeyEvent>
#include <QGuiApplication>
#include <qpa/qplatformnativeinterface.h>
#include <time.h>
#include <ass/ass.h>
#include "luna.h"
#include "umedia.h"

class LunaClient : public QObject {
    Q_OBJECT
public:
    // Registers on the bus under `name` (empty = anonymous). Returns "" or the error.
    Q_INVOKABLE QString init(const QString &name) {
        LSError e; LSErrorInit(&e);
        QByteArray n = name.toUtf8();
        if (!LSRegister(name.isEmpty() ? nullptr : n.constData(), &m_handle, &e)) return err(e);
        if (!LSGmainContextAttach(m_handle, g_main_context_default(), &e)) return err(e);
        return QString();
    }
    Q_INVOKABLE QString name() const { return m_handle ? QString::fromUtf8(LSHandleGetName(m_handle)) : QString(); }
    // Returns the call token, or -1 with lastError set.
    Q_INVOKABLE double call(const QString &uri, const QString &payload) {
        if (!m_handle) { m_lastError = "not registered"; return -1; }
        LSError e; LSErrorInit(&e);
        LSMessageToken token = 0;
        if (!LSCall(m_handle, uri.toUtf8().constData(), payload.toUtf8().constData(), &LunaClient::reply, this, &token, &e)) { m_lastError = err(e); return -1; }
        return double(token);
    }
    Q_INVOKABLE void cancel(double token) {
        if (!m_handle) return;
        LSError e; LSErrorInit(&e);
        if (!LSCallCancel(m_handle, LSMessageToken(token), &e)) LSErrorFree(&e);
    }
    Q_INVOKABLE QString lastError() const { return m_lastError; }
signals:
    void response(double token, const QString &payload);
private:
    static bool reply(LSHandle *, LSMessage *msg, void *ctx) {
        auto self = static_cast<LunaClient *>(ctx);
        emit self->response(double(LSMessageGetResponseToken(msg)), QString::fromUtf8(LSMessageGetPayload(msg)));
        return true;
    }
    static QString err(LSError &e) { QString s = QString::fromUtf8(e.message ? e.message : "unknown"); LSErrorFree(&e); return s; }
    LSHandle *m_handle = nullptr;
    QString m_lastError;
};

// Player events arrive on uMediaClient's own message thread; slot counts are atomics read from QML.
class NativePlayer;
class Client : public uMediaServer::uMediaClient {
public:
    Client(NativePlayer *owner) : uMediaClient(true, UMS_BUS_APP), m_owner(owner) {}
    std::atomic<int> counts[49] {};
    int eventSlot = -1; // once known, that slot's first argument is the raw JSON event
#define UMS_DEF(n) bool slot##n(void *a, void *, void *) override { counts[n]++; if (eventSlot == n) deliver(static_cast<const char *>(a)); return true; }
    UMS_SLOTS(UMS_DEF)
#undef UMS_DEF
private:
    void deliver(const char *json);
    NativePlayer *m_owner;
};

class NativePlayer : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString windowId READ windowId NOTIFY windowIdChanged)
public:
    // Unload before the client goes, so a pipeline never outlives the app (a leaked one jammed the TV's audio).
    ~NativePlayer() override { if (m_client) { m_client->unload(); delete m_client; } }
    QString windowId() const { return m_windowId; }
    // Asks LG's window manager for a video window under `window` and polls until it assigns an id.
    Q_INVOKABLE QString exportWindow(QObject *window) {
        auto w = qobject_cast<QWindow *>(window);
        if (!w) return "not a window";
        auto platform = WebOSPlatform::instance();
        if (!platform) return "no WebOSPlatform";
        auto foreign = platform->webOSForeign();
        if (!foreign) return "no WebOSForeign";
        m_exported = foreign->export_element(w, WebOSForeign::VideoObject);
        if (!m_exported) return "export_element returned null";
        QRegion full(0, 0, w->width(), w->height());
        m_exported->setExportedWindow(full, full);
        auto poll = new QTimer(this);
        connect(poll, &QTimer::timeout, this, [this, poll] {
            QString id = m_exported->getWindowId();
            if (id.isEmpty()) return;
            poll->deleteLater();
            m_windowId = id;
            emit windowIdChanged();
        });
        poll->start(50);
        return QString();
    }
    Q_INVOKABLE void setEventSlot(int n) { ensure(); m_client->eventSlot = n; }
    Q_INVOKABLE bool load(const QString &uri, const QString &payload) {
        ensure();
        return m_client->loadAsync(uri.toStdString(), "media", payload.toStdString());
    }
    Q_INVOKABLE bool play() { return m_client && m_client->play(); }
    Q_INVOKABLE bool pause() { return m_client && m_client->pause(); }
    Q_INVOKABLE bool seek(double ms) { return m_client && m_client->seek((long long)ms); }
    Q_INVOKABLE bool selectTrack(const QString &type, int index) {
        if (!m_client) return false;
        std::string t = type.toStdString();
        return m_client->selectTrack(t, index);
    }
    Q_INVOKABLE bool unload() { return m_client && m_client->unload(); }
    // "slot:count" for every slot that has fired, to find which one carries raw events.
    Q_INVOKABLE QString slotCounts() const {
        QStringList out;
        if (m_client) for (int i = 0; i < 49; i++) if (m_client->counts[i]) out << QString("%1:%2").arg(i).arg(m_client->counts[i].load());
        return out.join(" ");
    }
signals:
    void windowIdChanged();
    void event(const QString &json);
private:
    friend class Client;
    void ensure() { if (!m_client) m_client = new Client(this); }
    Client *m_client = nullptr;
    WebOSExported *m_exported = nullptr;
    QString m_windowId;
};

void Client::deliver(const char *json) {
    QString s = QString::fromUtf8(json);
    QMetaObject::invokeMethod(m_owner, [o = m_owner, s] { emit o->event(s); }, Qt::QueuedConnection);
}

// AssItem: draws an ASS subtitle file with libass. Setting `time` renders that moment on the GUI
// thread, blends the bitmaps into one image the size of their bounding box, and the scene graph
// uploads it as a texture. ponytail: CPU blend + full re-upload per change; per-bitmap alpha
// textures tinted on the GPU if the blend cost shows up on the TV.
class AssItem : public QQuickItem {
    Q_OBJECT
    Q_PROPERTY(QString file MEMBER m_file WRITE setFile)
    Q_PROPERTY(QString fontsDir MEMBER m_fontsDir)
    Q_PROPERTY(double time READ time WRITE setTime)
public:
    AssItem() { setFlag(ItemHasContents); }
    ~AssItem() override {
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

// KeyLatency: for each key press, the time from the key reaching the app (and from the compositor's
// event timestamp) to the first frame swapped after a scene sync that includes the key's changes.
class KeyLatency : public QObject {
    Q_OBJECT
public:
    Q_INVOKABLE void attach(QObject *window) {
        auto w = qobject_cast<QQuickWindow *>(window);
        if (!w) return;
        w->installEventFilter(this);
        connect(w, &QQuickWindow::beforeSynchronizing, this, [this] {   // render thread, GUI blocked
            QMutexLocker l(&m_mutex);
            for (auto &p : m_pending) p.synced = true;
        }, Qt::DirectConnection);
        connect(w, &QQuickWindow::frameSwapped, this, [this] {           // render thread
            double now = monoMs();
            QMutexLocker l(&m_mutex);
            for (int i = m_pending.size() - 1; i >= 0; i--) {
                if (!m_pending[i].synced) continue;
                m_fromArrival << now - m_pending[i].arrival;
                m_fromEvent << now - m_pending[i].eventTime;
                m_pending.removeAt(i);
            }
        }, Qt::DirectConnection);
    }
    bool eventFilter(QObject *, QEvent *e) override {
        if (e->type() == QEvent::KeyPress) {
            QMutexLocker l(&m_mutex);
            m_pending.append({ double(static_cast<QKeyEvent *>(e)->timestamp()), monoMs(), false });
        }
        return false;
    }
    Q_INVOKABLE QString stats() {
        QMutexLocker l(&m_mutex);
        auto line = [](QVector<double> v) {
            if (v.isEmpty()) return QString("none");
            std::sort(v.begin(), v.end());
            return QString("n %1 median %2 p90 %3 max %4").arg(v.size()).arg(v[v.size() / 2], 0, 'f', 1)
                .arg(v[v.size() * 9 / 10], 0, 'f', 1).arg(v.last(), 0, 'f', 1);
        };
        QString s = "from app arrival: " + line(m_fromArrival) + " | from input event: " + line(m_fromEvent);
        m_fromArrival.clear(); m_fromEvent.clear();
        return s;
    }
private:
    static double monoMs() { timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }
    struct Pending { double eventTime, arrival; bool synced; };
    QVector<Pending> m_pending;
    QVector<double> m_fromArrival, m_fromEvent;
    QMutex m_mutex;
};

// FrameStats: time between swapped frames, stamped on the render thread (a QML handler would stamp
// them on the GUI thread, where its own work shows up as fake late frames), grouped by `phase`.
class FrameStats : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString phase READ phase WRITE setPhase)
public:
    QString phase() const { QMutexLocker l(&m_mutex); return m_phase; }
    void setPhase(const QString &p) { QMutexLocker l(&m_mutex); m_phase = p; }
    Q_INVOKABLE void attach(QObject *window) {
        auto w = qobject_cast<QQuickWindow *>(window);
        if (!w) return;
        connect(w, &QQuickWindow::frameSwapped, this, [this] {
            timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
            double now = t.tv_sec * 1e3 + t.tv_nsec / 1e6;
            QMutexLocker l(&m_mutex);
            if (m_last > 0) m_gaps[m_phase].append(now - m_last);
            m_last = now;
        }, Qt::DirectConnection);
    }
    // { phase: { frames, median, max, late20, late30, short12 } } since the last call
    Q_INVOKABLE QVariantMap take() {
        QMutexLocker l(&m_mutex);
        QVariantMap out;
        for (auto it = m_gaps.begin(); it != m_gaps.end(); ++it) {
            QVector<double> g = it.value(); std::sort(g.begin(), g.end());
            int l20 = 0, l30 = 0, s12 = 0;
            for (double x : g) { l20 += x > 20; l30 += x > 30; s12 += x < 12; }
            out[it.key()] = QVariantMap{ {"frames", g.size()}, {"median", g[g.size() / 2]}, {"max", g.last()},
                                         {"late20", l20}, {"late30", l30}, {"short12", s12} };
        }
        m_gaps.clear();
        return out;
    }
private:
    mutable QMutex m_mutex;
    QString m_phase = "idle";
    double m_last = 0;
    QMap<QString, QVector<double>> m_gaps;
};

// WindowTools: sets webOS window properties that LG's QML window type doesn't expose, such as
// _WEBOS_ACCESS_POLICY_KEYS_BACK, which decides whether Back reaches the app or opens the exit menu.
class WindowTools : public QObject {
    Q_OBJECT
public:
    Q_INVOKABLE QString setWindowProperty(QObject *window, const QString &name, const QString &value) {
        auto w = qobject_cast<QWindow *>(window);
        if (!w || !w->handle()) return "window not created yet";
        auto native = QGuiApplication::platformNativeInterface();
        if (!native) return "no native interface";
        native->setWindowProperty(w->handle(), name, value);
        return QString();
    }
    Q_INVOKABLE QVariantMap windowProperties(QObject *window) {
        auto w = qobject_cast<QWindow *>(window);
        auto native = QGuiApplication::platformNativeInterface();
        return (w && w->handle() && native) ? native->windowProperties(w->handle()) : QVariantMap();
    }
};

// Captures Qt log output in-process (qml-runner sends it to PmLog, which dev mode can't read).
static QStringList g_logLines;
static QMutex g_logMutex;
class LogTap : public QObject {
    Q_OBJECT
public:
    Q_INVOKABLE void start(const QString &rules) {
        QLoggingCategory::setFilterRules(rules);
        qInstallMessageHandler([](QtMsgType, const QMessageLogContext &ctx, const QString &msg) {
            QMutexLocker l(&g_logMutex);
            g_logLines << QString("%1 %2").arg(ctx.category ? ctx.category : "").arg(msg);
        });
    }
    Q_INVOKABLE QStringList take() { QMutexLocker l(&g_logMutex); QStringList out = g_logLines; g_logLines.clear(); return out; }
};

// qml-runner gets Qt's single-threaded "basic" render loop on webOS: key handling, JS, animation and
// rendering share one thread, and animations tick on a timer instead of vsync. The plugin loads before
// the first window exists, so it can ask for the threaded loop here.
static const int g_renderLoop = [] {
    if (qEnvironmentVariableIsEmpty("QSG_RENDER_LOOP")) qputenv("QSG_RENDER_LOOP", "threaded");
    return 0;
}();

class LabNativePlugin : public QQmlExtensionPlugin {
    Q_OBJECT
    Q_PLUGIN_METADATA(IID QQmlExtensionInterface_iid)
public:
    // Registered under a fixed URI: the app loads the plugin through a folder import, then imports Lab.Native.
    void registerTypes(const char *) override {
        qmlRegisterType<LunaClient>("Lab.Native", 1, 0, "LunaClient");
        qmlRegisterType<NativePlayer>("Lab.Native", 1, 0, "NativePlayer");
        qmlRegisterType<LogTap>("Lab.Native", 1, 0, "LogTap");
        qmlRegisterType<AssItem>("Lab.Native", 1, 0, "AssItem");
        qmlRegisterType<KeyLatency>("Lab.Native", 1, 0, "KeyLatency");
        qmlRegisterType<FrameStats>("Lab.Native", 1, 0, "FrameStats");
        qmlRegisterType<WindowTools>("Lab.Native", 1, 0, "WindowTools");
    }
};

#include "plugin.moc"
