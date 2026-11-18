// The Seimio.Data plugin: Catalog and CalendarModel (catalog.h), Account (account.h, over Stremio's core), Streams (streams.h), Tracks (tracks.h), SkipTimes (skip.h). Plain Qt, so the same source builds for
// the TV (native/build.sh) and for the Mac previews (tools/preview/build-data.sh).
#include <QtQml>
#include <QNetworkDiskCache>
#include <QQmlNetworkAccessManagerFactory>
#include "account.h"
#include "catalog.h"
#include "streams.h"
#include "tracks.h"
#include "skip.h"

// The Mac's visual check (SEIMIO_REPLAY set, see Live) loads images from a disk cache that, once it has an
// answer for an address, never asks the network again: renders fetched art at whatever moment it arrived,
// and a frost captured a card before or after its art. Qt's cache keeps only what HTTP lets it, so the rest
// is kept here: where a redirect led and which addresses have nothing (pinned.json; an episode's still is
// a redirect from metahub to TMDB, or a 404 until TMDB has one), and every picture with an expiry a
// century off (fanart.tv sends no caching headers, so Qt kept its pictures and asked for them again each
// time). Each of those asked the network on every render, and sometimes came too late for it. A
// render that did ask says so ("fetched ..."), and shots.sh renders that state again. The TV never sets it.
class FixedImages : public QQmlNetworkAccessManagerFactory {
    class Manager : public QNetworkAccessManager {
    public:
        Manager(const QString &dir, QObject *parent) : QNetworkAccessManager(parent), m_file(dir + "/pinned.json") {
            QFile f(m_file);
            if (f.open(QIODevice::ReadOnly)) m_pinned = QJsonDocument::fromJson(f.readAll()).object();
        }
    protected:
        QNetworkReply *createRequest(Operation op, const QNetworkRequest &request, QIODevice *data) override {
            QNetworkRequest r(request);
            // an address pinned to another is asked for there; one pinned to nothing fails at once
            for (int hops = 0; hops < 5 && m_pinned.contains(r.url().toString()); hops++) r.setUrl(QUrl(m_pinned[r.url().toString()].toString("missing:")));
            r.setAttribute(QNetworkRequest::CacheLoadControlAttribute, QNetworkRequest::PreferCache);
            QNetworkReply *reply = QNetworkAccessManager::createRequest(op, r, data);
            // images load on QML's own thread; the GUI thread's requests (the lab's) are left as they are
            if (QThread::currentThread() != qApp->thread()) connect(reply, &QNetworkReply::finished, this, [this, reply] {
                if (reply->attribute(QNetworkRequest::SourceIsFromCacheAttribute).toBool() || reply->url().scheme() == "missing") return;
                qWarning("fetched %s", qPrintable(reply->url().toString()));
                const QUrl to = reply->attribute(QNetworkRequest::RedirectionTargetAttribute).toUrl();
                const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
                if (to.isValid()) pin(reply->url(), reply->url().resolved(to).toString());
                else if (status == 404) pin(reply->url(), "missing:");
                else if (status == 200) {
                    // kept under our own terms, in place of what Qt kept: without an expiry date Qt asks again
                    QNetworkCacheMetaData meta;
                    meta.setUrl(reply->url()); meta.setSaveToDisk(true); meta.setExpirationDate(QDateTime::currentDateTimeUtc().addYears(100));
                    if (QIODevice *out = cache()->prepare(meta)) { out->write(reply->peek(reply->bytesAvailable())); cache()->insert(out); }
                }
            });
            return reply;
        }
    private:
        void pin(const QUrl &from, const QString &to) {
            m_pinned[from.toString()] = to;
            QFile f(m_file);
            if (f.open(QIODevice::WriteOnly)) f.write(QJsonDocument(m_pinned).toJson());
        }
        QString m_file;
        QJsonObject m_pinned;
    };
public:
    QNetworkAccessManager *create(QObject *parent) override {
        const QString dir = qEnvironmentVariable("SEIMIO_REPLAY") + "/../../../.lab/preview-images";
        auto *nam = new Manager(dir, parent);
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
    }
};

#include "data_plugin.moc"
