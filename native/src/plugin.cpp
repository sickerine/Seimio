// The Seimio.Native QML plugin: LG platform access (Luna calls, the media server, window properties),
// libass subtitles, and lab measurement types.
#include <QQmlExtensionPlugin>
#include <QQmlEngine>
#include <QDir>
#include <QNetworkAccessManager>
#include <QNetworkDiskCache>
#include <QQmlNetworkAccessManagerFactory>
#include <QStandardPaths>
#include <QThread>
#include <QCoreApplication>
#include "luna_client.h"
#include "player.h"
#include "subtitle_layer.h"
#include "tee.h"
#include "probes.h"
#include "banded_image.h"
#include "window_tools.h"
#include "kept_pictures.h"

// qml-runner gets Qt's single-threaded "basic" render loop on webOS: key handling, JS, animation and
// rendering share one thread, and animations tick on a timer instead of vsync. The plugin loads before
// the first window exists, so it can ask for the threaded loop here.
// It also turns off the texture atlas. Adding an image to the shared atlas while the GPU still reads
// it from the last frame stalls the TV's driver for 10-15 ms (measured on the C5), and every card
// and backdrop image is sampled by a shader, which copies it back out of the atlas anyway.
static const int g_env = [] {
    if (qEnvironmentVariableIsEmpty("QSG_RENDER_LOOP")) qputenv("QSG_RENDER_LOOP", "threaded");
    if (qEnvironmentVariableIsEmpty("QSG_ATLAS_SIZE_LIMIT")) qputenv("QSG_ATLAS_SIZE_LIMIT", "1");
    return 0;
}();

// Everything the app shows comes from the network (nothing is baked into it), so images and anything QML
// fetches go through a disk cache that outlives a launch: a cover seen yesterday shows without downloading
// again, as HTTP's cache headers allow. A QNetworkDiskCache can't be shared between threads, and QML makes
// a manager per thread (the GUI's, the image reader's), so each gets its own directory.
// A picture whose server says nothing of how long it keeps is kept thirty days (KeptPictures).
class CachedNetwork : public QQmlNetworkAccessManagerFactory {
public:
    QNetworkAccessManager *create(QObject *parent) override {
        auto *nam = new QNetworkAccessManager(parent);
        auto *cache = new KeptPictures(nam);
        const bool gui = QThread::currentThread() == QCoreApplication::instance()->thread();
        cache->setCacheDirectory(QStandardPaths::writableLocation(QStandardPaths::CacheLocation) + "/net/" + (gui ? "gui" : "images"));
        // (the GUI thread's holds no pictures any more: the backdrop's went through it until the picture
        // loader took them, pictures.h, and what they left there, up to 400 MB, is let go)
        cache->setMaximumCacheSize(qint64(gui ? 8 : 400) << 20);
        if (gui) cache->trim();
        nam->setCache(cache);
        return nam;
    }
};

class SeimioNativePlugin : public QQmlExtensionPlugin {
    Q_OBJECT
    Q_PLUGIN_METADATA(IID QQmlExtensionInterface_iid)
public:
    // main.qml loads this plugin through a folder import ("native"), so types are registered under a
    // fixed URI, and the app folder (this folder's parent) is added to the import path so App and the
    // screens can `import Seimio.UI 1.0` and `import Seimio.Native 1.0`.
    void registerTypes(const char *) override {
        const char *uri = "Seimio.Native";
        qmlRegisterType<LunaClient>(uri, 1, 0, "LunaClient");
        qmlRegisterType<NativePlayer>(uri, 1, 0, "NativePlayer");
        qmlRegisterType<SubtitleLayer>(uri, 1, 0, "SubtitleLayer");
        qmlRegisterType<Tee>(uri, 1, 0, "Tee");
        qmlRegisterType<KeyLatency>(uri, 1, 0, "KeyLatency");
        qmlRegisterType<FrameStats>(uri, 1, 0, "FrameStats");
        qmlRegisterType<LogTap>(uri, 1, 0, "LogTap");
        qmlRegisterType<BandedImage>(uri, 1, 0, "BandedImage");
        qmlRegisterType<WindowTools>(uri, 1, 0, "WindowTools");
    }
    void initializeEngine(QQmlEngine *engine, const char *) override {
        engine->addImportPath(QDir::cleanPath(baseUrl().toLocalFile() + "/.."));
        if (!engine->networkAccessManagerFactory()) engine->setNetworkAccessManagerFactory(new CachedNetwork);
    }
};

#include "plugin.moc"
