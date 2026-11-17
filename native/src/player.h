#pragma once
// NativePlayer: plays a stream through LG's media server (uMediaClient), in a video window exported
// from the app's window. It reads the player's events itself into properties (playing, paused,
// buffering, position, duration, failure). Once the stream has loaded it switches to the best audio track
// (the first in `languages` with a codec this TV decodes, else the first such track), seeks to
// `startFraction` of the way through, and plays. Every event is also emitted raw (`event`), and the
// latest of each kind is kept in `seen`, for the lab.
#include <QtQml>
#include <QWindow>
#include <QRegion>
#include <QTimer>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSocketNotifier>
#include <atomic>
#include <csignal>
#include <unistd.h>
#include "lg/umedia.h"

// Player events arrive on uMediaClient's own message thread; slot counts are atomics read from QML.
class NativePlayer;
class Client : public uMediaServer::uMediaClient {
public:
    Client(NativePlayer *owner) : uMediaClient(true, UMS_BUS_APP), m_owner(owner) {}
    std::atomic<int> counts[49] {};
    int eventSlot = -1; // once known, that slot's first argument is the raw JSON event
#define UMS_DEF(n) bool slot##n(void *a, void *, void *) override { counts[n]++; if (eventSlot == n) deliver(static_cast<const char *>(a)); return true; }
    UMS_SLOTS(UMS_DEF)
#undef UMS_DEF
private:
    void deliver(const char *json);
    NativePlayer *m_owner;
};

class NativePlayer : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString windowId READ windowId NOTIFY windowIdChanged)
    Q_PROPERTY(bool loaded MEMBER m_loaded NOTIFY stateChanged)
    Q_PROPERTY(bool playing MEMBER m_playing NOTIFY stateChanged)
    Q_PROPERTY(bool paused MEMBER m_paused NOTIFY stateChanged)
    Q_PROPERTY(bool buffering MEMBER m_buffering NOTIFY stateChanged)
    Q_PROPERTY(QString failure MEMBER m_failure NOTIFY stateChanged)
    Q_PROPERTY(double duration MEMBER m_duration NOTIFY stateChanged)
    Q_PROPERTY(double position MEMBER m_position NOTIFY positionChanged)
    Q_PROPERTY(int audioTrack MEMBER m_audioTrack NOTIFY stateChanged)
    Q_PROPERTY(double startFraction MEMBER m_startFraction NOTIFY settingsChanged)
    Q_PROPERTY(QStringList languages MEMBER m_languages NOTIFY settingsChanged)
    Q_PROPERTY(QVariantMap seen MEMBER m_seen NOTIFY stateChanged)
public:
    // Unload before the client goes, so a pipeline never outlives the app (a leaked one jammed the TV's audio).
    ~NativePlayer() override { live().removeAll(this); if (m_client) { m_client->unload(); delete m_client; } }
    QString windowId() const { return m_windowId; }
    // Asks LG's window manager for a video window under `window` and polls until it assigns an id.
    Q_INVOKABLE QString exportWindow(QObject *window) {
        auto w = qobject_cast<QWindow *>(window);
        if (!w) return "not a window";
        auto platform = WebOSPlatform::instance();
        if (!platform) return "no WebOSPlatform";
        auto foreign = platform->webOSForeign();
        if (!foreign) return "no WebOSForeign";
        m_exported = foreign->export_element(w, WebOSForeign::VideoObject);
        if (!m_exported) return "export_element returned null";
        QRegion full(0, 0, w->width(), w->height());
        m_exported->setExportedWindow(full, full);
        auto poll = new QTimer(this);
        connect(poll, &QTimer::timeout, this, [this, poll] {
            QString id = m_exported->getWindowId();
            if (id.isEmpty()) return;
            poll->deleteLater();
            m_windowId = id;
            emit windowIdChanged();
        });
        poll->start(50);
        return QString();
    }
    Q_INVOKABLE void setEventSlot(int n) { ensure(); m_client->eventSlot = n; }
    Q_INVOKABLE bool load(const QString &uri, const QString &payload) {
        ensure();
        m_loaded = m_playing = m_paused = m_buffering = false; m_failure.clear(); m_duration = m_position = 0; m_audioTrack = -1;
        m_tracks = QJsonArray(); m_seen.clear();
        emit stateChanged(); emit positionChanged();
        return m_client->loadAsync(uri.toStdString(), "media", payload.toStdString());
    }
    Q_INVOKABLE bool play() { return m_client && m_client->play(); }
    Q_INVOKABLE bool pause() { return m_client && m_client->pause(); }
    Q_INVOKABLE bool seek(double ms) { return m_client && m_client->seek((long long)ms); }
    Q_INVOKABLE bool selectTrack(const QString &type, int index) {
        if (!m_client) return false;
        std::string t = type.toStdString();
        return m_client->selectTrack(t, index);
    }
    Q_INVOKABLE bool unload() { m_playing = m_loaded = false; emit stateChanged(); return m_client && m_client->unload(); }
    // "slot:count" for every slot that has fired, to find which one carries raw events.
    Q_INVOKABLE QString slotCounts() const {
        QStringList out;
        if (m_client) for (int i = 0; i < 49; i++) if (m_client->counts[i]) out << QString("%1:%2").arg(i).arg(m_client->counts[i].load());
        return out.join(" ");
    }
    // One player event (JSON with one key naming it), on the GUI thread.
    void handle(const QString &json) {
        const QJsonObject e = QJsonDocument::fromJson(json.toUtf8()).object();
        if (e.isEmpty()) return;
        const QString kind = e.begin().key();
        const QJsonObject v = e.begin().value().toObject();
        if (kind == "currentTime") { m_position = v.value("currentTime").toDouble(); emit positionChanged(); return; }
        if (kind == "bufferRange") return;
        m_seen[kind] = kind == "sourceInfo" ? json : json.left(600);
        if (kind == "sourceInfo") {
            const QJsonObject program = v.value("programInfo").toArray().first().toObject();
            m_duration = program.value("duration").toDouble();
            m_tracks = program.value("audioTrackInfo").toArray();
        } else if (kind == "loadCompleted") {
            m_loaded = true;
            const int best = bestAudio();
            if (best > 0 || (best == 0 && m_tracks.size() > 1)) { std::string a("audio"); m_client->selectTrack(a, best); }
            m_audioTrack = best;
            if (m_startFraction > 0 && m_duration > 0) m_client->seek((long long)(m_duration * m_startFraction));
            m_client->play();
        } else if (kind == "playing") { m_playing = true; m_paused = false; m_buffering = false; }
        else if (kind == "paused") m_paused = true;
        else if (kind == "bufferingStart") m_buffering = true;
        else if (kind == "bufferingEnd") m_buffering = false;
        else if (kind == "endOfStream") m_playing = false;
        else if (kind == "error" && v.value("errorCode").toInt() != 0) {
            m_failure = v.value("errorText").toString(QString::number(v.value("errorCode").toInt()));
            m_playing = false; m_client->unload();
        }
        emit stateChanged();
    }
signals:
    void windowIdChanged();
    void stateChanged();
    void positionChanged();
    void settingsChanged();
    void event(const QString &json);
private:
    friend class Client;
    void ensure() { if (!m_client) { m_client = new Client(this); guard(this); } }
    // Every player unloads before the app goes, when it quits or when webOS closes it (SIGTERM), so no
    // pipeline outlives the app (a leaked one once jammed the TV's audio). The signal handler only writes to a pipe; the unloading
    // happens on the GUI thread.
    static QList<NativePlayer *> &live() { static QList<NativePlayer *> players; return players; }
    static void unloadAll() { for (NativePlayer *p : live()) if (p->m_client) p->m_client->unload(); }
    static void guard(NativePlayer *p) {
        live() << p;
        static bool installed = false;
        if (installed) return;
        installed = true;
        QObject::connect(qApp, &QCoreApplication::aboutToQuit, [] { unloadAll(); });
        static int fds[2];
        if (::pipe(fds) != 0) return;
        auto notifier = new QSocketNotifier(fds[0], QSocketNotifier::Read, qApp);
        QObject::connect(notifier, &QSocketNotifier::activated, [] { char c; if (::read(fds[0], &c, 1) > 0) { unloadAll(); QCoreApplication::quit(); } });
        auto handler = [](int) { char c = 1; if (::write(fds[1], &c, 1) < 0) {} };
        std::signal(SIGTERM, handler);
        std::signal(SIGINT, handler);
    }
    // the first audio track in a preferred language with a codec this TV decodes, else the first such
    // track, else 0 (LG names codecs as GStreamer does: ac3, eac3, aac, mp3, lpcm)
    int bestAudio() const {
        auto plays = [](const QString &c) { return c == "ac3" || c == "eac3" || c == "aac" || c == "mp3" || c.contains("pcm"); };
        for (const QString &lang : m_languages)
            for (int i = 0; i < m_tracks.size(); i++)
                if (plays(m_tracks[i].toObject().value("codec").toString()) && m_tracks[i].toObject().value("language").toString().startsWith(lang)) return i;
        for (int i = 0; i < m_tracks.size(); i++) if (plays(m_tracks[i].toObject().value("codec").toString())) return i;
        return 0;
    }
    bool m_loaded = false, m_playing = false, m_paused = false, m_buffering = false;
    QString m_failure;
    double m_duration = 0, m_position = 0, m_startFraction = 0;
    int m_audioTrack = -1;
    QStringList m_languages { "en" };
    QJsonArray m_tracks;
    QVariantMap m_seen;
    Client *m_client = nullptr;
    WebOSExported *m_exported = nullptr;
    QString m_windowId;
};

inline void Client::deliver(const char *json) {
    QString s = QString::fromUtf8(json);
    QMetaObject::invokeMethod(m_owner, [o = m_owner, s] { o->handle(s); emit o->event(s); }, Qt::QueuedConnection);
}
