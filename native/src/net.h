#pragma once
// Net: the way out to the network for the data layer.
//
// `request` and `exists` are reads, and go through the query cache (query.h): the same address asked for
// twice at once is fetched once, an answer can be kept (`freshMs`), and a read that fails for a passing
// reason is tried again before anyone hears of it:
//   - no answer at all, or the service is in trouble (a 5xx): again after 1 s, then 2 s;
//   - too many requests (429): again when the service says, or in 20 s (AniList allows about 30 a minute);
//   - the service says no (any other 4xx): that is the answer, kept like one;
//   - nothing within 20 s: a failure, and not tried again (it would be another 20 s).
// `send` is the transfer itself, once, with nothing kept or tried again: Stremio's core is a client of
// its own (it writes as well as reads, and decides itself what to ask again), so its requests go
// straight out.
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
#include "query.h"

// what a service said: its status and the bytes that came with it
struct Answer { QByteArray body; int status = 0; };

class Net : public QObject {
public:
    using Done = std::function<void(const QByteArray &, bool, int)>;
    // `cache`: the thread's query cache (none: `send` only)
    explicit Net(query::Queries *cache = nullptr, QObject *parent = nullptr) : QObject(parent), m_cache(cache) {}
    static bool replaying() { return !qEnvironmentVariableIsEmpty("SEIMIO_REPLAY"); }

    // A GET when `body` is empty, else a JSON POST that reads (a GraphQL query). `done(body, ok, status)`
    // on a later turn: `ok` for a 2xx; status 0 with no body when nothing answered. An answer is kept
    // `freshMs`, and asked for within that is not asked of the network again.
    void request(const QString &url, const QByteArray &body, Done done, qint64 freshMs = 0) {
        query::Options o; o.freshMs = freshMs; o.keepMs = freshMs; o.retries = 2;
        m_cache->fetch<Answer>({ "net", url, body.isEmpty() ? QString() : QString::fromLatin1(QCryptographicHash::hash(body, QCryptographicHash::Sha1).toHex()) },
                               [this, url, body](query::Call<Answer> call) { read(url, body, call); }, o,
                               [done](std::shared_ptr<const Answer> a, const query::Failure &why) {
            if (a) done(a->body, a->status >= 200 && a->status < 300, a->status); else done(QByteArray(), false, why.status);
        });
    }
    // Whether something is at `url` (a HEAD): `done(false)` only when the server says there is nothing
    // (404), so a check that failed otherwise loses nothing. Kept ten minutes. A preview answers from its
    // recordings ("true" or "false", by the address); what isn't recorded is there.
    void exists(const QString &url, std::function<void(bool)> done) {
        query::Options o; o.freshMs = o.keepMs = 10 * 60 * 1000; o.retries = 0;
        m_cache->fetch<bool>({ "head", url }, [this, url](query::Call<bool> call) { head(url, call); }, o,
                             [done](std::shared_ptr<const bool> there, const query::Failure &) { done(!there || *there); });
    }

    // The transfer itself, once: `done(body, ok, status)` when it ends, status 0 when nothing answered.
    void send(const QString &url, const QByteArray &body, Done done, bool secret = false) {
        transfer(url, body, secret, 0, [done](const Reply &r) { done(r.body, r.ok, r.status); });
    }

private:
    // how a transfer ended; `final`: asking again would end the same (nothing in 20 s, not in the recordings)
    struct Reply { QByteArray body; int status = 0; bool ok = false, final = false; int waitMs = 0; QString error; };
    static QString recording(const QString &url, const QByteArray &body) {
        static const QString replay = qEnvironmentVariable("SEIMIO_REPLAY");
        return replay.isEmpty() ? QString() : replay + "/" + QCryptographicHash::hash(url.toUtf8() + body, QCryptographicHash::Sha1).toHex() + ".json";
    }
    static bool recordingNew() { return !qEnvironmentVariableIsEmpty("SEIMIO_RECORD"); }

    // a read's fetch: the transfer, its outcome sorted as the top says
    void read(const QString &url, const QByteArray &body, query::Call<Answer> call) {
        const auto stop = transfer(url, body, false, call.priority(), [call](const Reply &r) {
            const bool no = r.status >= 400 && r.status < 500 && r.status != 408 && r.status != 429;
            if (r.ok || no) { call.ok(Answer { r.body, r.status }); return; }
            query::Failure why; why.status = r.status; why.reason = r.error;
            why.final = r.final;
            if (r.status == 429) why.waitMs = r.waitMs > 0 ? r.waitMs : 20000;
            call.fail(why);
        });
        call.onCancel(stop);
    }
    void head(const QString &url, query::Call<bool> call) {
        static const QString replay = qEnvironmentVariable("SEIMIO_REPLAY");
        const QString file = replay.isEmpty() ? QString() : replay + "/" + QCryptographicHash::hash("HEAD " + url.toUtf8(), QCryptographicHash::Sha1).toHex() + ".json";
        if (!file.isEmpty()) {
            QFile f(file);
            const bool recorded = f.open(QIODevice::ReadOnly);
            if (recorded || !recordingNew()) { call.ok(!recorded || f.readAll().trimmed() != "false"); return; }
        }
        QNetworkRequest r { QUrl(url) };
        r.setHeader(QNetworkRequest::UserAgentHeader, "seimio/0.1");
        r.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
        QNetworkReply *reply = m_net.head(r);
        QTimer::singleShot(8000, reply, &QNetworkReply::abort);
        connect(reply, &QNetworkReply::finished, this, [reply, call, file] {
            reply->deleteLater();
            const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
            if (!file.isEmpty() && (status == 200 || status == 404)) { QFile f(file); if (f.open(QIODevice::WriteOnly)) f.write(status == 404 ? "false" : "true"); }
            if (status == 200 || status == 404) call.ok(status != 404);
            else { query::Failure why; why.status = status; why.reason = reply->errorString(); call.fail(why); }
        });
        call.onCancel([reply] { reply->disconnect(); reply->abort(); reply->deleteLater(); });
    }

    // One request, answered from the recordings in a preview and on the wire otherwise; `done` on a later
    // turn when it ends, unless the function it returns stopped it first.
    std::function<void()> transfer(const QString &url, const QByteArray &body, bool secret, int priority, std::function<void(const Reply &)> done) {
        auto later = [this, done](Reply r) { QTimer::singleShot(0, this, [done, r] { done(r); }); return [] {}; };
        if (replaying() && secret) { Reply none; none.final = true; return later(none); }
        const QString file = secret ? QString() : recording(url, body);
        if (!file.isEmpty()) {
            QFile f(file);
            if (f.open(QIODevice::ReadOnly)) { Reply r; r.body = f.readAll(); r.status = 200; r.ok = true; return later(r); }
            if (!recordingNew()) { Reply none; none.final = true; none.error = "not recorded"; return later(none); }
        }
        // (A host this Qt can't reach is asked through a relay, SEIMIO_VIA="host=http://127.0.0.1:port":
        // the Mac's Qt fails the TLS handshake with arm.haglund.dev, where a franchise starts, so
        // tools/franchises.sh runs one beside it.)
        static const QStringList via = qEnvironmentVariable("SEIMIO_VIA").split('=');
        QNetworkRequest r { QUrl(via.size() == 2 && url.startsWith("https://" + via[0] + "/") ? via[1] + url.mid(8 + via[0].size()) : url) };
        r.setHeader(QNetworkRequest::UserAgentHeader, "seimio/0.1");
        r.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
        r.setPriority(priority > 0 ? QNetworkRequest::HighPriority : priority < 0 ? QNetworkRequest::LowPriority : QNetworkRequest::NormalPriority);
        if (!body.isEmpty()) { r.setHeader(QNetworkRequest::ContentTypeHeader, "application/json"); r.setRawHeader("Accept", "application/json"); }
        QNetworkReply *reply = body.isEmpty() ? m_net.get(r) : m_net.post(r, body);
        auto late = std::make_shared<bool>(false);
        QTimer::singleShot(20000, reply, [reply, late] { *late = true; reply->abort(); });
        connect(reply, &QNetworkReply::finished, this, [reply, done, late, file] {
            reply->deleteLater();
            Reply out;
            out.body = reply->readAll();
            out.ok = reply->error() == QNetworkReply::NoError;
            out.status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
            out.final = *late;
            out.error = *late ? QStringLiteral("no answer in 20 s") : reply->errorString();
            out.waitMs = qBound(0, reply->rawHeader("Retry-After").toInt(), 120) * 1000;
            if (out.ok && !file.isEmpty()) { QDir().mkpath(QFileInfo(file).path()); QFile f(file); if (f.open(QIODevice::WriteOnly)) f.write(out.body); }
            done(out);
        });
        return [reply = QPointer<QNetworkReply>(reply)] { if (reply) { reply->disconnect(); reply->abort(); reply->deleteLater(); } };
    }

    query::Queries *m_cache;
    QNetworkAccessManager m_net { this };
};
