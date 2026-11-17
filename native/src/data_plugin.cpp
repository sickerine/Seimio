// The Seimio.Data plugin: Catalog and CalendarModel (catalog.h), Streams (streams.h), Tracks (tracks.h), SkipTimes (skip.h). Plain Qt, so the same source builds for
// the TV (native/build.sh) and for the Mac previews (tools/preview/build-data.sh).
#include <QtQml>
#include <QNetworkDiskCache>
#include <QQmlNetworkAccessManagerFactory>
#include "catalog.h"
#include "streams.h"
#include "tracks.h"
#include "skip.h"

// The Mac's visual check (SEIMIO_REPLAY set, see Live) loads images from a disk cache that, once it holds an
// image, never asks the network again: renders fetched art at whatever moment it arrived, and a frost
// captured a card before or after its art. The TV never sets it.
class FixedImages : public QQmlNetworkAccessManagerFactory {
    class Manager : public QNetworkAccessManager {
    public:
        using QNetworkAccessManager::QNetworkAccessManager;
    protected:
        QNetworkReply *createRequest(Operation op, const QNetworkRequest &request, QIODevice *data) override {
            QNetworkRequest r(request);
            r.setAttribute(QNetworkRequest::CacheLoadControlAttribute, QNetworkRequest::PreferCache);
            return QNetworkAccessManager::createRequest(op, r, data);
        }
    };
public:
    QNetworkAccessManager *create(QObject *parent) override {
        auto *nam = new Manager(parent);
        auto *cache = new QNetworkDiskCache(nam);
        cache->setCacheDirectory(qEnvironmentVariable("SEIMIO_REPLAY") + "/../../../.lab/preview-images");
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
        qmlRegisterType<Streams>("Seimio.Data", 1, 0, "Streams");
        qmlRegisterType<Tracks>("Seimio.Data", 1, 0, "Tracks");
        qmlRegisterType<SkipTimes>("Seimio.Data", 1, 0, "SkipTimes");
        qmlRegisterUncreatableType<CalendarModel>("Seimio.Data", 1, 0, "CalendarModel", "comes from Catalog.calendar");
    }
    void initializeEngine(QQmlEngine *engine, const char *) override {
        if (!qEnvironmentVariableIsEmpty("SEIMIO_REPLAY") && !engine->networkAccessManagerFactory()) engine->setNetworkAccessManagerFactory(new FixedImages);
    }
};

#include "data_plugin.moc"
