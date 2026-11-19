#pragma once
// A disk cache that keeps a picture whose server says nothing of how long it keeps for thirty days.
// fanart.tv's backdrops and logos come with no Cache-Control, Expires, ETag or Last-Modified, so the copy
// on disk was never trusted and each was fetched again at every launch: a megabyte of backdrop at the
// 25 KB/s a connection that host serves, 40 s with the title before it still on screen. (Pictures only:
// the lab's switches come through the same manager and must be read anew.)
#include <QDateTime>
#include <QNetworkDiskCache>

class KeptPictures : public QNetworkDiskCache {
public:
    using QNetworkDiskCache::QNetworkDiskCache;
    QIODevice *prepare(const QNetworkCacheMetaData &meta) override {
        QNetworkCacheMetaData kept = meta;
        bool picture = false, dated = meta.expirationDate().isValid() || meta.lastModified().isValid();
        for (const auto &h : meta.rawHeaders()) {
            const QByteArray name = h.first.toLower();
            if (name == "content-type") picture = h.second.toLower().startsWith("image/");
            if (name == "cache-control" || name == "etag") dated = true;
        }
        if (picture && !dated) kept.setExpirationDate(QDateTime::currentDateTimeUtc().addDays(30));
        return QNetworkDiskCache::prepare(kept);
    }
    // brings what is on disk down to the size allowed now (Qt does it only as it writes)
    void trim() { expire(); }
};
