#pragma once
// NativePlayer: plays a stream through LG's media server (uMediaClient), in a video window exported
// from the app's window. Track switching, seeking and every player event (as JSON) are available.
#include <QtQml>
#include <QWindow>
#include <QRegion>
#include <QTimer>
#include <atomic>
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
public:
    // Unload before the client goes, so a pipeline never outlives the app (a leaked one jammed the TV's audio).
    ~NativePlayer() override { if (m_client) { m_client->unload(); delete m_client; } }
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
    Q_INVOKABLE bool unload() { return m_client && m_client->unload(); }
    // "slot:count" for every slot that has fired, to find which one carries raw events.
    Q_INVOKABLE QString slotCounts() const {
        QStringList out;
        if (m_client) for (int i = 0; i < 49; i++) if (m_client->counts[i]) out << QString("%1:%2").arg(i).arg(m_client->counts[i].load());
        return out.join(" ");
    }
signals:
    void windowIdChanged();
    void event(const QString &json);
private:
    friend class Client;
    void ensure() { if (!m_client) m_client = new Client(this); }
    Client *m_client = nullptr;
    WebOSExported *m_exported = nullptr;
    QString m_windowId;
};

inline void Client::deliver(const char *json) {
    QString s = QString::fromUtf8(json);
    QMetaObject::invokeMethod(m_owner, [o = m_owner, s] { emit o->event(s); }, Qt::QueuedConnection);
}
