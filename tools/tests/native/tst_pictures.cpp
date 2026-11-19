// The picture loader's rules (native/src/pictures.h), against a server in the test and a disk cache in a
// folder of its own. Run by tools/tests/native/run.sh.
#include <QtTest>
#include <QTemporaryDir>
#include "pictures.h"
#include "service.h"

using namespace pictures;

// a picture of one colour, as a PNG's bytes
static QByteArray png(const QColor &colour, int w = 40, int h = 20) {
    QImage image(w, h, QImage::Format_RGB32); image.fill(colour);
    QByteArray bytes; QBuffer buffer(&bytes); buffer.open(QIODevice::WriteOnly); image.save(&buffer, "PNG");
    return bytes;
}
static const QByteArray kPicture = "Content-Type: image/png\r\n";             // a picture, with no word on how long it keeps
struct Got {
    QImage image; QString error; bool done = false; int times = 0;
    Loader::Done fn() { return [this](const QImage &i, const QString &e) { image = i; error = e; done = true; ++times; }; }
    QColor colour() const { return image.isNull() ? QColor() : image.pixelColor(0, 0); }
};
static Want of(const QStringList &places, const QSize &size = QSize()) { Want w; w.places = places; w.size = size; return w; }

class TestPictures : public QObject {
    Q_OBJECT
private slots:
    void anAddressListsItsPlaces() {
        QCOMPARE(address({ "https://a/x.png" }), QString("https://a/x.png"));          // one place: itself, for Qt's own loader
        QCOMPARE(address({ "", "https://a/x.png", "https://a/x.png" }), QString("https://a/x.png"));
        QCOMPARE(address({}), QString());
        const QString two = address({ "https://own/logo.png?x=1", "https://quick/logo" });
        QVERIFY(two.startsWith("image://art/"));
        Want w = wanted(two.mid(QString("image://art/").size()));
        QCOMPARE(w.places, (QStringList { "https://own/logo.png?x=1", "https://quick/logo" }));
        QVERIFY(!w.banded);
        QVERIFY(wanted("f/" + encoded("https://a/b.jpg")).banded);
        // whose turn comes first: the backdrop's, then a logo's (one side given), then a card's (both)
        w.size = QSize(480, 270); QCOMPARE(w.rank(), 0);
        w.size = QSize(780, 0); QCOMPARE(w.rank(), 1);
        w.banded = true; w.size = QSize(1920, 1080); QCOMPARE(w.rank(), 2);
        QCOMPARE(wanted("https://plain/a.jpg").places, (QStringList { "https://plain/a.jpg" }));
    }
    void aPictureIsDecodedAtTheSizeItIsShownAt() {
        const QByteArray wide = png(Qt::red, 200, 100);
        QCOMPARE(decoded(wide, QSize(), false).size(), QSize(200, 100));
        QCOMPARE(decoded(wide, QSize(100, 0), false).size(), QSize(100, 50));           // by its one side
        QCOMPARE(decoded(wide, QSize(50, 50), false).size(), QSize(100, 50));           // to cover both, as an Image that crops
        QCOMPARE(decoded(wide, QSize(400, 0), false).size(), QSize(400, 200));          // up too, as Qt has it
        QCOMPARE(decoded(wide, QSize(100, 0), false).format(), QImage::Format_RGB32);   // in a format Qt's scene takes as it is
        const QImage banded = decoded(wide, QSize(50, 50), true);
        QCOMPARE(banded.size(), QSize(50, 25));                                         // the backdrop's: inside
        QCOMPARE(banded.format(), QImage::Format_RGBX8888);
        QCOMPARE(decoded(wide, QSize(1920, 1080), true).size(), QSize(200, 100));       // and never up
        QVERIFY(decoded("not a picture", QSize(), false).isNull());
    }
    void onePlaceIsFetched() {
        Service s; QTemporaryDir dir; Loader loader(dir.path());
        s.lines["/own"] = { { 200, png(Qt::red), kPicture, 0 } };
        Got g; loader.request(of({ s.at("/own") }), g.fn());
        QTRY_VERIFY(g.done);
        QCOMPARE(g.colour(), QColor(Qt::red)); QVERIFY(g.error.isEmpty());
    }
    void withNothingOnDiskTheQuickPlaceShowsAndItsOwnComesOnTheSide() {
        Service s; QTemporaryDir dir; Loader loader(dir.path());
        s.lines["/own"] = { { 200, png(Qt::red), kPicture, 300 } };
        s.lines["/quick"] = { { 200, png(Qt::blue), kPicture, 0 } };
        const QStringList places { s.at("/own"), s.at("/quick") };
        QElapsedTimer t; t.start();
        Got first; loader.request(of(places), first.fn());
        QTRY_VERIFY(first.done);
        QCOMPARE(first.colour(), QColor(Qt::blue));     // the quick one, without waiting for its own
        QVERIFY(t.elapsed() < 250);
        QTRY_VERIFY(loader.kept(s.at("/own")));         // which went on arriving
        Got second; loader.request(of(places), second.fn());
        QTRY_VERIFY(second.done);
        QCOMPARE(second.colour(), QColor(Qt::red));     // and is what shows the next time
        QCOMPARE(s.asked["/own"], 1); QCOMPARE(s.asked["/quick"], 1);                   // from disk: nobody was asked again
    }
    void theFirstPlaceOnDiskShows() {
        Service s; QTemporaryDir dir; Loader loader(dir.path());
        s.lines["/own"] = { { -1, "", "", 0 } };        // its own never comes
        s.lines["/quick"] = { { 200, png(Qt::blue), kPicture, 0 } };
        s.lines["/third"] = { { 200, png(Qt::green), kPicture, 0 } };
        Got warm; loader.request(of({ s.at("/third") }), warm.fn());
        QTRY_VERIFY(warm.done);
        Got g; loader.request(of({ s.at("/own"), s.at("/quick"), s.at("/third") }), g.fn());
        QTRY_VERIFY(g.done);
        QCOMPARE(g.colour(), QColor(Qt::green));        // the one already here, before the quick one that would have to be fetched
        QCOMPARE(s.asked["/quick"], 0);
    }
    void aPlaceWithNothingLeavesItToTheNext() {
        Service s; QTemporaryDir dir; Loader loader(dir.path());
        s.lines["/own"] = { { 200, png(Qt::red), kPicture, 120 } };
        Got g; loader.request(of({ s.at("/own"), s.at("/quick") }), g.fn());      // the quick place answers 404
        QTRY_VERIFY(g.done);
        QCOMPARE(g.colour(), QColor(Qt::red));          // its own after all, as long as that takes
        QCOMPARE(s.asked["/own"], 1);                   // the one fetch, which was on the side until then
    }
    void aPlaceThatStallsDoesNotHoldBackItsOwnPictureOnceThatIsIn() {
        Service s; QTemporaryDir dir; Loader loader(dir.path());
        s.lines["/own"] = { { 200, png(Qt::red), kPicture, 150 } };
        s.lines["/quick"] = { { -1, "", "", 0 } };      // never answers (given up on only after 20 s of nothing)
        QElapsedTimer t; t.start();
        Got g; loader.request(of({ s.at("/own"), s.at("/quick") }), g.fn());
        QTRY_VERIFY_WITH_TIMEOUT(g.done, 3000);
        QCOMPARE(g.colour(), QColor(Qt::red));          // its own, which came in on the side meanwhile
        QVERIFY(t.elapsed() < 2000);
    }
    void atItsEndTheLoaderAnswersWhatIsStillAskedFor() {
        Service s; QTemporaryDir dir;
        s.lines["/own"] = { { -1, "", "", 0 } };
        auto *loader = new Loader(dir.path());
        const std::shared_ptr<Door> door = loader->door();
        Got g; loader->request(of({ s.at("/own") }), g.fn());
        QTest::qWait(30);
        loader->drain();
        QVERIFY(g.done); QVERIFY(g.image.isNull()); QCOMPARE(g.times, 1);
        delete loader;
        bool reached = false;
        Loader::with(door, [&reached](Loader *) { reached = true; });      // what a response left behind does: nobody is there
        QVERIFY(!reached);
    }
    void whatIsNoPictureLeavesItToTheNext() {
        Service s; QTemporaryDir dir; Loader loader(dir.path());
        s.lines["/own"] = { { 200, png(Qt::red), kPicture, 60 } };
        s.lines["/quick"] = { { 200, "<html>moved</html>", "Content-Type: text/html\r\n", 0 } };
        Got g; loader.request(of({ s.at("/own"), s.at("/quick") }), g.fn());
        QTRY_VERIFY(g.done);
        QCOMPARE(g.colour(), QColor(Qt::red));
    }
    void whenNoPlaceHasItTheFailureSaysWhy() {
        Service s; QTemporaryDir dir; Loader loader(dir.path());
        Got g; loader.request(of({ s.at("/own"), s.at("/quick") }), g.fn());
        QTRY_VERIFY(g.done);
        QVERIFY(g.image.isNull()); QVERIFY2(g.error.contains("404"), qPrintable(g.error));
        Got none; loader.request(of({}), none.fn());
        QTRY_VERIFY(none.done);
        QVERIFY(none.image.isNull()); QVERIFY(!none.error.isEmpty());
    }
    void twoAskingAtOnceShareTheDownload() {
        Service s; QTemporaryDir dir; Loader loader(dir.path());
        s.lines["/own"] = { { 200, png(Qt::red), kPicture, 80 } };
        Got a, b; loader.request(of({ s.at("/own") }), a.fn()); loader.request(of({ s.at("/own") }, QSize(20, 0)), b.fn());
        QTRY_VERIFY(a.done && b.done);
        QCOMPARE(s.asked["/own"], 1);
        QCOMPARE(a.image.width(), 40); QCOMPARE(b.image.width(), 20);       // each at its own size
    }
    void aLogoDoesNotWaitBehindAScreenOfCards() {
        Service s; QTemporaryDir dir; Loader loader(dir.path());
        const QByteArray big = png(Qt::red, 1600, 900);
        QVector<int> order;
        for (int i = 0; i < 40; i++) {
            s.lines[QString("/card%1").arg(i)] = { { 200, big, kPicture, 0 } };
            loader.request(of({ s.at(QString("/card%1").arg(i)) }, QSize(442, 248)), [&order, i](const QImage &, const QString &) { order << i; });
        }
        s.lines["/logo"] = { { 200, big, kPicture, 0 } };
        loader.request(of({ s.at("/logo") }, QSize(780, 0)), [&order](const QImage &, const QString &) { order << -1; });
        QTRY_COMPARE_WITH_TIMEOUT(order.size(), 41, 20000);
        QVERIFY2(order.indexOf(-1) < 20, qPrintable(QString("the logo, asked for last, came %1th of 41").arg(order.indexOf(-1) + 1)));
    }
    void cancelledItAnswersOnceWithNothing() {
        Service s; QTemporaryDir dir; Loader loader(dir.path());
        s.lines["/own"] = { { 200, png(Qt::red), kPicture, 150 } };
        Got g; const quint64 ticket = loader.request(of({ s.at("/own") }), g.fn());
        QTest::qWait(30);
        loader.cancel(ticket);
        QTRY_VERIFY(g.done);
        QVERIFY(g.image.isNull()); QCOMPARE(g.error, QString("cancelled"));
        QTest::qWait(200);
        QCOMPARE(g.times, 1);                           // the picture arriving later says nothing more
    }
    void aPictureWithNoWordOnKeepingIsStillThereNextRun() {
        Service s; QTemporaryDir dir;
        s.lines["/own"] = { { 200, png(Qt::red), kPicture, 0 } };
        {
            Loader first(dir.path());
            Got g; first.request(of({ s.at("/own") }), g.fn());
            QTRY_VERIFY(g.done);
            QTRY_VERIFY(first.kept(s.at("/own")));
        }
        Loader second(dir.path());
        QVERIFY(second.kept(s.at("/own")));
        Got g; second.request(of({ s.at("/own") }), g.fn());
        QTRY_VERIFY(g.done);
        QCOMPARE(g.colour(), QColor(Qt::red)); QCOMPARE(s.asked["/own"], 1);
    }
    void theOnesOnTheSideAreSixAtOnceAndTwentyFourWaiting() {
        Service s; QTemporaryDir dir; Loader loader(dir.path());
        s.lines["/quick"] = { { 200, png(Qt::blue), kPicture, 0 } };
        QVector<Got> got(40);
        for (int i = 0; i < 40; i++) {
            s.lines[QString("/own%1").arg(i)] = { { 200, png(Qt::red), kPicture, 250 } };
            loader.request(of({ s.at(QString("/own%1").arg(i)), s.at("/quick") }), got[i].fn());
        }
        QTRY_VERIFY(got[39].done);
        int asked = 0; for (int i = 0; i < 40; i++) asked += s.asked[QString("/own%1").arg(i)];
        QCOMPARE(asked, 6);                             // the rest wait their turn
        QVariantMap seen; loader.look([&seen](QVariantMap m) { seen = m; });
        QTRY_VERIFY(!seen.isEmpty());
        QCOMPARE(seen["onTheSide"].toInt(), 6); QCOMPARE(seen["waiting"].toInt(), 24);
        QTRY_COMPARE_WITH_TIMEOUT(s.asked["/own39"], 1, 3000);              // the latest asked for goes first of those
        QCOMPARE(s.asked["/own6"], 0);                  // and the oldest beyond the twenty-four was let go
    }
    void theLabSeesWhereEachPictureCameFrom() {
        Service s; QTemporaryDir dir; Loader loader(dir.path());
        s.lines["/own"] = { { 200, png(Qt::red), kPicture, 0 } };
        Got a; loader.request(of({ s.at("/own") }), a.fn()); QTRY_VERIFY(a.done);
        QTRY_VERIFY(loader.kept(s.at("/own")));
        Got b; loader.request(of({ s.at("/own") }), b.fn()); QTRY_VERIFY(b.done);
        QVariantMap seen; loader.look([&seen](QVariantMap m) { seen = m; });
        QTRY_VERIFY(!seen.isEmpty());
        const QVariantList recent = seen["recent"].toList();
        QCOMPARE(recent.size(), 2);
        QCOMPARE(recent[0].toMap()["how"].toString(), QString("net")); QCOMPARE(recent[1].toMap()["how"].toString(), QString("disk"));
        QCOMPARE(recent[1].toMap()["from"].toString(), QString("127.0.0.1"));
        QCOMPARE(seen["asked"].toInt(), 2); QCOMPARE(seen["shown"].toInt(), 2);
    }
};

QTEST_GUILESS_MAIN(TestPictures)
#include "tst_pictures.moc"
