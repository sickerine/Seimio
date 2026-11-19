// A query watched from another thread than its cache's (native/src/watch.h). Run by tools/tests/native/run.sh.
#include <QtTest>
#include "watch.h"

using namespace query;

// a cache on a thread of its own, as the app's data thread has one
struct Far {
    QThread thread;
    Queries *cache = new Queries;
    Far() { cache->moveToThread(&thread); thread.start(); }
    ~Far() { thread.quit(); thread.wait(); delete cache; }
};
static Options quick() { Options o; o.retries = 0; o.keepMs = 60000; return o; }
// answers at once with `value`, on the cache's thread; counts the times it was asked
static Fetch<int> gives(int value, std::atomic<int> *asked = nullptr) { return [value, asked](Call<int> call) { if (asked) ++*asked; call.ok(value); }; }
// answers `value` after `ms`
static Fetch<int> givesLater(int value, int ms) {
    return [value, ms](Call<int> call) { QTimer::singleShot(ms, QCoreApplication::instance(), [call, value] { call.ok(value); }); };
}
struct Told {
    QVector<Result<int>> results; QVector<QThread *> on;
    std::function<void(const Result<int> &)> fn() { return [this](const Result<int> &r) { results << r; on << QThread::currentThread(); }; }
    int value() const { return results.isEmpty() || !results.last().data ? -1 : *results.last().data; }
};

class TestWatch : public QObject {
    Q_OBJECT
private slots:
    void theHolderHearsOnItsOwnThread() {
        Far far; Told t; QObject holder;
        Watch<int> w(far.cache, &holder, t.fn());
        std::atomic<QThread *> fetchedOn { nullptr };
        w.watch({ "k" }, [&fetchedOn](Call<int> call) { fetchedOn = QThread::currentThread(); call.ok(5); }, quick());
        QVERIFY(t.results.isEmpty());                   // nothing from inside the call
        QTRY_COMPARE(t.value(), 5);
        QCOMPARE(fetchedOn.load(), &far.thread);        // fetched over there
        for (QThread *on : t.on) QCOMPARE(on, QThread::currentThread());
    }
    void anAnswerOnItsWayForWhatItNoLongerWatchesIsDropped() {
        Far far; Told t; QObject holder;
        Watch<int> w(far.cache, &holder, t.fn());
        w.watch({ "search", "na" }, gives(10), quick());
        QThread::msleep(60);                            // the answer is across by now, waiting for this thread's turn
        w.watch({ "search", "naruto" }, givesLater(20, 30), quick());
        QTRY_COMPARE(t.value(), 20);
        for (const Result<int> &r : t.results) QVERIFY(!r.data || *r.data == 20);       // never the first key's
    }
    // (Home is asked for twice at launch, as the account's core says it is ready more than once: the
    // first answer crossed under the first asking's number and was dropped, and the second asking, with
    // nothing changed over there, was never answered. Home stayed empty.)
    void askedAgainForTheSameKeyItStillHears() {
        Far far; Told t; QObject holder;
        Watch<int> w(far.cache, &holder, t.fn());
        Options kept = quick(); kept.freshMs = 60000;
        w.watch({ "home" }, gives(7), kept);
        QThread::msleep(60);                            // the answer is across, waiting for this thread's turn
        w.watch({ "home" }, gives(8), kept);            // the same key again, still fresh over there
        QTRY_COMPARE(t.value(), 7);
    }
    void stoppedItHearsNothingMore() {
        Far far; Told t; QObject holder;
        Watch<int> w(far.cache, &holder, t.fn());
        w.watch({ "k" }, gives(1), quick());
        QThread::msleep(60);
        w.stop();
        QTest::qWait(60);
        QVERIFY(t.results.isEmpty());
    }
    void goneItHearsNothingMore() {
        Far far; Told t; QObject holder;
        {
            Watch<int> w(far.cache, &holder, t.fn());
            w.watch({ "k" }, gives(1), quick());
            QThread::msleep(60);
        }
        QTest::qWait(60);
        QVERIFY(t.results.isEmpty());
    }
    void theHolderMayGoFirst() {
        Far far; Told t;
        auto *holder = new QObject;
        Watch<int> w(far.cache, holder, t.fn());
        w.watch({ "k" }, givesLater(1, 30), quick());
        delete holder;
        QTest::qWait(80);
        QVERIFY(t.results.isEmpty());
    }
    void theCacheMayGoFirst() {
        Told t; QObject holder;
        auto *far = new Far;
        Watch<int> w(far->cache, &holder, t.fn());
        w.watch({ "k" }, [](Call<int>) {}, quick());      // a fetch still under way when the cache goes
        QTest::qWait(30);
        delete far;
        w.watch({ "j" }, gives(2), quick());            // asks into nothing
        QTest::qWait(30);
    }
    void twoWatchesOfAKeyShareItsFetch() {
        Far far; Told a, b; QObject holder; std::atomic<int> asked { 0 };
        Watch<int> first(far.cache, &holder, a.fn()), second(far.cache, &holder, b.fn());
        Options kept = quick(); kept.freshMs = 60000;
        first.watch({ "k" }, gives(3, &asked), kept);
        QTRY_COMPARE(a.value(), 3);
        second.watch({ "k" }, gives(4, &asked), kept);
        QTRY_COMPARE(b.value(), 3);                     // the first one's answer, still fresh
        QCOMPARE(asked.load(), 1);
    }
    void whatItShowedStaysUntilTheNewKeyHasItsOwn() {
        Far far; Told t; QObject holder;
        Watch<int> w(far.cache, &holder, t.fn());
        w.watch({ "page", "1" }, gives(1), quick(), true);
        QTRY_COMPARE(t.value(), 1);
        w.watch({ "page", "2" }, givesLater(2, 60), quick(), true);
        QTRY_VERIFY(t.results.last().placeholder);
        QCOMPARE(t.value(), 1);
        QTRY_COMPARE(t.value(), 2);
        QVERIFY(!t.results.last().placeholder);
    }
    void fetchingAgainTellsOfTheNewAnswer() {
        Far far; Told t; QObject holder; std::atomic<int> asked { 0 };
        Watch<int> w(far.cache, &holder, t.fn());
        const Fetch<int> counts = [&asked](Call<int> call) { call.ok(++asked); };
        w.watch({ "k" }, counts, quick());
        QTRY_COMPARE(t.value(), 1);
        w.refetch();
        QTRY_COMPARE(t.value(), 2);
    }
};

QTEST_GUILESS_MAIN(TestWatch)
#include "tst_watch.moc"
