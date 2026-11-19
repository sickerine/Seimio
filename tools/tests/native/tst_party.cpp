// Party (party.h) against a relay of the test's own: a server that takes the WebSocket greeting, reads
// what the TV says and can say things back, drop the line and send a ping.
#include <QtTest>
#include <QTcpServer>
#include <QTcpSocket>
#include "party.h"
#include "websocket.h"

class Relay : public QObject {
    Q_OBJECT
public:
    QTcpServer server;
    QTcpSocket *line = nullptr;
    QByteArray in, asked;                       // bytes not yet read as frames; the request line of the greeting
    QList<QJsonObject> said;                    // the TV's messages, in order
    QList<QByteArray> pongs;
    int greetings = 0;
    bool greeted = false;                       // this line's greeting has been taken
    Relay() {
        server.listen(QHostAddress::LocalHost);
        connect(&server, &QTcpServer::newConnection, this, [this] {
            line = server.nextPendingConnection(); in.clear(); greeted = false;
            connect(line, &QTcpSocket::readyRead, this, [this] { in += line->readAll(); read(); });
        });
    }
    QString address(const QString &query = "role=tv&room=home&key=k") const { return QString("ws://127.0.0.1:%1/ws?%2").arg(server.serverPort()).arg(query); }
    void read() {
        if (!greeted) {
            const int end = in.indexOf("\r\n\r\n");
            if (end < 0) return;
            asked = in.left(in.indexOf("\r\n")); in.remove(0, end + 4); greetings++; greeted = true;
            line->write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n");
        }
        while (in.size() >= 6) {
            const uchar *d = reinterpret_cast<const uchar *>(in.constData());
            const int opcode = d[0] & 0x0f;
            quint64 size = d[1] & 0x7f; int at = 2;
            if (size == 126) { size = qFromBigEndian<quint16>(d + 2); at = 4; }
            if (!(d[1] & 0x80)) qFatal("a client's frame must be masked");
            if (quint64(in.size()) < at + 4 + size) return;
            QByteArray payload = in.mid(at + 4, int(size));
            for (int i = 0; i < payload.size(); i++) payload[i] = char(payload[i] ^ in[at + i % 4]);
            in.remove(0, at + 4 + int(size));
            if (opcode == 0x1) said << QJsonDocument::fromJson(payload).object(); else if (opcode == 0xA) pongs << payload;
        }
    }
    // a frame from the server (not masked); `pieces` splits a text into that many frames
    void frame(int opcode, const QByteArray &payload, bool last = true) {
        QByteArray out; out.append(char((last ? 0x80 : 0) | opcode));
        if (payload.size() < 126) out.append(char(payload.size()));
        else { const quint16 be = qToBigEndian<quint16>(quint16(payload.size())); out.append(char(126)); out.append(reinterpret_cast<const char *>(&be), 2); }
        line->write(out + payload);
    }
    void tell(const QJsonObject &m) { frame(0x1, QJsonDocument(m).toJson(QJsonDocument::Compact)); }
    QList<QJsonObject> states() const { QList<QJsonObject> out; for (const QJsonObject &m : said) if (m.value("type") == "state") out << m.value("state").toObject(); return out; }
};

class TestParty : public QObject {
    Q_OBJECT
    QVariantMap at(double ms, bool paused = false, const QString &media = "https://cdn.example/a.mkv") {
        return { { "media", media }, { "title", "A" }, { "episode", "tt1:1:1" }, { "position", ms }, { "duration", 1400000.0 }, { "paused", paused }, { "buffering", false } };
    }
private slots:
    void init() { qunsetenv("SEIMIO_REPLAY"); }
    // The relay is reached at its address, as a TV, and learns the TV's clock from its answers.
    void reachesTheRelayAndAnswersItsClock() {
        Relay relay; Party party;
        party.setRelay(relay.address());
        QTRY_VERIFY(party.connected());
        QCOMPARE(relay.asked, QByteArray("GET /ws?role=tv&room=home&key=k HTTP/1.1"));
        relay.tell({ { "type", "clock-ping" }, { "t", 1234.0 } });
        QTRY_COMPARE(relay.said.size(), 1);
        QCOMPARE(relay.said[0].value("type").toString(), QString("clock-pong"));
        QCOMPARE(relay.said[0].value("t").toDouble(), 1234.0);
        QVERIFY(qAbs(relay.said[0].value("tvMs").toDouble() - QDateTime::currentMSecsSinceEpoch()) < 2000);
        relay.frame(0x9, "are you there");
        QTRY_COMPARE(relay.pongs.size(), 1);
        QCOMPARE(relay.pongs[0], QByteArray("are you there"));
    }
    // Who is in the room, and who is still loading: from the greeting and from each word after. One who
    // has not said either way is there and is not waited for.
    void knowsTheRoom() {
        Relay relay; Party party;
        party.setRelay(relay.address());
        QTRY_VERIFY(party.connected());
        QSignalSpy changed(&party, &Party::viewersChanged);
        relay.tell({ { "type", "hello" }, { "viewers", QJsonArray { QJsonObject { { "id", 1 }, { "ready", QJsonValue() } } } } });
        QTRY_COMPARE(party.viewers().size(), 1);
        QVERIFY(!party.loading());
        // (a long one, in two frames)
        QJsonArray many; for (int i = 1; i <= 9; i++) many << QJsonObject { { "id", i }, { "ready", i != 4 } };
        const QByteArray text = QJsonDocument(QJsonObject { { "type", "room-viewers" }, { "viewers", many } }).toJson(QJsonDocument::Compact);
        QVERIFY(text.size() > 126);
        relay.frame(0x1, text.left(100), false); relay.frame(0x0, text.mid(100));
        QTRY_COMPARE(party.viewers().size(), 9);
        QVERIFY(party.loading());
        QCOMPARE(party.viewers()[3].toMap().value("loading").toBool(), true);
        QCOMPARE(party.viewers()[4].toMap().value("loading").toBool(), false);
        relay.tell({ { "type", "room-viewers" }, { "viewers", QJsonArray() } });
        QTRY_COMPARE(party.viewers().size(), 0);
        QVERIFY(!party.loading());
    }
    // What plays is said as it changes, with what happened, and twice a second while nothing does.
    void saysWhatPlays() {
        Relay relay; Party party;
        party.setRelay(relay.address());
        QTRY_VERIFY(party.connected());
        party.playing(at(60000, true));                                 // loaded, held at a minute in
        QTRY_COMPARE(relay.states().size(), 1);
        QJsonObject s = relay.states()[0];
        QCOMPARE(s.value("positionSeconds").toDouble(), 60.0);
        QCOMPARE(s.value("paused").toBool(), true);
        QCOMPARE(s.value("mediaUrl").toString(), QString("https://cdn.example/a.mkv"));
        QCOMPARE(s.value("durationSeconds").toDouble(), 1400.0);
        QCOMPARE(s.value("sequence").toInt(), 1);
        QVERIFY(qAbs(s.value("sampledAtMs").toDouble() - QDateTime::currentMSecsSinceEpoch()) < 2000);
        const QString session = s.value("sessionId").toString();
        QVERIFY(!session.isEmpty());

        party.playing(at(60000));                                       // released
        QTRY_COMPARE(relay.states().size(), 2);
        QCOMPARE(relay.states()[1].value("event").toString(), QString("play"));
        QTest::qWait(250);
        party.playing(at(60250));                                       // going along
        QTRY_COMPARE(relay.states().size(), 3);
        QCOMPARE(relay.states()[2].value("event").toString(), QString("heartbeat"));
        party.playing(at(60260));                                       // (said again at once: kept for the next word)
        QTest::qWait(50);
        QCOMPARE(relay.states().size(), 3);
        party.playing(at(300000));                                      // moved
        QTRY_COMPARE(relay.states().size(), 4);
        QCOMPARE(relay.states()[3].value("event").toString(), QString("seeked"));
        party.playing(at(300000, true));
        QTRY_COMPARE(relay.states().size(), 5);
        QCOMPARE(relay.states()[4].value("event").toString(), QString("pause"));
        QCOMPARE(relay.states()[4].value("sessionId").toString(), session);
        for (int i = 1; i < 5; i++) QVERIFY(relay.states()[i].value("sequence").toInt() > relay.states()[i - 1].value("sequence").toInt());

        // nothing more said: it goes on saying where it is, so the relay knows the TV is there
        QTRY_VERIFY_WITH_TIMEOUT(relay.states().size() >= 7, 2000);
        QCOMPARE(relay.states().last().value("positionSeconds").toDouble(), 300.0);

        party.playing(at(0, false, "https://cdn.example/b.mkv"));       // another file
        QTRY_VERIFY(relay.states().last().value("mediaUrl").toString().endsWith("b.mkv"));
        QVERIFY(relay.states().last().value("sessionId").toString() != session);
        QCOMPARE(relay.states().last().value("sequence").toInt(), 1);

        const int before = relay.said.size();
        party.stopped();
        QTRY_COMPARE(relay.said.size(), before + 1);
        QCOMPARE(relay.said.last().value("type").toString(), QString("idle"));
        QCOMPARE(relay.said.last().value("sessionId").toString(), relay.states().last().value("sessionId").toString());
        QTest::qWait(700);
        QCOMPARE(relay.said.size(), before + 1);                        // and is quiet after
    }
    // A relay that goes is reached again, and told what is playing; the room is empty meanwhile.
    void comesBackAfterTheLineDrops() {
        Relay relay; Party party;
        party.setRetry(100);
        party.setRelay(relay.address());
        QTRY_VERIFY(party.connected());
        relay.tell({ { "type", "room-viewers" }, { "viewers", QJsonArray { QJsonObject { { "id", 1 }, { "ready", false } } } } });
        QTRY_VERIFY(party.loading());
        party.playing(at(5000));
        QTRY_COMPARE(relay.states().size(), 1);
        relay.line->abort();
        QTRY_VERIFY(!party.connected());
        QCOMPARE(party.viewers().size(), 0);
        QTRY_VERIFY(party.connected());
        QCOMPARE(relay.greetings, 2);
        QTRY_VERIFY(relay.states().size() >= 2);
        QCOMPARE(relay.states().last().value("positionSeconds").toDouble(), 5.0);
    }
    // With no relay there is no party, and the Mac's previews reach nothing.
    void reachesNothingWithoutAnAddressOrInAPreview() {
        Relay relay; Party party;
        party.playing(at(1000));
        QTest::qWait(100);
        QVERIFY(!party.connected());
        qputenv("SEIMIO_REPLAY", "/somewhere");
        party.setRelay(relay.address());
        QTest::qWait(200);
        QVERIFY(!party.connected());
        QCOMPARE(relay.greetings, 0);
    }
};
QTEST_GUILESS_MAIN(TestParty)
#include "tst_party.moc"
