// Seimio's entry on Android: registers the Seimio.Data plugin (linked in, not loaded) and the player (mpv.h),
// and opens App.qml. On the LG, qml-runner opens app/main.qml and the plugin loads from the app's "native" folder.
#include <QGuiApplication>
#include <QJniEnvironment>
#include <QPluginLoader>
#include <QQmlApplicationEngine>
#include <QQmlExtensionPlugin>
#include <clocale>
#include "mpv.h"

Q_IMPORT_PLUGIN(SeimioDataPlugin)
// FFmpeg's, for MediaCodec and Android's audio, which mpv reaches through Java
extern "C" int av_jni_set_java_vm(void *vm, void *log);

int main(int argc, char **argv) {
    // The TV draws apps at 1920x1080 and calls it 320 dpi, so Qt would scale by 2: a 960x540 window with the
    // app's 1920x1080 canvas shrunk into it. Unscaled, the canvas is the window, and mpv's picture is drawn
    // at the screen's size.
    qputenv("QT_ENABLE_HIGHDPI_SCALING", "0");
    QGuiApplication app(argc, argv);
    std::setlocale(LC_NUMERIC, "C");          // (mpv reads numbers in the C locale)
    av_jni_set_java_vm(QJniEnvironment::javaVM(), nullptr);
    qmlRegisterSingletonInstance("Seimio.Android", 1, 0, "Mpv", Mpv::instance());
    qmlRegisterType<MpvVideo>("Seimio.Android", 1, 0, "MpvVideo");
    qmlRegisterType<AddonList>("Seimio.Android", 1, 0, "AddonList");
    QQmlApplicationEngine engine;
    for (QObject *o : QPluginLoader::staticInstances())
        if (auto *plugin = qobject_cast<QQmlExtensionPlugin *>(o)) {
            plugin->registerTypes("Seimio.Data");
            plugin->initializeEngine(&engine, "Seimio.Data");
        }
    engine.addImportPath("qrc:/app");
    engine.addImportPath("qrc:/imports");
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app, [] { QCoreApplication::exit(1); });
    engine.load(QUrl("qrc:/app/qml/App.qml"));
    return app.exec();
}
