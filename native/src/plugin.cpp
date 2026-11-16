// The Seimio.Native QML plugin: LG platform access (Luna calls, the media server, window properties),
// libass subtitles, and lab measurement types.
#include <QQmlExtensionPlugin>
#include <QQmlEngine>
#include <QDir>
#include "luna_client.h"
#include "player.h"
#include "subtitle_layer.h"
#include "probes.h"
#include "window_tools.h"

// qml-runner gets Qt's single-threaded "basic" render loop on webOS: key handling, JS, animation and
// rendering share one thread, and animations tick on a timer instead of vsync. The plugin loads before
// the first window exists, so it can ask for the threaded loop here.
static const int g_renderLoop = [] {
    if (qEnvironmentVariableIsEmpty("QSG_RENDER_LOOP")) qputenv("QSG_RENDER_LOOP", "threaded");
    return 0;
}();

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
        qmlRegisterType<KeyLatency>(uri, 1, 0, "KeyLatency");
        qmlRegisterType<FrameStats>(uri, 1, 0, "FrameStats");
        qmlRegisterType<LogTap>(uri, 1, 0, "LogTap");
        qmlRegisterType<WindowTools>(uri, 1, 0, "WindowTools");
    }
    void initializeEngine(QQmlEngine *engine, const char *) override {
        engine->addImportPath(QDir::cleanPath(baseUrl().toLocalFile() + "/.."));
    }
};

#include "plugin.moc"
