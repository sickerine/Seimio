#pragma once
// A WebSocket client (RFC 6455), as much of one as the watch party's relay asks for: text messages each
// way, with TLS or without, the server's pings answered. The TV's Qt has no QtWebSockets module.
#include <QObject>
#include <QRandomGenerator>
#include <QSslSocket>
#include <QUrl>
#include <QtEndian>

class WebSocket : public QObject {
    Q_OBJECT
public:
    explicit WebSocket(QObject *parent = nullptr) : QObject(parent) {
        connect(&m_socket, &QAbstractSocket::connected, this, [this] { if (!m_secure) greet(); });
        connect(&m_socket, &QSslSocket::encrypted, this, [this] { greet(); });
        connect(&m_socket, &QIODevice::readyRead, this, [this] { m_in += m_socket.readAll(); read(); });
        // (a connection refused, a name not found and a line cut all end here)
        connect(&m_socket, &QAbstractSocket::stateChanged, this, [this](QAbstractSocket::SocketState s) { if (s == QAbstractSocket::UnconnectedState) down(); });
    }
    // (going, it says nothing: the socket closes as it is destroyed, and whoever hears `closed` then may be
    // half gone itself; a Party's timers were, and it started one)
    ~WebSocket() override { m_socket.disconnect(this); close(); }
    bool isOpen() const { return m_open; }
    // ws://host[:port]/path?query or wss://...
    void open(const QUrl &url) {
        close();
        m_url = url; m_secure = url.scheme() == "wss"; m_wanted = true;
        if (m_secure) m_socket.connectToHostEncrypted(url.host(), quint16(url.port(443)));
        else m_socket.connectToHost(url.host(), quint16(url.port(80)));
    }
    // (says nothing: `closed` is for one that went by itself)
    void close() { m_wanted = false; m_open = false; m_socket.abort(); m_in.clear(); m_message.clear(); }
    void send(const QString &text) { if (m_open) frame(0x1, text.toUtf8()); }
signals:
    void opened();
    void text(const QString &message);
    void closed();              // asked for, and not there: it never opened, or it has gone
private:
    void down() {
        if (!m_wanted) return;
        m_wanted = false; m_open = false; m_in.clear(); m_message.clear();
        emit closed();
    }
    void greet() {
        QByteArray key(16, 0);
        for (char &c : key) c = char(QRandomGenerator::global()->bounded(256));
        QByteArray path = m_url.path(QUrl::FullyEncoded).toUtf8();
        if (path.isEmpty()) path = "/";
        if (m_url.hasQuery()) path += "?" + m_url.query(QUrl::FullyEncoded).toUtf8();
        const int port = m_url.port(-1);
        m_socket.write("GET " + path + " HTTP/1.1\r\nHost: " + m_url.host().toUtf8() + (port > 0 ? ":" + QByteArray::number(port) : QByteArray())
                       + "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: " + key.toBase64()
                       + "\r\nSec-WebSocket-Version: 13\r\nUser-Agent: seimio/0.1\r\n\r\n");
    }
    // one frame out; a client's are masked
    void frame(int opcode, const QByteArray &payload) {
        QByteArray out;
        out.append(char(0x80 | opcode));
        const int n = payload.size();
        if (n < 126) out.append(char(0x80 | n));
        else if (n < 65536) { const quint16 be = qToBigEndian<quint16>(quint16(n)); out.append(char(0x80 | 126)); out.append(reinterpret_cast<const char *>(&be), 2); }
        else { const quint64 be = qToBigEndian<quint64>(quint64(n)); out.append(char(0x80 | 127)); out.append(reinterpret_cast<const char *>(&be), 8); }
        const quint32 mask = QRandomGenerator::global()->generate();
        const char *m = reinterpret_cast<const char *>(&mask);
        out.append(m, 4);
        for (int i = 0; i < n; i++) out.append(char(payload[i] ^ m[i % 4]));
        m_socket.write(out);
    }
    // what has come in: the answer to the greeting, then frames, as many as are whole
    void read() {
        while (m_wanted) {
            if (!m_open) {
                const int end = m_in.indexOf("\r\n\r\n");
                if (end < 0) return;
                const bool taken = m_in.startsWith("HTTP/1.1 101");
                m_in.remove(0, end + 4);
                if (!taken) { m_socket.abort(); return; }
                m_open = true;
                emit opened();
                continue;
            }
            if (m_in.size() < 2) return;
            const uchar *d = reinterpret_cast<const uchar *>(m_in.constData());
            const int opcode = d[0] & 0x0f, masked = d[1] & 0x80 ? 4 : 0;
            const bool last = d[0] & 0x80;
            quint64 size = d[1] & 0x7f;
            int at = 2;
            if (size == 126) { if (m_in.size() < 4) return; size = qFromBigEndian<quint16>(d + 2); at = 4; }
            else if (size == 127) { if (m_in.size() < 10) return; size = qFromBigEndian<quint64>(d + 2); at = 10; }
            if (size > (1u << 22)) { m_socket.abort(); return; }                // (the relay's are a few kilobytes)
            if (quint64(m_in.size()) < at + masked + size) return;
            QByteArray payload = m_in.mid(at + masked, int(size));
            for (int i = 0; masked && i < payload.size(); i++) payload[i] = char(payload[i] ^ m_in[at + i % 4]);
            m_in.remove(0, at + masked + int(size));
            if (opcode == 0x8) { m_socket.abort(); return; }                    // it is closing
            if (opcode == 0x9) frame(0xA, payload);                             // its ping, answered
            else if (opcode == 0x0 || opcode == 0x1) {
                m_message += payload;
                if (last) { const QString said = QString::fromUtf8(m_message); m_message.clear(); emit text(said); }
            }
        }
    }
    QSslSocket m_socket;
    QUrl m_url;
    QByteArray m_in, m_message;
    bool m_secure = false, m_open = false, m_wanted = false;
};
