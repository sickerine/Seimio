#pragma once
// NativePlayer: plays a stream through LG's media server (uMediaClient), in a video window exported
// from the app's window. It reads the player's events itself into properties (playing, paused,
// buffering, position, duration, failure). Once the stream has loaded it switches to the best audio track
// (the first in `languages` with a codec this TV decodes, else the first such track), seeks to
// `startFraction` of the way through, and plays. Every event is also emitted raw (`event`), and the
// latest of each kind is kept in `seen`, for the lab.
#include <QtQml>
#include <QElapsedTimer>
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
    Q_PROPERTY(double startAt MEMBER m_startAt NOTIFY settingsChanged)          // ms; wins over startFraction (-1: none)
    Q_PROPERTY(QStringList languages MEMBER m_languages NOTIFY settingsChanged)
    Q_PROPERTY(QVariantMap seen MEMBER m_seen NOTIFY seenChanged)
    Q_PROPERTY(QVariantList audioTracks MEMBER m_audioTracks NOTIFY audioTracksChanged)     // { lang, codec } per audio track
    Q_PROPERTY(int preferredAudio MEMBER m_preferredAudio NOTIFY settingsChanged)     // chosen before load ends, or -1
public:
    // Unload before the client goes, so a pipeline never outlives the app (a leaked one jammed the TV's audio).
    ~NativePlayer() override {
        live().removeAll(this);
        m_control.quit(); m_control.wait();                             // queued commands finish first
        if (m_client) { m_client->unload(); delete m_client; }
    }
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
    // queued with the other calls, so an unload or seek for the last stream can't land after it
    Q_INVOKABLE void load(const QString &uri, const QString &payload) {
        ensure();
        m_loaded = m_playing = m_paused = m_buffering = false; m_failure.clear(); m_duration = m_position = 0; m_audioTrack = -1;
        m_tracks = QJsonArray(); m_seen.clear(); m_audioTracks.clear(); m_preferredAudio = -1;
        emit stateChanged(); emit positionChanged();
        command([u = uri.toStdString(), p = payload.toStdString()](Client *c) { c->loadAsync(u, "media", p); });
    }
    // LG's client calls are synchronous calls to the media server (50-150 ms on the TV), so they run on
    // their own thread, in order; the GUI thread never waits on them
    Q_INVOKABLE void play() { command([](Client *c) { c->play(); }); }
    Q_INVOKABLE void pause() { command([](Client *c) { c->pause(); }); }
    // the position moves to the target at once: LG goes on reporting the old time while it seeks, which
    // drew the bar back to where it was before it jumped forward
    Q_INVOKABLE void seek(double ms) {
        m_position = ms; m_seekTo = ms; m_seeking = true; m_seekLanded = false; m_seekClock.restart(); emit positionChanged();
        command([ms](Client *c) { c->seek((long long)ms); });
    }
    Q_INVOKABLE void selectAudio(int index) { command([index](Client *c) { std::string a("audio"); c->selectTrack(a, index); }); m_audioTrack = index; emit stateChanged(); }
    Q_INVOKABLE void mute(bool on) { command([on](Client *c) { c->setAudioMute(on); }); }
    Q_INVOKABLE void unload() { m_playing = m_loaded = false; emit stateChanged(); command([](Client *c) { c->unload(); }); }
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
        if (kind == "currentTime") {
            const double t = v.value("currentTime").toDouble();
            // until LG says the seek is done (or 10 s pass), a time far from the target is the old one
            if (m_seeking && !m_seekLanded && qAbs(t - m_seekTo) > 3000 && m_seekClock.elapsed() < 10000) return;
            m_seeking = false; m_seekLanded = false;
            m_position = t; emit positionChanged(); return;
        }
        if (kind == "seekDone") m_seekLanded = true;
        if (kind == "bufferRange") return;
        m_seen[kind] = kind == "sourceInfo" ? json : json.left(600);
        emit seenChanged();
        if (kind == "sourceInfo") {
            const QJsonObject program = v.value("programInfo").toArray().first().toObject();
            m_duration = program.value("duration").toDouble();
            m_tracks = program.value("audioTrackInfo").toArray();
            m_audioTracks.clear();
            for (const QJsonValue &t : m_tracks) m_audioTracks << QVariantMap { { "lang", t.toObject().value("language").toString() }, { "codec", t.toObject().value("codec").toString() } };
            emit audioTracksChanged();
        } else if (kind == "loadCompleted") {
            m_loaded = true;
            const int best = m_preferredAudio >= 0 && m_preferredAudio < m_tracks.size() ? m_preferredAudio : bestAudio();
            const bool select = best > 0 || (best == 0 && m_tracks.size() > 1);
            const long long at = m_startAt >= 0 ? (long long)m_startAt : m_startFraction > 0 && m_duration > 0 ? (long long)(m_duration * m_startFraction) : -1;
            m_audioTrack = best;
            command([select, best, at](Client *c) {
                c->setSubtitleEnable(false);                                    // ours draws them (SubtitleLayer)
                if (select) { std::string a("audio"); c->selectTrack(a, best); }
                if (at >= 0) c->seek(at);
                c->play();
            });
        } else if (kind == "playing") { m_playing = true; m_paused = false; m_buffering = false; }
        else if (kind == "paused") m_paused = true;
        else if (kind == "bufferingStart") m_buffering = true;
        else if (kind == "bufferingEnd") m_buffering = false;
        else if (kind == "endOfStream") m_playing = false;
        else if (kind == "error" && v.value("errorCode").toInt() != 0) {
            m_failure = v.value("errorText").toString(QString::number(v.value("errorCode").toInt()));
            m_playing = false; command([](Client *c) { c->unload(); });
        }
        emit stateChanged();
    }
signals:
    void windowIdChanged();
    void stateChanged();
    void positionChanged();
    void settingsChanged();
    void seenChanged();
    void audioTracksChanged();
    void event(const QString &json);
private:
    friend class Client;
    template <typename F> void command(F f) {
        if (!m_client) return;
        if (!m_control.isRunning()) { m_controlObject.moveToThread(&m_control); m_control.start(); }
        Client *c = m_client;
        QMetaObject::invokeMethod(&m_controlObject, [c, f] { f(c); }, Qt::QueuedConnection);
    }
    QThread m_control;
    QObject m_controlObject;
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
    double m_duration = 0, m_position = 0, m_startFraction = 0, m_startAt = -1, m_seekTo = 0;
    bool m_seeking = false, m_seekLanded = false;
    QElapsedTimer m_seekClock;
    int m_audioTrack = -1;
    QStringList m_languages { "en" };
    QJsonArray m_tracks;
    QVariantList m_audioTracks;
    int m_preferredAudio = -1;
    QVariantMap m_seen;
    Client *m_client = nullptr;
    WebOSExported *m_exported = nullptr;
    QString m_windowId;
};

inline void Client::deliver(const char *json) {
    QString s = QString::fromUtf8(json);
    QMetaObject::invokeMethod(m_owner, [o = m_owner, s] { o->handle(s); emit o->event(s); }, Qt::QueuedConnection);
}
