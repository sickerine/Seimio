#pragma once
// A server for the tests, which answers as it is told. Each path gets the next of the answers lined up
// for it (the last one stays): a status, a body, headers, and how long it takes over it. A status of 0
// hangs up without a word, one under 0 never answers, and headers starting with "Drip" send the body a
// byte every 40 ms.
#include <QTcpServer>
#include <QTcpSocket>
#include <QTimer>
#include <memory>

struct Service : QTcpServer {
    struct Line { int status; QByteArray body; QByteArray headers; int afterMs; };
    QHash<QString, QVector<Line>> lines;
    QHash<QString, int> asked;
    QStringList methods;
    QList<QByteArray> heads;                // each request as it came: its first line and its headers
    Service() {
        listen(QHostAddress::LocalHost);
        connect(this, &QTcpServer::newConnection, this, [this] {
            while (QTcpSocket *s = nextPendingConnection()) {
                connect(s, &QTcpSocket::readyRead, this, [this, s] {
                    if (s->property("answered").toBool() || !s->peek(65536).contains("\r\n\r\n")) return;
                    s->setProperty("answered", true);
                    const QByteArray asking = s->readAll();
                    heads << asking.left(asking.indexOf("\r\n\r\n"));
                    const QList<QByteArray> first = asking.split('\r').first().split(' ');
                    const QString path = QString::fromLatin1(first.value(1));
                    methods << QString::fromLatin1(first.value(0));
                    const int n = asked[path]++;
                    const QVector<Line> &l = lines[path];
                    const Line line = l.isEmpty() ? Line { 404, "nothing", "", 0 } : l[qMin(n, l.size() - 1)];
                    QTimer::singleShot(line.afterMs, s, [s, line] {
                        if (line.status == 0) { s->abort(); return; }               // hangs up without a word
                        if (line.status < 0) return;                                // never answers
                        if (line.headers.startsWith("Drip")) {                      // the body a byte every 40 ms
                            s->write("HTTP/1.1 200 X\r\nContent-Length: " + QByteArray::number(line.body.size()) + "\r\nConnection: close\r\n\r\n");
                            auto at = std::make_shared<int>(0);
                            auto *drip = new QTimer(s);
                            QObject::connect(drip, &QTimer::timeout, s, [s, line, at, drip] {
                                s->write(line.body.mid((*at)++, 1)); s->flush();
                                if (*at >= line.body.size()) { drip->stop(); s->disconnectFromHost(); }
                            });
                            drip->start(40);
                            return;
                        }
                        s->write("HTTP/1.1 " + QByteArray::number(line.status) + " X\r\nContent-Length: " + QByteArray::number(line.body.size()) + "\r\nConnection: close\r\n" + line.headers + "\r\n" + line.body);
                        s->disconnectFromHost();
                    });
                });
                connect(s, &QTcpSocket::disconnected, s, &QObject::deleteLater);
            }
        });
    }
    QString at(const QString &path) const { return "http://127.0.0.1:" + QString::number(serverPort()) + path; }
};
