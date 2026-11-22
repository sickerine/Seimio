#pragma once
// Pictures: one loader for every picture that can be had from more than one place, and for the backdrop.
//
// Qt's own Image loads an address, keeps it on disk and in memory, and shares a download between two
// Images. What it has no notion of is a second place to get the same picture, and that is what an
// anime's art needs: its logo and backdrop are on fanart.tv, which serves about 25 KB/s a connection
// from here (2 to 9 s for a logo, 7 to 34 s for a backdrop, 2026-11-18), while Stremio's image host has
// a logo and a backdrop for the same title by its IMDb id in a fifth of a second (the same file for
// five titles in six among the most popular; for a show still airing often the franchise's where the
// title's own is its season's). So a picture has an address that lists its places, the title's own
// first, and the rule is the one Fresco calls "first available" (docs/state-and-query-research.md):
//   - The first place that is on disk is what shows: the title's own, if it has been fetched before.
//   - With none on disk, the others are fetched in their order and the title's own last, and the first
//     to come shows, for as long as it is shown.
//   - Whenever the title's own isn't what shows, it comes in on the side, so that it is on disk the
//     next time. Six of those at once, the most recent of the rest waiting, twenty-four at most.
//   - A place that fails, or answers with something that isn't a picture, leaves it to the next.
// Two Images asking for a picture share its download, a failure is tried again as Net does, and a
// download that is slow but still coming is let come (query.h, net.h). Pictures are kept on disk as their
// server allows, or thirty days when it says nothing (KeptPictures).
//
// `address()` makes such an address for the data layer; one place alone is its own address, which Qt
// loads as ever. QML's Image takes the address through the "art" image provider; the backdrop's
// BandedImage asks the same provider, for pixels as the GPU takes them.
// The loader has a thread of its own for the network and one more for decoding; nothing of a picture
// is read or decoded on the GUI thread. tools/tests/native/tst_pictures.cpp has the rules.
#include <QBuffer>
#include <QCoreApplication>
#include <QGuiApplication>
#include <QImage>
#include <QImageReader>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMutex>
#include <QQuickAsyncImageProvider>
#include <QQuickImageResponse>
#include <QQuickTextureFactory>
#include <QQuickWindow>
#include <QRunnable>
#include <QStandardPaths>
#include <QThread>
#include <QThreadPool>
#include <atomic>
#ifdef Q_OS_LINUX
#include <sys/resource.h>
#endif
#include "kept_pictures.h"
#include "net.h"

namespace pictures {

inline QString encoded(const QString &url) { return QString::fromLatin1(url.toUtf8().toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals)); }
inline QString decodedPlace(const QString &part) { return QString::fromUtf8(QByteArray::fromBase64(part.toLatin1(), QByteArray::Base64UrlEncoding)); }

// The address of a picture that can be had from these places, the title's own first (empty ones and
// repeats are left out). One place: that address itself.
inline QString address(const QStringList &places) {
    QStringList have;
    for (const QString &p : places) if (!p.isEmpty() && !have.contains(p)) have << p;
    if (have.size() < 2) return have.value(0);
    QStringList parts;
    for (const QString &p : have) parts << encoded(p);
    return QString("image://art/-/") + parts.join('.');
}

// what is asked of the loader: the places, the size it is shown at, and how
struct Want {
    QStringList places;
    QSize size;
    bool banded = false;        // for the backdrop: scaled to fit inside `size` and never up, in the GPU's own byte order
    // Whose turn comes first, at the network and at the decoder: the backdrop's, then a logo's, then a
    // card's. Told by how it is asked for: an Image that fits a logo gives the one side it is bound by,
    // a card both. (A screen of wide cards is ninety pictures at once, some 15 ms each at the decoder:
    // in one line with them, the logo and the backdrop of the title in hand came 1.5 s later.)
    int rank() const { return banded ? 2 : size.width() <= 0 || size.height() <= 0 ? 1 : 0; }
};
// an address's part after "image://art/", or any other address as the one place it is
inline Want wanted(const QString &id) {
    Want w;
    const int slash = id.indexOf('/');
    const QString flags = id.left(qMax(0, slash));
    if (slash < 0 || flags.contains(':')) { w.places << id; return w; }
    w.banded = flags.contains('f');
    for (const QString &part : id.mid(slash + 1).split('.')) if (!part.isEmpty()) w.places << decodedPlace(part);
    return w;
}

// The picture in `bytes`, decoded at the size it is wanted at (none: what was there is no picture).
// An Image's rule, as Qt has it for one that crops or fits (every one in the app): scaled so that it
// covers `size`, by the one side when only one is given, and in one of the two formats Qt's scene takes
// as they are. The backdrop's: inside `size`, never up, in the byte order the GPU takes.
inline QImage decoded(const QByteArray &bytes, const QSize &size, bool banded) {
    QBuffer buffer; buffer.setData(bytes); buffer.open(QIODevice::ReadOnly);
    QImageReader reader(&buffer);
    const QSize full = reader.size();
    if (full.isValid() && !full.isEmpty() && (size.width() > 0 || size.height() > 0)) {
        if (banded) {
            if (size.width() > 0 && size.height() > 0 && (full.width() > size.width() || full.height() > size.height())) reader.setScaledSize(full.scaled(size, Qt::KeepAspectRatio));
        } else {
            qreal ratio = 0;
            if (size.width() > 0) ratio = qreal(size.width()) / full.width();
            if (size.height() > 0) ratio = qMax(ratio, qreal(size.height()) / full.height());
            if (ratio > 0) reader.setScaledSize(QSize(qRound(full.width() * ratio), qRound(full.height() * ratio)));
        }
    }
    QImage image = reader.read();
    if (image.isNull()) return image;
    // (converted here, on a thread of the loader's, so that nothing is on the render thread)
    if (banded) image = image.convertToFormat(QImage::Format_RGBX8888);
    else if (image.format() != QImage::Format_ARGB32_Premultiplied && image.format() != QImage::Format_RGB32) image = image.convertToFormat(QImage::Format_ARGB32_Premultiplied);
    return image;
}

// The Mac's visual check loads pictures from a disk cache that, once it has an answer for an address,
// never asks the network again (SEIMIO_REPLAY set): renders fetched art at whatever moment it arrived,
// and a frost captured a card before or after its art. Qt's cache keeps only what HTTP lets it, so the
// rest is kept here: where a redirect led and which addresses have nothing (pinned.json; an episode's
// still is a redirect from metahub to TMDB, or a 404 until TMDB has one), and every picture with an
// expiry a century off. A render that did ask says so ("fetched ..."), and shots.sh renders that state
// again. One list for the two managers there are (Qt's own image reader's, and the loader's).
class Fixed : public QNetworkAccessManager {
public:
    Fixed(const QString &dir, bool pictures, QObject *parent) : QNetworkAccessManager(parent), m_pictures(pictures) {
        QMutexLocker l(&mutex());
        if (!file().isEmpty()) return;
        file() = dir + "/pinned.json";
        QFile f(file());
        if (f.open(QIODevice::ReadOnly)) pinned() = QJsonDocument::fromJson(f.readAll()).object();
    }
    static QString directory() { return qEnvironmentVariable("SEIMIO_REPLAY") + "/../../../.lab/preview-images"; }
    // where an address leads ("missing:" when it is pinned to nothing)
    static QUrl resolved(QUrl url) {
        QMutexLocker l(&mutex());
        for (int hops = 0; hops < 5 && pinned().contains(url.toString()); hops++) url = QUrl(pinned()[url.toString()].toString("missing:"));
        return url;
    }
protected:
    QNetworkReply *createRequest(Operation op, const QNetworkRequest &request, QIODevice *data) override {
        QNetworkRequest r(request);
        // an address pinned to another is asked for there; one pinned to nothing fails at once
        r.setUrl(resolved(r.url()));
        r.setAttribute(QNetworkRequest::CacheLoadControlAttribute, QNetworkRequest::PreferCache);
        QNetworkReply *reply = QNetworkAccessManager::createRequest(op, r, data);
        // (pictures: Qt's reader has a thread of its own, and the GUI thread's requests, the lab's, are left as they are)
        if (m_pictures) connect(reply, &QNetworkReply::finished, this, [this, reply] {
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
    static QMutex &mutex() { static QMutex m; return m; }
    static QString &file() { static QString f; return f; }
    static QJsonObject &pinned() { static QJsonObject p; return p; }
    static void pin(const QUrl &from, const QString &to) {
        QMutexLocker l(&mutex());
        pinned()[from.toString()] = to;
        QFile f(file());
        if (f.open(QIODevice::WriteOnly)) f.write(QJsonDocument(pinned()).toJson());
    }
    bool m_pictures;
};

// The way in to a loader from other threads. A response an Image holds outlives the loader at the app's
// end, and asks or cancels through this: under its lock the loader is either there or gone.
class Loader;
struct Door { QMutex lock; Loader *loader = nullptr; };

class Loader : public QObject {
public:
    // `image` (none: `error` says why), on the loader's thread, once for every `request`
    using Done = std::function<void(const QImage &image, const QString &error)>;

    // `dir`: where the pictures are kept on disk. `fixed`: the visual check's cache, which never asks
    // again. It is used on the thread it lives on; `request`, `cancel` and `look` from any.
    explicit Loader(const QString &dir, bool fixed = false, QObject *parent = nullptr) : QObject(parent), m_fixed(fixed) {
        m_manager = fixed ? static_cast<QNetworkAccessManager *>(new Fixed(dir, true, this)) : new QNetworkAccessManager(this);
        QNetworkDiskCache *disk = fixed ? new QNetworkDiskCache(m_manager) : new KeptPictures(m_manager);
        disk->setCacheDirectory(dir);
        disk->setMaximumCacheSize(qint64(fixed ? 500 : 400) << 20);
        m_manager->setCache(disk);
        m_cache = new query::Queries(this);
        m_net = new Net(m_cache, this, m_manager, false);
        // One picture decoded at a time. The TV has four cores, and the GUI thread, the render thread and
        // Qt's own image reader have three: with two decoding here, the Anime tour had 10, 12 and 6 late
        // frames on a warm cache where it has 7, 8 and 5 with one (2026-11-18, three runs each).
        m_pool.setMaxThreadCount(1);
        m_door->loader = this;
    }
    ~Loader() override {
        try {
            { QMutexLocker closing(&m_door->lock); m_door->loader = nullptr; }
            m_pool.waitForDone();
        } catch (...) { }
    }
    std::shared_ptr<Door> door() const { return m_door; }
    // `use` with the loader behind a door, if it is still there (from any thread)
    static void with(const std::shared_ptr<Door> &door, const std::function<void(Loader *)> &use) {
        QMutexLocker here(&door->lock);
        if (door->loader) use(door->loader);
    }
    // every picture still asked for is answered with none: before the loader ends, so that no response is left waiting
    void drain() { const auto jobs = m_jobs.values(); for (const auto &job : jobs) finish(job, QImage(), "the app is closing", QString(), false); }

    // The app's own, by its door: on a thread of its own until the app ends. At the end what is still
    // asked for is answered with nothing, the thread stops and the loader goes; the door stays, closed.
    static std::shared_ptr<Door> app() {
        static std::shared_ptr<Door> door = [] {
            const bool fixed = Net::replaying();
            auto *thread = new QThread; thread->setObjectName("pictures");
            auto *l = new Loader(fixed ? Fixed::directory() : QStandardPaths::writableLocation(QStandardPaths::CacheLocation) + "/net/art", fixed);
            l->moveToThread(thread);
            thread->start();
#ifdef Q_OS_LINUX
            // On a core they share with what draws the screen, the loader's threads get a tenth of it
            // (nice 10: Linux keeps it by thread, and the threads this one starts, the decoder's and the
            // network manager's, inherit it); on a free core they run as ever. Qt's own thread priorities
            // do nothing under Linux's default scheduler, except the idle one, which is its idle class:
            // with that the Anime tour lost no frame to a picture and pictures took over 2 s off the disk.
            QMetaObject::invokeMethod(l, [] { setpriority(PRIO_PROCESS, 0, 10); }, Qt::QueuedConnection);
#endif
            QObject::connect(qApp, &QCoreApplication::aboutToQuit, qApp, [thread, l] {
                QMetaObject::invokeMethod(l, [l] { l->drain(); }, Qt::BlockingQueuedConnection);
                thread->quit(); thread->wait();
                delete l; delete thread;
            }, Qt::DirectConnection);
            return l->door();
        }();
        return door;
    }

    quint64 request(const Want &want, Done done) {
        const quint64 ticket = ++m_tickets;
        QMetaObject::invokeMethod(this, [this, ticket, want, done] { start(ticket, want, done); }, Qt::QueuedConnection);
        return ticket;
    }
    // no longer wanted: its `done` comes at once, with no picture
    void cancel(quint64 ticket) {
        QMetaObject::invokeMethod(this, [this, ticket] { if (const auto job = m_jobs.value(ticket)) finish(job, QImage(), "cancelled", QString(), false); }, Qt::QueuedConnection);
    }
    // the lab's look: { asked, shown, onTheSide, waiting, recent: the last pictures, each { picture, from (the
    // place it came from), how ("disk" | "net"), ms, error }, fetches: what was fetched and how long each took }
    void look(std::function<void(QVariantMap)> seen) {
        QMetaObject::invokeMethod(this, [this, seen] {
            seen(QVariantMap { { "asked", m_asked }, { "shown", m_shown }, { "onTheSide", m_asides.size() }, { "waiting", m_waiting.size() }, { "under way", m_jobs.size() },
                               { "recent", m_recent.mid(qMax(0, m_recent.size() - 16)) }, { "fetches", m_cache->history().mid(qMax(0, m_cache->history().size() - 16)) } });
        }, Qt::QueuedConnection);
    }
    // lets go of every picture on disk (the lab's: to see and time a first view again)
    void forget() { QMetaObject::invokeMethod(this, [this] { if (m_manager->cache()) m_manager->cache()->clear(); }, Qt::QueuedConnection); }
    // how many pictures are decoded at once and how many come in on the side at once (the lab's, to measure)
    void tune(int decoders, int onTheSide) { QMetaObject::invokeMethod(this, [this, decoders, onTheSide] { m_pool.setMaxThreadCount(decoders); m_sideLimit = onTheSide; }, Qt::QueuedConnection); }
    // whether an address is on disk and may still be used from there
    bool kept(const QString &url) const {
        QAbstractNetworkCache *disk = m_manager->cache();
        const QUrl at = m_fixed ? Fixed::resolved(QUrl(url)) : QUrl(url);
        if (!disk || at.scheme() == "missing") return false;
        const QNetworkCacheMetaData meta = disk->metaData(at);
        return meta.isValid() && (m_fixed || !meta.expirationDate().isValid() || meta.expirationDate() > QDateTime::currentDateTimeUtc());
    }
    query::Queries *queries() const { return m_cache; }
    int idleMs() const { return m_net->idleMs; }
    void setIdleMs(int ms) { m_net->idleMs = ms; }

private:
    // (`over` is read by the decoding thread too)
    struct Job { quint64 ticket; Want want; Done done; QVector<int> order; int at = 0; std::atomic<bool> over { false }; qint64 askedAt = 0, fetchedAt = 0; QStringList failed; };

    void start(quint64 ticket, const Want &want, Done done) {
        auto job = std::make_shared<Job>();
        job->ticket = ticket; job->want = want; job->done = std::move(done); job->askedAt = m_cache->now();
        m_jobs.insert(ticket, job); ++m_asked;
        const QStringList &places = want.places;
        int onDisk = -1;
        for (int i = 0; i < places.size() && onDisk < 0; i++) if (kept(places[i])) onDisk = i;
        // what is on disk first; then the others in their order, the title's own last: it is the slow one
        if (onDisk >= 0) job->order << onDisk;
        for (int i = 1; i < places.size(); i++) if (i != onDisk) job->order << i;
        if (onDisk != 0 && !places.isEmpty()) job->order << 0;
        if (onDisk != 0 && places.size() > 1) {
            aside(places[0]);
            // With nothing on disk, the title's own may be the first to come: an alternative that stalls
            // (nothing arriving for 20 s) is not waited out with its own picture already in hand.
            if (onDisk < 0 && m_asides.contains(places[0])) {
                const QString own = places[0];
                query::Options o; o.keepMs = 0; o.priority = -1; o.retries = 2;
                m_net->read(own, QByteArray(), o, [this, job, own](std::shared_ptr<const Answer> a, const query::Failure &) {
                    if (!job->over && a && a->status >= 200 && a->status < 300) decode(job, own, a, [] {});
                });
            }
        }
        next(job);
    }
    void next(const std::shared_ptr<Job> &job) {
        if (job->over) return;
        if (job->at >= job->order.size()) { finish(job, QImage(), job->failed.isEmpty() ? QString("no address") : job->failed.join("; "), QString(), false); return; }
        const QString url = job->want.places[job->order[job->at++]];
        query::Options o; o.keepMs = 0; o.priority = job->want.rank() > 0 ? 1 : 0;
        o.retries = job->at < job->order.size() ? 0 : 2;        // (with another place to turn to, a failure goes straight there)
        m_net->read(url, QByteArray(), o, [this, job, url](std::shared_ptr<const Answer> a, const query::Failure &why) {
            if (job->over) return;
            if (!a || a->status < 200 || a->status >= 300) { job->failed << QString("%1 %2").arg(a ? a->status : why.status).arg(a ? QString("from %1").arg(QUrl(url).host()) : why.reason.left(40)); next(job); return; }
            decode(job, url, a, [this, job, url] { job->failed << "no picture from " + QUrl(url).host(); next(job); });
        });
    }
    // The bytes of one place decoded on the decoder's thread, and the job answered with the picture;
    // `otherwise` when they are no picture. (One no longer wanted by the time its turn comes is not
    // decoded: along a row walked fast the pictures of the titles passed held the one of the title
    // rested on back 0.9 s, off the disk.)
    void decode(const std::shared_ptr<Job> &job, const QString &url, const std::shared_ptr<const Answer> &a, std::function<void()> otherwise) {
        const QSize size = job->want.size; const bool banded = job->want.banded, cached = a->cached;
        if (!job->fetchedAt) job->fetchedAt = m_cache->now();
        m_pool.start(new Work([this, job, url, a, size, banded, cached, otherwise] {
            const QImage image = job->over ? QImage() : decoded(a->body, size, banded);
            QMetaObject::invokeMethod(this, [this, job, url, image, cached, otherwise] {
                if (job->over) return;
                if (image.isNull()) { otherwise(); return; }
                finish(job, image, QString(), url, cached);
            }, Qt::QueuedConnection);
        }), job->want.rank());
    }
    void finish(const std::shared_ptr<Job> &job, const QImage &image, const QString &error, const QString &from, bool cached) {
        if (job->over) return;
        job->over = true;
        m_jobs.remove(job->ticket);
        if (!image.isNull()) ++m_shown;
        m_recent << QVariantMap { { "picture", job->want.places.value(0).right(44) }, { "from", QUrl(from).host() }, { "how", image.isNull() ? "" : cached ? "disk" : "net" },
                                  { "ms", m_cache->now() - job->askedAt }, { "error", error },
                                  // (what took it: the bytes, then its turn at the decoder and the decoding)
                                  { "fetch", job->fetchedAt ? job->fetchedAt - job->askedAt : -1 }, { "decode", job->fetchedAt ? m_cache->now() - job->fetchedAt : -1 },
                                  { "as", QString(job->want.banded ? "backdrop" : job->want.rank() ? "logo" : "card") + QString(" %1x%2").arg(job->want.size.width()).arg(job->want.size.height()) } };
        if (m_recent.size() > 64) m_recent = m_recent.mid(32);
        const Done done = std::move(job->done);
        job->done = nullptr;
        if (done) done(image, error);
    }
    // A title's own picture, fetched for the next time: it is only kept on disk. Six at once (the slow
    // host serves each connection its 25 KB/s, so six bring six times as much), the latest of the rest
    // next, twenty-four waiting at most: someone walking a long chart asks for hundreds.
    void aside(const QString &url) {
        if (m_asides.contains(url) || kept(url)) return;
        if (m_asides.size() >= m_sideLimit) { m_waiting.removeAll(url); m_waiting << url; while (m_waiting.size() > 24) m_waiting.removeFirst(); return; }
        m_asides << url;
        query::Options o; o.keepMs = 0; o.priority = -1; o.retries = 2;
        m_net->read(url, QByteArray(), o, [this, url](std::shared_ptr<const Answer>, const query::Failure &) {
            m_asides.remove(url);
            if (!m_waiting.isEmpty()) aside(m_waiting.takeLast());
        });
    }
    struct Work : QRunnable { std::function<void()> fn; explicit Work(std::function<void()> f) : fn(std::move(f)) {} void run() override { fn(); } };

    std::shared_ptr<Door> m_door = std::make_shared<Door>();
    bool m_fixed;
    QNetworkAccessManager *m_manager;
    query::Queries *m_cache;
    Net *m_net;
    QThreadPool m_pool;
    QHash<quint64, std::shared_ptr<Job>> m_jobs;
    QSet<QString> m_asides; QStringList m_waiting; int m_sideLimit = 6;
    QVariantList m_recent; int m_asked = 0, m_shown = 0;
    std::atomic<quint64> m_tickets { 0 };
};

// a picture for the backdrop, as it was decoded (Qt's own factory turns anything but two formats into another)
class Plain : public QQuickTextureFactory {
public:
    explicit Plain(const QImage &image) : m_image(image) {}
    QSGTexture *createTexture(QQuickWindow *window) const override { return window->createTextureFromImage(m_image); }
    QSize textureSize() const override { return m_image.size(); }
    int textureByteCount() const override { return int(m_image.sizeInBytes()); }
    QImage image() const override { return m_image; }
private:
    QImage m_image;
};
class Response : public QQuickImageResponse {
public:
    // `finished` is sent from this object's own thread, on a later turn of it: whoever asked has had its
    // hands on the response by then. Sent from the loader's thread it can come before the one asking has
    // connected to it, and Qt's own check for that only sees a signal sent on its reader's thread. (At the
    // app's end the loader answers everything still asked for before Qt's reader stops: Loader::app.)
    Response(const std::shared_ptr<Door> &door, const Want &want) : m_door(door), m_banded(want.banded) {
        bool asked = false;
        Loader::with(door, [&](Loader *loader) {
            asked = true;
            m_ticket = loader->request(want, [this](const QImage &image, const QString &error) {
                m_image = image; m_error = error;
                QMetaObject::invokeMethod(this, [this] { emit finished(); }, Qt::QueuedConnection);
            });
        });
        if (!asked) { m_error = "the app is closing"; QMetaObject::invokeMethod(this, [this] { emit finished(); }, Qt::QueuedConnection); }
    }
    QQuickTextureFactory *textureFactory() const override {
        // (an Image's is Qt's own factory: the picture is laid out by the size it was decoded at, as one
        // Qt loaded itself is)
        return m_image.isNull() ? nullptr : m_banded ? new Plain(m_image) : QQuickTextureFactory::textureFactoryForImage(m_image);
    }
    QString errorString() const override { return m_error; }
    void cancel() override { const quint64 ticket = m_ticket; Loader::with(m_door, [ticket](Loader *loader) { loader->cancel(ticket); }); }
private:
    std::shared_ptr<Door> m_door; bool m_banded; quint64 m_ticket = 0;
    QImage m_image; QString m_error;
};

// "image://art/...": QML's Image asks here for an address `address()` made
class Provider : public QQuickAsyncImageProvider {
public:
    // (On a screen with more than one pixel a point, Qt asks a provider for that many times the size an
    // Image gave, and lays the picture out as that dense. It does no such thing for an address it loads
    // itself, so the size is taken back here: a picture comes out the same through either. The TV's
    // screen is one to one; the Mac's, where the previews render, is two.)
    QQuickImageResponse *requestImageResponse(const QString &id, const QSize &requestedSize) override {
        Want want = wanted(id);
        const qreal dense = qGuiApp ? qGuiApp->devicePixelRatio() : 1;
        want.size = dense > 1 ? QSize(qRound(requestedSize.width() / dense), qRound(requestedSize.height() / dense)) : requestedSize;
        return new Response(Loader::app(), want);
    }
};

}  // namespace pictures
