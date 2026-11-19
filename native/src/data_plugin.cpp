// The Seimio.Data plugin: Catalog and CalendarModel (catalog.h), Account (account.h, over Stremio's core), Streams (streams.h), Tracks (tracks.h), SkipTimes (skip.h). Plain Qt, so the same source builds for
// the TV (native/build.sh) and for the Mac previews (tools/preview/build-data.sh).
#include <QtQml>
#include <QNetworkDiskCache>
#include <QQmlNetworkAccessManagerFactory>
#include "account.h"
#include "catalog.h"
#include "pictures.h"
#include "streams.h"
#include "tracks.h"
#include "skip.h"

// The Mac's visual check (SEIMIO_REPLAY set) loads pictures from a disk cache that never asks the network
// again (pictures::Fixed). Qt's own image reader gets it here; the picture loader takes it itself.
class FixedImages : public QQmlNetworkAccessManagerFactory {
public:
    QNetworkAccessManager *create(QObject *parent) override {
        const QString dir = pictures::Fixed::directory();
        // images load on QML's own thread; the GUI thread's requests (the lab's) are left as they are
        auto *nam = new pictures::Fixed(dir, QThread::currentThread() != qApp->thread(), parent);
        auto *cache = new QNetworkDiskCache(nam);
        cache->setCacheDirectory(dir);
        cache->setMaximumCacheSize(qint64(500) << 20);
        nam->setCache(cache);
        return nam;
    }
};

class SeimioDataPlugin : public QQmlExtensionPlugin {
    Q_OBJECT
    Q_PLUGIN_METADATA(IID QQmlExtensionInterface_iid)
public:
    // on the TV this loads through the app's "native" folder import, so the URI is fixed here
    void registerTypes(const char *) override {
        qmlRegisterType<Catalog>("Seimio.Data", 1, 0, "Catalog");
        qmlRegisterType<Rest>("Seimio.Data", 1, 0, "Rest");
        qmlRegisterType<Account>("Seimio.Data", 1, 0, "Account");
        qmlRegisterType<Streams>("Seimio.Data", 1, 0, "Streams");
        qmlRegisterType<Tracks>("Seimio.Data", 1, 0, "Tracks");
        qmlRegisterType<SkipTimes>("Seimio.Data", 1, 0, "SkipTimes");
        qmlRegisterUncreatableType<CalendarModel>("Seimio.Data", 1, 0, "CalendarModel", "comes from Catalog.calendar");
    }
    void initializeEngine(QQmlEngine *engine, const char *) override {
        if (!qEnvironmentVariableIsEmpty("SEIMIO_REPLAY") && !engine->networkAccessManagerFactory()) engine->setNetworkAccessManagerFactory(new FixedImages);
        // "image://art/...": the pictures that can be had from more than one place, and the backdrop's (pictures.h)
        engine->addImageProvider("art", new pictures::Provider);
    }
};

#include "data_plugin.moc"
