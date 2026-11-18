#pragma once
// Stremio's own core (core/, Rust: accounts, the library, watch state, catalogs, the player's progress
// rules) for Qt. One for the process, on the thread that first asks for it (the GUI's). The core runs on
// its own threads; what it says comes back here through queued calls, and its HTTP is answered by Http.
//   dispatch(model, action)   the core's Action as JSON, to one of its models or ("") to all
//   state(model), view(name)  JSON, read on any thread
//   changed(models)           those models' state is new;  event(name, args)  the core's events
#include <QCoreApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStandardPaths>
#include "http.h"

extern "C" {
void seimio_core_start(const char *dir, void (*onEvent)(void *, const char *, const char *),
                       void (*onFetch)(void *, quint64, const char *, const char *, const char *, const uchar *, size_t), void *user);
void seimio_core_fetched(quint64 id, quint16 status, const uchar *body, size_t len);
char *seimio_core_dispatch(const char *model, const char *action);
char *seimio_core_state(const char *model);
char *seimio_core_view(const char *name);
char *seimio_core_select(const char *what, const char *choice);
void seimio_core_free(char *);
}

class Core : public QObject {
    Q_OBJECT
public:
    static Core *instance() { static Core *core = new Core(qApp); return core; }
    bool ready() const { return m_ready; }

    // The account's files: the app's own data folder; for the previews, the folder beside their recordings,
    // or SEIMIO_ACCOUNT (an empty one renders the app signed out).
    void start() {
        if (m_started) return;
        m_started = true;
        const QString dir = qEnvironmentVariable("SEIMIO_ACCOUNT", Http::replaying() ? qEnvironmentVariable("SEIMIO_REPLAY") + "/../account"
                                                 : QStandardPaths::writableLocation(QStandardPaths::AppDataLocation) + "/account");
        seimio_core_start(QDir::cleanPath(dir).toUtf8().constData(), &Core::onEvent, &Core::onFetch, this);
    }
    void dispatch(const char *model, const QJsonObject &action) {
        if (char *why = seimio_core_dispatch(model, QJsonDocument(action).toJson(QJsonDocument::Compact).constData())) {
            qWarning("core: %s not sent to %s: %s", qPrintable(action.value("action").toString()), model, why);
            seimio_core_free(why);
        }
    }
    // one choice of a browsable model's filters (`select` in core/src/lib.rs)
    void select(const QByteArray &what, const QByteArray &choice) {
        if (char *why = seimio_core_select(what.constData(), choice.constData())) { qWarning("core: %s = %s: %s", what.constData(), choice.constData(), why); seimio_core_free(why); }
    }
    static QJsonDocument state(const char *model) { return taken(seimio_core_state(model)); }
    static QJsonDocument view(const char *name) { return taken(seimio_core_view(name)); }
    // { action, args } and { model, args }: the two shapes the core's actions nest
    static QJsonObject action(const char *name, const QJsonValue &args = QJsonValue(QJsonValue::Undefined)) {
        QJsonObject o { { "action", name } }; if (!args.isUndefined()) o["args"] = args; return o;
    }
    static QJsonObject load(const char *model, const QJsonValue &args = QJsonValue(QJsonValue::Undefined)) {
        QJsonObject o { { "model", model } }; if (!args.isUndefined()) o["args"] = args; return action("Load", o);
    }

signals:
    void readyChanged();
    void changed(const QStringList &models);
    void event(const QString &name, const QJsonObject &args);

private:
    explicit Core(QObject *parent) : QObject(parent) {}
    static QJsonDocument taken(char *json) {
        if (!json) return QJsonDocument();
        const QJsonDocument d = QJsonDocument::fromJson(json);
        seimio_core_free(json);
        return d;
    }
    // both run on the core's threads
    static void onEvent(void *user, const char *kind, const char *json) {
        Core *core = static_cast<Core *>(user);
        const QByteArray k(kind), j(json);
        QMetaObject::invokeMethod(core, [core, k, j] {
            if (k == "ready") { core->m_ready = true; emit core->readyChanged(); }
            else if (k == "state") { QStringList models; for (const QJsonValue &v : QJsonDocument::fromJson(j).array()) models << v.toString(); emit core->changed(models); }
            else if (k == "event") { const QJsonObject e = QJsonDocument::fromJson(j).object(); emit core->event(e.value("event").toString(), e.value("args").toObject()); }
        }, Qt::QueuedConnection);
    }
    static void onFetch(void *user, quint64 id, const char *method, const char *url, const char *, const uchar *body, size_t len) {
        Core *core = static_cast<Core *>(user);
        const QString u = QString::fromUtf8(url);
        const QByteArray b(reinterpret_cast<const char *>(body), int(len));
        // a POST is the Stremio API (the key goes with it, the library comes back); a GET is an addon
        const bool secret = qstrcmp(method, "GET") != 0;
        QMetaObject::invokeMethod(core, [core, id, u, b, secret] {
            core->m_http.request(u, b, [id](const QByteArray &data, bool, int status) {
                seimio_core_fetched(id, quint16(status), reinterpret_cast<const uchar *>(data.constData()), size_t(data.size()));
            }, secret);
        }, Qt::QueuedConnection);
    }
    Http m_http { this };
    bool m_started = false, m_ready = false;
};
