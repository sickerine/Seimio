#pragma once
// One way out to the network for the data layer (Live, Franchise, the Stremio core's requests): GET when
// `body` is empty, else a JSON POST; `done(body, ok, status)` on the caller's thread, status 0 when
// nothing answered.
//
// The Mac's visual check needs the same data every run: with SEIMIO_REPLAY set to a folder, answers come
// from recordings there (by request), and SEIMIO_RECORD=1 records what's missing (tools/preview/shots.sh
// --record). A request marked `secret` (the Stremio API's: it carries the account's key and answers with
// the library) is never recorded and never asked in a preview. The app on the TV sets neither.
#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QTimer>
#include <QUrl>
#include <functional>

class Http : public QObject {
    Q_OBJECT
public:
    using Done = std::function<void(const QByteArray &, bool, int)>;
    explicit Http(QObject *parent = nullptr) : QObject(parent) {}
    static bool replaying() { return !qEnvironmentVariableIsEmpty("SEIMIO_REPLAY"); }

    void request(const QString &url, const QByteArray &body, Done done, bool secret = false) {
        static const QString replay = qEnvironmentVariable("SEIMIO_REPLAY");
        const QString file = replay.isEmpty() || secret ? QString() : replay + "/" + QCryptographicHash::hash(url.toUtf8() + body, QCryptographicHash::Sha1).toHex() + ".json";
        auto later = [this, done](const QByteArray &data, bool ok, int status) { QTimer::singleShot(0, this, [done, data, ok, status] { done(data, ok, status); }); };
        if (!replay.isEmpty() && secret) { later(QByteArray(), false, 0); return; }
        if (!file.isEmpty()) {
            QFile f(file);
            if (f.open(QIODevice::ReadOnly)) { later(f.readAll(), true, 200); return; }
            if (qEnvironmentVariableIsEmpty("SEIMIO_RECORD")) { later(QByteArray(), false, 0); return; }
        }
        QNetworkRequest r { QUrl(url) };
        r.setHeader(QNetworkRequest::UserAgentHeader, "seimio/0.1");
        r.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
        if (!body.isEmpty()) { r.setHeader(QNetworkRequest::ContentTypeHeader, "application/json"); r.setRawHeader("Accept", "application/json"); }
        QNetworkReply *reply = body.isEmpty() ? m_net.get(r) : m_net.post(r, body);
        QTimer::singleShot(20000, reply, &QNetworkReply::abort);
        connect(reply, &QNetworkReply::finished, this, [reply, done, file] {
            reply->deleteLater();
            const QByteArray data = reply->readAll();
            const bool ok = reply->error() == QNetworkReply::NoError;
            if (ok && !file.isEmpty()) { QDir().mkpath(QFileInfo(file).path()); QFile f(file); if (f.open(QIODevice::WriteOnly)) f.write(data); }
            done(data, ok, reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt());
        });
    }

private:
    QNetworkAccessManager m_net { this };
};
