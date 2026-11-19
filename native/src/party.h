#pragma once
// The watch party, from the TV's side. Friends follow what this TV plays through a relay
// (stremio-webos/watch-web/server): the TV tells it what plays and where it is, and the relay tells the
// TV who is watching and which of them can play it yet.
//   relay      the relay's address for a TV: ws(s)://host/ws?role=tv&room=...&key=... (none: no party).
//              It is reached as soon as it is set and for as long as the app runs, playing or not: who
//              is in the room shows on the tabs too.
//   playing({ media, title, episode, position, duration, paused, buffering })   what plays now, said
//              on every change and every time the player says where it is (ms). The moment it is said
//              is the moment the position was true, which is what the followers keep time by.
//   stopped()  nothing plays any more
//   viewers    [{ id, loading }]: one a follower, `loading` while it can't play what the TV has yet
//   loading    one of them is
//   waits      his setting: something starting waits for the room to have loaded it (kept on the TV)
// To the relay: `state` (a session a file, a sequence a message, the position in seconds with when it
// was sampled, and what happened: play, pause, seeked, or just a heartbeat), twice a second at least
// while something is in hand, since the relay takes a TV silent for six seconds to have gone; `idle`;
// and `clock-pong`, the answers by which the relay learns this clock.
#include <QDateTime>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTimer>
#include <QtQml>
#include "store.h"
#include "websocket.h"

class Party : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString relay READ relay WRITE setRelay NOTIFY relayChanged)
    Q_PROPERTY(bool connected READ connected NOTIFY connectedChanged)
    Q_PROPERTY(QVariantList viewers READ viewers NOTIFY viewersChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY viewersChanged)
    Q_PROPERTY(bool waits READ waits WRITE setWaits NOTIFY waitsChanged)
public:
    explicit Party(QObject *parent = nullptr) : QObject(parent) {
        connect(&m_socket, &WebSocket::opened, this, [this] { emit connectedChanged(); say("heartbeat"); });
        connect(&m_socket, &WebSocket::closed, this, [this] { emit connectedChanged(); setViewers({}); m_retry.start(); });
        connect(&m_socket, &WebSocket::text, this, &Party::heard);
        m_retry.setSingleShot(true); m_retry.setInterval(3000);
        connect(&m_retry, &QTimer::timeout, this, &Party::reach);
        m_beat.setInterval(500);
        connect(&m_beat, &QTimer::timeout, this, [this] { if (now() - m_saidAt >= 450) say("heartbeat"); });
    }
    QString relay() const { return m_relay; }
    void setRelay(const QString &relay) { if (relay == m_relay) return; m_relay = relay; emit relayChanged(); reach(); }
    void setRetry(int ms) { m_retry.setInterval(ms); }                  // (a test's)
    bool connected() const { return m_socket.isOpen(); }
    QVariantList viewers() const { return m_viewers; }
    bool loading() const { for (const QVariant &v : m_viewers) if (v.toMap().value("loading").toBool()) return true; return false; }
    bool waits() { return m_store.data().value("waits").toBool(true); }
    void setWaits(bool on) { if (on == waits()) return; m_store.data()["waits"] = on; m_store.save(); emit waitsChanged(); }

    Q_INVOKABLE void playing(const QVariantMap &state) {
        const QString media = state.value("media").toString();
        if (media.isEmpty()) { stopped(); return; }
        const qint64 at = now();
        const double position = state.value("position").toDouble() / 1000, duration = state.value("duration").toDouble() / 1000;
        const bool paused = state.value("paused").toBool(), buffering = state.value("buffering").toBool();
        QString event = "heartbeat";
        if (media != m_media) {                                         // another file: another session, named by when it began
            m_media = media; m_session = QString::number(at, 36); m_sequence = 0;
        } else {
            const bool was = m_state.value("paused").toBool(), held = was || m_state.value("buffering").toBool();
            // where the last word says it is by now: far from that, it was moved
            const double expected = m_state.value("positionSeconds").toDouble() + (held ? 0 : (at - m_sampledAt) / 1000.0);
            if (was != paused) event = paused ? "pause" : "play";
            else if (qAbs(position - expected) > 1.5) event = "seeked";
            else if (buffering != m_state.value("buffering").toBool()) event = buffering ? "waiting" : "playing";
        }
        m_state = QJsonObject { { "sessionId", m_session }, { "positionSeconds", position }, { "paused", paused }, { "buffering", buffering },
                                { "playbackRate", 1 }, { "mediaUrl", media }, { "title", state.value("title").toString() },
                                { "episodeId", state.value("episode").toString() } };
        if (duration > 0) m_state["durationSeconds"] = duration;
        m_sampledAt = at;
        // (the player says where it is several times a second: what happened goes at once, where it is
        // five times a second at most)
        if (event != "heartbeat" || at - m_saidAt >= 200) say(event);
        if (!m_beat.isActive()) m_beat.start();
    }
    Q_INVOKABLE void stopped() {
        if (m_state.isEmpty()) return;
        m_beat.stop();
        tell(QJsonObject { { "type", "idle" }, { "sessionId", m_session }, { "sampledAtMs", double(now()) }, { "sequence", ++m_sequence } });
        m_state = QJsonObject(); m_media.clear();
    }
signals:
    void relayChanged();
    void connectedChanged();
    void viewersChanged();
    void waitsChanged();
private:
    static qint64 now() { return QDateTime::currentMSecsSinceEpoch(); }
    // (the Mac's previews replay recorded answers and reach nothing live)
    void reach() { if (m_relay.isEmpty() || !qEnvironmentVariableIsEmpty("SEIMIO_REPLAY")) m_socket.close(); else m_socket.open(QUrl(m_relay)); }
    void tell(const QJsonObject &message) { m_socket.send(QString::fromUtf8(QJsonDocument(message).toJson(QJsonDocument::Compact))); }
    void say(const QString &event) {
        if (m_state.isEmpty() || !m_socket.isOpen()) return;
        QJsonObject state = m_state;
        state["sequence"] = ++m_sequence; state["sampledAtMs"] = double(m_sampledAt); state["event"] = event;
        tell(QJsonObject { { "type", "state" }, { "state", state } });
        m_saidAt = now();
    }
    void heard(const QString &message) {
        const QJsonObject m = QJsonDocument::fromJson(message.toUtf8()).object();
        const QString type = m.value("type").toString();
        if (type == "clock-ping") tell(QJsonObject { { "type", "clock-pong" }, { "t", m.value("t") }, { "tvMs", double(now()) } });
        else if (type == "room-viewers" || (type == "hello" && m.contains("viewers"))) {
            QVariantList viewers;
            // (`ready` is null for a follower that has not said: one from before it was asked, which nothing waits for)
            for (const QJsonValue &v : m.value("viewers").toArray())
                viewers << QVariantMap { { "id", v.toObject().value("id").toInt() }, { "loading", v.toObject().value("ready").isBool() && !v.toObject().value("ready").toBool() } };
            setViewers(viewers);
        }
    }
    void setViewers(const QVariantList &viewers) { if (viewers == m_viewers) return; m_viewers = viewers; emit viewersChanged(); }
    WebSocket m_socket;
    QTimer m_retry, m_beat;
    QString m_relay, m_media, m_session;
    QJsonObject m_state;                // what was last said to be playing (none: nothing is)
    QVariantList m_viewers;
    JsonStore m_store { "party.json" };
    qint64 m_sampledAt = 0, m_saidAt = 0;
    int m_sequence = 0;
};
