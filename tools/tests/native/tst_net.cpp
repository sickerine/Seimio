// What Net does with a service's answers (native/src/net.h), against a server in the test that answers
// as it is told. Run by tools/tests/native/run.sh.
#include <QtTest>
#include "net.h"
#include "service.h"

struct Got { QByteArray body; bool ok = false; int status = -1; bool done = false; };
static Net::Done into(Got &g) { return [&g](const QByteArray &b, bool ok, int status) { g.body = b; g.ok = ok; g.status = status; g.done = true; }; }

class TestNet : public QObject {
    Q_OBJECT
private slots:
    void anAnswerComesWithItsStatus() {
        Service s; query::Queries cache; Net net(&cache);
        s.lines["/a"] = { { 200, "hello", "", 0 } };
        Got g; net.request(s.at("/a"), QByteArray(), into(g));
        QTRY_VERIFY(g.done);
        QVERIFY(g.ok); QCOMPARE(g.status, 200); QCOMPARE(g.body, QByteArray("hello"));
        QCOMPARE(s.methods, QStringList { "GET" });
    }
    void aBodyMakesItAPost() {
        Service s; query::Queries cache; Net net(&cache);
        s.lines["/q"] = { { 200, "{}", "", 0 } };
        Got g; net.request(s.at("/q"), "{\"query\":1}", into(g));
        QTRY_VERIFY(g.done);
        QCOMPARE(s.methods, QStringList { "POST" });
    }
    void theSameAddressAskedTwiceAtOnceIsFetchedOnce() {
        Service s; query::Queries cache; Net net(&cache);
        s.lines["/a"] = { { 200, "one", "", 30 } };
        Got a, b; net.request(s.at("/a"), QByteArray(), into(a)); net.request(s.at("/a"), QByteArray(), into(b));
        QTRY_VERIFY(a.done && b.done);
        QCOMPARE(s.asked["/a"], 1);
        QCOMPARE(a.body, QByteArray("one")); QCOMPARE(b.body, QByteArray("one"));
        // two bodies to the same address are two questions
        s.lines["/q"] = { { 200, "x", "", 0 } };
        Got c, d; net.request(s.at("/q"), "1", into(c)); net.request(s.at("/q"), "2", into(d));
        QTRY_VERIFY(c.done && d.done);
        QCOMPARE(s.asked["/q"], 2);
    }
    void anAnswerIsKeptForAsLongAsAsked() {
        Service s; query::Queries cache; Net net(&cache);
        s.lines["/a"] = { { 200, "one", "", 0 }, { 200, "two", "", 0 } };
        Got a; net.request(s.at("/a"), QByteArray(), into(a), 60000);
        QTRY_VERIFY(a.done);
        Got b; net.request(s.at("/a"), QByteArray(), into(b), 60000);
        QTRY_VERIFY(b.done);
        QCOMPARE(b.body, QByteArray("one")); QCOMPARE(s.asked["/a"], 1);
        // and not at all otherwise
        s.lines["/b"] = { { 200, "one", "", 0 }, { 200, "two", "", 0 } };
        Got c; net.request(s.at("/b"), QByteArray(), into(c)); QTRY_VERIFY(c.done);
        Got d; net.request(s.at("/b"), QByteArray(), into(d)); QTRY_VERIFY(d.done);
        QCOMPARE(d.body, QByteArray("two"));
        QTRY_COMPARE(cache.size(), 1);                  // only the kept one is still held
    }
    void aServiceInTroubleIsAskedAgain() {
        Service s; query::Queries cache; Net net(&cache);
        s.lines["/a"] = { { 503, "busy", "", 0 }, { 200, "fine", "", 0 } };
        QElapsedTimer t; t.start();
        Got g; net.request(s.at("/a"), QByteArray(), into(g));
        QTRY_VERIFY_WITH_TIMEOUT(g.done, 4000);
        QVERIFY(g.ok); QCOMPARE(g.body, QByteArray("fine")); QCOMPARE(s.asked["/a"], 2);
        QVERIFY(t.elapsed() >= 900);                    // a second later
    }
    void aNoIsAnAnswer() {
        Service s; query::Queries cache; Net net(&cache);
        s.lines["/gone"] = { { 404, "{\"error\":\"none\"}", "", 0 } };
        Got g; net.request(s.at("/gone"), QByteArray(), into(g));
        QTRY_VERIFY(g.done);
        QVERIFY(!g.ok); QCOMPARE(g.status, 404); QCOMPARE(g.body, QByteArray("{\"error\":\"none\"}"));
        QCOMPARE(s.asked["/gone"], 1);                  // not asked again
    }
    void aNoSaysWhy() {
        Service s; query::Queries cache; Net net(&cache);
        std::shared_ptr<const Answer> got; bool done = false;
        net.read(s.at("/gone"), QByteArray(), query::Options(), [&](std::shared_ptr<const Answer> a, const query::Failure &) { got = a; done = true; });
        QTRY_VERIFY(done);
        QVERIFY(got); QCOMPARE(got->status, 404);
        QVERIFY(!got->error.isEmpty());                 // Qt's words for it, for a screen that says what went wrong
    }
    void aRequestCarriesItsNetsHeadersAndItsOwnOverThem() {
        Service s; Net net;
        net.headers = { { "Accept", "application/vnd.api+json" }, { "X-Every", "1" } };
        s.lines["/form"] = { { 200, "ok", "", 0 } };
        Got g; net.send(s.at("/form"), "a=b", into(g), false, { { "Content-Type", "application/x-www-form-urlencoded" }, { "X-Every", "2" } });
        QTRY_VERIFY(g.done);
        const QByteArray head = s.heads.value(0).toLower();
        QVERIFY(head.contains("accept: application/vnd.api+json"));
        QVERIFY(head.contains("content-type: application/x-www-form-urlencoded"));     // over the JSON a body is sent as otherwise
        QVERIFY(head.contains("x-every: 2") && !head.contains("x-every: 1"));
    }
    void tooManyRequestsWaitsAsLongAsTheServiceSays() {
        Service s; query::Queries cache; Net net(&cache);
        s.lines["/a"] = { { 429, "", "Retry-After: 1\r\n", 0 }, { 200, "fine", "", 0 } };
        QElapsedTimer t; t.start();
        Got g; net.request(s.at("/a"), QByteArray(), into(g));
        QTRY_VERIFY_WITH_TIMEOUT(g.done, 4000);
        QVERIFY(g.ok); QCOMPARE(s.asked["/a"], 2);
        QVERIFY(t.elapsed() >= 950 && t.elapsed() < 2500);
    }
    // (A connection the machine refuses is not this case: Qt 5.15 on the Mac never reports one, and
    // Net's own 20 s are what end it.)
    void aServiceThatHangsUpIsAskedAgainThenFailsWithNoStatus() {
        Service s; query::Queries cache; Net net(&cache);
        s.lines["/a"] = { { 0, "", "", 0 } };
        Got g; net.request(s.at("/a"), QByteArray(), into(g));
        QTRY_VERIFY_WITH_TIMEOUT(g.done, 8000);         // after its two tries again, 1 s and 2 s on
        QVERIFY(!g.ok); QCOMPARE(g.status, 0); QVERIFY(g.body.isEmpty());
        QCOMPARE(cache.counts().retries, 2);
    }
    void nothingArrivingIsGivenUpOnAndNotTriedAgain() {
        Service s; query::Queries cache; Net net(&cache);
        net.idleMs = 150;
        s.lines["/silent"] = { { -1, "", "", 0 } };
        QElapsedTimer t; t.start();
        Got g; net.request(s.at("/silent"), QByteArray(), into(g));
        QTRY_VERIFY_WITH_TIMEOUT(g.done, 2000);
        QVERIFY(!g.ok); QCOMPARE(g.status, 0);
        QVERIFY(t.elapsed() < 1000);                    // once, not three times over
        QCOMPARE(s.asked["/silent"], 1);
    }
    void aSlowAnswerThatKeepsComingIsLetCome() {
        Service s; query::Queries cache; Net net(&cache);
        net.idleMs = 150;
        s.lines["/slow"] = { { 200, "0123456789", "Drip", 0 } };       // 400 ms in all, never 150 ms without a byte
        Got g; net.request(s.at("/slow"), QByteArray(), into(g));
        QTRY_VERIFY_WITH_TIMEOUT(g.done, 3000);
        QVERIFY(g.ok); QCOMPARE(g.body, QByteArray("0123456789"));
    }
    void existsSaysNoOnlyForA404() {
        Service s; query::Queries cache; Net net(&cache);
        s.lines["/there"] = { { 200, "", "", 0 } }; s.lines["/broken"] = { { 500, "", "", 0 } };
        bool there = false, gone = true, broken = false; int done = 0;
        net.exists(s.at("/there"), [&](bool e) { there = e; ++done; });
        net.exists(s.at("/gone"), [&](bool e) { gone = e; ++done; });
        net.exists(s.at("/broken"), [&](bool e) { broken = e; ++done; });
        QTRY_COMPARE(done, 3);
        QVERIFY(there); QVERIFY(!gone); QVERIFY(broken);
        QCOMPARE(s.methods.count("HEAD"), 3);
        net.exists(s.at("/gone"), [&](bool) { ++done; });           // kept: not asked a second time
        QTRY_COMPARE(done, 4);
        QCOMPARE(s.asked["/gone"], 1);
    }
    void sendGoesOutOnceWithNothingKeptOrTriedAgain() {
        Service s; Net net;                             // (no cache: the core's own requests)
        s.lines["/write"] = { { 503, "busy", "", 0 }, { 200, "fine", "", 0 } };
        Got a, b; net.send(s.at("/write"), "x", into(a)); net.send(s.at("/write"), "x", into(b));
        QTRY_VERIFY(a.done && b.done);
        QCOMPARE(s.asked["/write"], 2);                 // each asked for itself, the failure as it came
        QVERIFY(a.status == 503 || b.status == 503);
    }
};

QTEST_GUILESS_MAIN(TestNet)
#include "tst_net.moc"
