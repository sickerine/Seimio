// The rules of native/src/query.h, one test each. Run by tools/tests/native/run.sh.
#include <QtTest>
#include "query.h"

using namespace query;

// A service the tests answer by hand: every fetch is kept until the test says what it gets. (Declared
// before the cache in a test, to outlive it: a cache that goes tells its fetches under way to stop.)
struct Source {
    QVector<Call<int>> asked;
    QVector<int> cancelled;                 // the fetches told to stop, by their place in `asked`
    Fetch<int> fn() {
        return [this](Call<int> call) {
            const int n = asked.size();
            call.onCancel([this, n] { cancelled << n; });
            asked << call;
        };
    }
};
static Options quick(qint64 freshMs = 0, qint64 keepMs = 60000) {
    Options o; o.freshMs = freshMs; o.keepMs = keepMs; o.retries = 0;
    return o;
}
// what an observer was told, in order
struct Told {
    QVector<Result<int>> results;
    std::function<void(const Result<int> &)> fn() { return [this](const Result<int> &r) { results << r; }; }
    const Result<int> &last() const { return results.last(); }
    int value() const { return results.isEmpty() || !results.last().data ? -1 : *results.last().data; }
};
static void turn() { QCoreApplication::processEvents(); QCoreApplication::processEvents(); }

class TestQuery : public QObject {
    Q_OBJECT
private slots:
    void oneEntryAKey() {
        Source s; Queries cache; Told a, b;
        Observer<int> first(&cache, a.fn()), second(&cache, b.fn());
        first.watch({ "title", "1" }, s.fn(), quick());
        second.watch({ "title", "1" }, s.fn(), quick());
        turn();
        QCOMPARE(s.asked.size(), 1);                    // the second joined the first's fetch
        QCOMPARE(cache.counts().joined, 1);
        s.asked[0].ok(7); turn();
        QCOMPARE(a.value(), 7); QCOMPARE(b.value(), 7);
        QVERIFY(a.last().data == b.last().data);        // the same data, not a copy each
    }
    void statusAndFetchingAreApart() {
        Source s; Queries cache; Told t;
        Observer<int> o(&cache, t.fn());
        o.watch({ "k" }, s.fn(), quick());
        turn();
        QCOMPARE(t.last().status, Pending); QVERIFY(t.last().fetching); QVERIFY(!t.last().data);
        s.asked[0].ok(1); turn();
        QCOMPARE(t.last().status, Success); QVERIFY(!t.last().fetching);
        o.refetch(); turn();
        QCOMPARE(t.last().status, Success); QVERIFY(t.last().fetching);     // fetched again, the data still shown
        QCOMPARE(t.value(), 1);
        s.asked[1].ok(2); turn();
        QCOMPARE(t.value(), 2); QVERIFY(!t.last().fetching);
    }
    void aFetchUnderWayIsJoined() {
        Source s; Queries cache; QVector<int> got;
        auto then = [&got](std::shared_ptr<const int> d, const Failure &) { got << (d ? *d : -1); };
        cache.fetch<int>({ "k" }, s.fn(), quick(), then);
        cache.fetch<int>({ "k" }, s.fn(), quick(), then);
        turn();
        QCOMPARE(s.asked.size(), 1);
        QVERIFY(got.isEmpty());
        s.asked[0].ok(5); turn();
        QCOMPARE(got, (QVector<int> { 5, 5 }));
    }
    void freshDataIsNotAskedForAgain() {
        Source s; Queries cache; QVector<int> got;
        auto then = [&got](std::shared_ptr<const int> d, const Failure &) { got << (d ? *d : -1); };
        cache.fetch<int>({ "k" }, s.fn(), quick(80), then); turn();
        s.asked[0].ok(5); turn();
        cache.fetch<int>({ "k" }, s.fn(), quick(80), then); turn();
        QCOMPARE(s.asked.size(), 1);                    // still fresh: answered from the cache
        QCOMPARE(got, (QVector<int> { 5, 5 }));
        QTest::qWait(100);
        cache.fetch<int>({ "k" }, s.fn(), quick(80), then); turn();
        QCOMPARE(s.asked.size(), 2);                    // no longer fresh: asked again, and that answer is waited for
        QCOMPARE(got.size(), 2);
        s.asked[1].ok(6); turn();
        QCOMPARE(got, (QVector<int> { 5, 5, 6 }));
    }
    void anAnswerNeverComesInsideTheCall() {
        Queries cache; Told t; bool then = false;
        const Fetch<int> atOnce = [](Call<int> call) { call.ok(3); };       // a source that answers inside the fetch
        Observer<int> o(&cache, t.fn());
        o.watch({ "k" }, atOnce, quick());
        cache.fetch<int>({ "j" }, atOnce, quick(), [&then](std::shared_ptr<const int>, const Failure &) { then = true; });
        QVERIFY(t.results.isEmpty()); QVERIFY(!then);
        turn();
        QCOMPARE(t.results.size(), 1);                  // told once, of the state it ended in
        QCOMPARE(t.value(), 3); QVERIFY(!t.last().fetching);
        QVERIFY(then);
    }
    void anEntryNobodyUsesGoesAfterItsTime() {
        Source s; Queries cache;
        {
            Told t; Observer<int> o(&cache, t.fn());
            o.watch({ "k" }, s.fn(), quick(0, 60)); turn();
            s.asked[0].ok(1); turn();
        }
        QCOMPARE(cache.size(), 1);
        QTest::qWait(30);
        { Told t; Observer<int> o(&cache, t.fn()); o.watch({ "k" }, s.fn(), quick(0, 60)); turn(); QCOMPARE(t.value(), 1); s.asked[1].ok(2); turn(); }
        QTest::qWait(40);
        QCOMPARE(cache.size(), 1);                      // taken up in between: the first leaving's time doesn't count
        QTRY_COMPARE_WITH_TIMEOUT(cache.size(), 0, 500);
    }
    void aFailureIsTriedAgainBeforeItShows() {
        Source s; Queries cache; Told t;
        Options o = quick(); o.retries = 2; o.retryDelay = [](int, const Failure &) { return 10; };
        Observer<int> obs(&cache, t.fn());
        obs.watch({ "k" }, s.fn(), o); turn();
        s.asked[0].fail({ 503, "busy" }); turn();
        QCOMPARE(t.last().status, Pending); QVERIFY(t.last().fetching); QCOMPARE(t.last().failures, 1);
        QTRY_COMPARE(s.asked.size(), 2);
        QCOMPARE(s.asked[1].attempt(), 2);
        s.asked[1].fail({ 503, "busy" });
        QTRY_COMPARE(s.asked.size(), 3);
        s.asked[2].ok(9); turn();
        QCOMPARE(t.last().status, Success); QCOMPARE(t.value(), 9); QCOMPARE(t.last().failures, 0);
        QCOMPARE(cache.counts().retries, 2);
    }
    void theFailureShowsWhenTheTriesAreUsedUp() {
        Source s; Queries cache; Told t;
        Options o = quick(); o.retries = 1; o.retryDelay = [](int, const Failure &) { return 5; };
        Observer<int> obs(&cache, t.fn());
        obs.watch({ "k" }, s.fn(), o); turn();
        s.asked[0].fail({ 500, "down" });
        QTRY_COMPARE(s.asked.size(), 2);
        s.asked[1].fail({ 500, "still down" }); turn();
        QCOMPARE(t.last().status, Error); QVERIFY(!t.last().fetching);
        QCOMPARE(t.last().error.status, 500); QCOMPARE(t.last().error.reason, QString("still down"));
        QCOMPARE(s.asked.size(), 2);
    }
    void aFailureThatWontGoAwayIsNotTriedAgain() {
        Source s; Queries cache; Told t;
        Options o = quick(); o.retries = 3; o.retryDelay = [](int, const Failure &f) { return f.status == 404 ? -1 : 5; };
        Observer<int> obs(&cache, t.fn());
        obs.watch({ "k" }, s.fn(), o); turn();
        s.asked[0].fail({ 404, "nothing there" }); turn();
        QCOMPARE(t.last().status, Error);
        QTest::qWait(30);
        QCOMPARE(s.asked.size(), 1);
    }
    void theDefaultWaitDoublesFromASecondToThirty() {
        QCOMPARE(backoff(1, {}), 1000); QCOMPARE(backoff(2, {}), 2000); QCOMPARE(backoff(3, {}), 4000);
        QCOMPARE(backoff(6, {}), 30000); QCOMPARE(backoff(40, {}), 30000);
        Failure asked; asked.status = 429; asked.waitMs = 20000;
        QCOMPARE(backoff(1, asked), 20000);             // the wait the service asked for
        Failure gone; gone.status = 404; gone.final = true;
        QCOMPARE(backoff(1, gone), -1);                 // nothing to try again for
    }
    void aFinalFailureShowsAtOnce() {
        Source s; Queries cache; Told t;
        Options o = quick(); o.retries = 3;
        Observer<int> obs(&cache, t.fn());
        obs.watch({ "k" }, s.fn(), o); turn();
        Failure gone; gone.status = 404; gone.reason = "nothing there"; gone.final = true;
        s.asked[0].fail(gone); turn();
        QCOMPARE(t.last().status, Error); QCOMPARE(t.last().error.status, 404);
        QCOMPARE(s.asked.size(), 1);
    }
    void theHistorySaysHowLongFetchesTook() {
        Source s; Queries cache;
        cache.fetch<int>({ "a" }, s.fn(), quick(0, 0), [](std::shared_ptr<const int>, const Failure &) {}); turn();
        QTest::qWait(20);
        s.asked[0].ok(1); turn();
        cache.fetch<int>({ "b" }, s.fn(), quick(0, 0), [](std::shared_ptr<const int>, const Failure &) {}); turn();
        s.asked[1].fail({ 500, "down" }); turn();
        const QVariantList h = cache.history();
        QCOMPARE(h.size(), 2);
        QCOMPARE(h[0].toMap()["key"].toString(), QString("a")); QVERIFY(h[0].toMap()["ok"].toBool()); QVERIFY(h[0].toMap()["took"].toInt() >= 15);
        QCOMPARE(h[1].toMap()["key"].toString(), QString("b")); QVERIFY(!h[1].toMap()["ok"].toBool());
        QTRY_COMPARE(cache.size(), 0);                  // kept no longer than asked (not at all), yet in the history
    }
    void dataStaysWhenALaterFetchFails() {
        Source s; Queries cache; Told t;
        Observer<int> o(&cache, t.fn());
        o.watch({ "k" }, s.fn(), quick()); turn();
        s.asked[0].ok(4); turn();
        o.refetch(); turn();
        s.asked[1].fail({ 0, "no network" }); turn();
        QCOMPARE(t.last().status, Error); QCOMPARE(t.value(), 4);
        o.refetch(); turn();
        s.asked[2].ok(5); turn();
        QCOMPARE(t.last().status, Success); QCOMPARE(t.value(), 5); QVERIFY(t.last().error.reason.isEmpty());
    }
    void aFetchNobodyWaitsForGoesOn() {
        Source s; Queries cache;
        { Told t; Observer<int> o(&cache, t.fn()); o.watch({ "k" }, s.fn(), quick()); turn(); }
        QVERIFY(s.cancelled.isEmpty());
        s.asked[0].ok(8); turn();
        QVERIFY(cache.peek<int>({ "k" }));
        QCOMPARE(*cache.peek<int>({ "k" }), 8);         // kept for the next one to ask
    }
    void orIsCancelledAndLeavesNoTrace() {
        Source s; Queries cache;
        Options o = quick(); o.finishUnobserved = false;
        { Told t; Observer<int> obs(&cache, t.fn()); obs.watch({ "k" }, s.fn(), o); turn(); }
        QCOMPARE(s.cancelled, (QVector<int> { 0 }));    // the transfer was told to stop
        QVERIFY(s.asked[0].cancelled());
        s.asked[0].ok(8); turn();                       // what it says after is dropped
        QVERIFY(!cache.peek<int>({ "k" }));
        Told t; Observer<int> again(&cache, t.fn());
        again.watch({ "k" }, s.fn(), o); turn();
        QCOMPARE(t.last().status, Pending); QCOMPARE(s.asked.size(), 2);
    }
    void cancellingPutsItBackAsItWas() {
        Source s; Queries cache; Told t; QVector<int> got; QStringList why;
        Observer<int> o(&cache, t.fn());
        o.watch({ "k" }, s.fn(), quick()); turn();
        s.asked[0].ok(1); turn();
        o.refetch(); turn();
        QVERIFY(t.last().fetching);
        cache.fetch<int>({ "k" }, s.fn(), quick(), [&](std::shared_ptr<const int> d, const Failure &f) { got << (d ? *d : -1); why << f.reason; });
        cache.cancel({ "k" }); turn();
        QCOMPARE(t.last().status, Success); QVERIFY(!t.last().fetching); QCOMPARE(t.value(), 1);
        QCOMPARE(got, (QVector<int> { 1 }));            // the one who asked once gets what there is
        s.asked[1].ok(2); turn();
        QCOMPARE(t.value(), 1);
        // with nothing to go back to, the one who asked is told it was cancelled
        cache.fetch<int>({ "other" }, s.fn(), quick(), [&](std::shared_ptr<const int> d, const Failure &f) { got << (d ? *d : -1); why << f.reason; });
        turn(); cache.cancel({ "other" }); turn();
        QCOMPARE(got.last(), -1); QCOMPARE(why.last(), QString("cancelled"));
    }
    void invalidatingAsksAgainAndTheNewestAnswers() {
        Source s; Queries cache; Told t;
        Observer<int> o(&cache, t.fn());
        o.watch({ "home", "a" }, s.fn(), quick(60000)); turn();
        s.asked[0].ok(1); turn();
        cache.invalidate({ "home" }); turn();
        QCOMPARE(s.asked.size(), 2);                    // fresh, but invalidated: asked again
        QVERIFY(t.last().fetching); QCOMPARE(t.value(), 1);
        cache.invalidate({ "home" }); turn();           // again while that one is under way: it is replaced
        QCOMPARE(s.asked.size(), 3);
        QVERIFY(s.asked[1].cancelled());
        s.asked[2].ok(3); turn();
        s.asked[1].ok(2); turn();                       // the older one answering last changes nothing
        QCOMPARE(t.value(), 3);
        QCOMPARE(cache.counts().dropped, 1);
    }
    void invalidatedDuringItsFirstFetchItShowsThatAnswerAndFetchesAgain() {
        Source s; Queries cache; Told t;
        Observer<int> o(&cache, t.fn());
        o.watch({ "home" }, s.fn(), quick(60000)); turn();
        cache.invalidate({ "home" }); turn();           // what the fetch read may have changed under it
        QCOMPARE(s.asked.size(), 1); QVERIFY(!s.asked[0].cancelled());      // let finish: there is nothing to show yet
        s.asked[0].ok(1); turn();
        QCOMPARE(t.value(), 1);                         // shown
        QCOMPARE(s.asked.size(), 2); QVERIFY(t.last().fetching);            // and asked again at once
        s.asked[1].ok(2); turn();
        QCOMPARE(t.value(), 2); QVERIFY(!t.last().fetching);
        QCOMPARE(s.asked.size(), 2);
    }
    void invalidatingWhatNobodyWatchesWaitsForTheNextAsking() {
        Source s; Queries cache; QVector<int> got;
        auto then = [&got](std::shared_ptr<const int> d, const Failure &) { got << (d ? *d : -1); };
        cache.fetch<int>({ "home", "a" }, s.fn(), quick(60000), then); turn();
        s.asked[0].ok(1); turn();
        cache.invalidate({ "home" }); turn();
        QCOMPARE(s.asked.size(), 1);
        cache.fetch<int>({ "home", "a" }, s.fn(), quick(60000), then); turn();
        QCOMPARE(s.asked.size(), 2);
        cache.invalidate({ "elsewhere" }); turn();      // another key's prefix touches nothing
        QCOMPARE(s.asked.size(), 2);
    }
    void anObserverHearsOnlyOfTheKeyItWatches() {
        Source s; Queries cache; Told t;
        Observer<int> o(&cache, t.fn());
        o.watch({ "search", "na" }, s.fn(), quick()); turn();
        o.watch({ "search", "naruto" }, s.fn(), quick()); turn();
        QCOMPARE(s.asked.size(), 2);
        s.asked[1].ok(20); turn();
        const int told = t.results.size();
        s.asked[0].ok(10); turn();                      // the first key's answer, late: the cache's, not the observer's
        QCOMPARE(t.results.size(), told);
        QCOMPARE(t.value(), 20);
        QCOMPARE(*cache.peek<int>({ "search", "na" }), 10);
    }
    void theDataShownStaysUntilTheNewKeyHasItsOwn() {
        Source s; Queries cache; Told t;
        Observer<int> o(&cache, t.fn());
        o.watch({ "page", "1" }, s.fn(), quick(), true); turn();
        s.asked[0].ok(1); turn();
        o.watch({ "page", "2" }, s.fn(), quick(), true); turn();
        QCOMPARE(t.last().status, Pending); QVERIFY(t.last().placeholder); QCOMPARE(t.value(), 1);
        o.watch({ "page", "3" }, s.fn(), quick(), true); turn();
        QVERIFY(t.last().placeholder); QCOMPARE(t.value(), 1);          // still the last data it had of its own
        s.asked[2].ok(3); turn();
        QVERIFY(!t.last().placeholder); QCOMPARE(t.value(), 3); QCOMPARE(t.last().status, Success);
        // without it, the new key starts with nothing
        o.watch({ "page", "4" }, s.fn(), quick(), false); turn();
        QVERIFY(!t.last().data); QVERIFY(!t.last().placeholder);
    }
    void aPlaceholderGoesWhenTheNewKeyFails() {
        Source s; Queries cache; Told t;
        Observer<int> o(&cache, t.fn());
        o.watch({ "page", "1" }, s.fn(), quick(), true); turn();
        s.asked[0].ok(1); turn();
        o.watch({ "page", "2" }, s.fn(), quick(), true); turn();
        s.asked[1].fail({ 500, "down" }); turn();
        QCOMPARE(t.last().status, Error); QVERIFY(!t.last().data); QVERIFY(!t.last().placeholder);
    }
    void anAnswerMayComeFromAnotherThread() {
        Queries cache; Told t;
        QThread *worker = nullptr;
        const Fetch<int> elsewhere = [&worker](Call<int> call) {
            worker = QThread::create([call] { QThread::msleep(5); call.ok(11); });
            worker->start();
        };
        Observer<int> o(&cache, t.fn());
        o.watch({ "k" }, elsewhere, quick());
        QTRY_COMPARE(t.value(), 11);
        worker->wait(); delete worker;
    }
    void workIsDoneOffTheCachesThreadAndWhatItReturnsIsTheAnswer() {
        Queries cache; Told t;
        std::atomic<QThread *> ran { nullptr };
        Observer<int> o(&cache, t.fn());
        o.watch({ "k" }, onWorker<int>([&ran] { ran = QThread::currentThread(); return 12; }), quick());
        QVERIFY(!ran.load() || ran.load() != QThread::currentThread());
        QTRY_COMPARE(t.value(), 12);
        QVERIFY(ran.load() && ran.load() != QThread::currentThread());
    }
    void workReplacedRunsToItsEndAndTheNewestIsTheAnswer() {
        Queries cache; Told t;
        std::atomic<int> runs { 0 };
        Observer<int> o(&cache, t.fn());
        const auto work = onWorker<int>([&runs] { const int n = ++runs; QThread::msleep(n == 2 ? 60 : 5); return n; });
        o.watch({ "k" }, work, quick());
        QTRY_COMPARE(t.value(), 1);
        cache.invalidate({ "k" }); turn();              // a read under way (the slow one),
        cache.invalidate({ "k" });                      // and what it reads changes again
        QTRY_COMPARE(t.value(), 3);
        QTRY_COMPARE(cache.counts().dropped, 1);        // the slow one ended later, and changed nothing
        QCOMPARE(t.value(), 3);
    }
    void allRunsWhatFollowsOnceWhenTheLastPartIsIn() {
        All all; int ran = 0;
        const auto a = all.part(), b = all.part();
        a();
        all.then([&ran] { ++ran; });
        QCOMPARE(ran, 0);                               // one part is still out
        a();                                            // the same part again counts once
        QCOMPARE(ran, 0);
        b();
        QCOMPARE(ran, 1);
        b();
        QCOMPARE(ran, 1);
    }
    void allRunsAtOnceWhenEveryPartWasInAlreadyOrThereWereNone() {
        All answered, none; int ran = 0;
        const auto a = answered.part();
        a();                                            // in before what follows was said: nothing ran early
        QCOMPARE(ran, 0);
        answered.then([&ran] { ++ran; });
        QCOMPARE(ran, 1);
        none.then([&ran] { ++ran; });
        QCOMPARE(ran, 2);
    }
    void inTurnsOnlySoManyAreOutAtATime() {
        QVector<std::function<void()>> out; QVector<int> asked; int done = 0;
        inTurns(5, 2, [&](int n, std::function<void()> in) { asked << n; out << in; }, [&done] { ++done; });
        QCOMPARE(asked, (QVector<int> { 0, 1 }));
        out[1]();                                       // one in: the next goes out
        QCOMPARE(asked, (QVector<int> { 0, 1, 2 }));
        out[1]();                                       // (the same one again: nothing)
        QCOMPARE(asked.size(), 3);
        out[0](); out[2]();
        QCOMPARE(asked, (QVector<int> { 0, 1, 2, 3, 4 }));
        out[3]();
        QCOMPARE(done, 0);
        out[4]();
        QCOMPARE(done, 1);
        int none = 0;
        inTurns(0, 8, [](int, std::function<void()>) { QFAIL("nothing to ask for"); }, [&none] { ++none; });
        QCOMPARE(none, 1);
    }
    void theCacheSaysHowManyOfAKindAreBeingFetched() {
        Source s; Queries cache;
        const auto then = [](std::shared_ptr<const int>, const Failure &) {};
        cache.fetch<int>({ "page", "a" }, s.fn(), quick(60000), then);
        cache.fetch<int>({ "page", "b" }, s.fn(), quick(60000), then);
        cache.fetch<int>({ "other" }, s.fn(), quick(60000), then);
        QCOMPARE(cache.fetching({ "page" }), 2); QCOMPARE(cache.fetching({ "page", "a" }), 1);
        s.asked[0].ok(1); turn();
        QCOMPARE(cache.fetching({ "page" }), 1); QCOMPARE(cache.fetching({ "page", "a" }), 0);       // held now, no longer on its way
        QCOMPARE(cache.fetching({ "page", "never asked" }), 0);
    }
    void aFaultMakesAQuerySlowOrFailing() {
        Source s; Queries cache; Told slow, failing;
        cache.fault("slow", 40, false); cache.fault("broken", 0, true);
        Observer<int> a(&cache, slow.fn()), b(&cache, failing.fn());
        a.watch({ "slow", "1" }, s.fn(), quick());
        b.watch({ "broken", "1" }, s.fn(), quick());
        turn();
        QCOMPARE(s.asked.size(), 0);                    // neither has reached the source
        QTRY_COMPARE(failing.results.isEmpty() ? Pending : failing.last().status, Error);
        QCOMPARE(failing.last().error.reason, QString("made to fail"));
        QTRY_COMPARE(s.asked.size(), 1);                // the slow one, late
        cache.clearFaults();
        Told t; Observer<int> c(&cache, t.fn());
        c.watch({ "broken", "2" }, s.fn(), quick()); turn();
        QCOMPARE(s.asked.size(), 2);
    }
    void dataPutInByHandIsToldLikeAnAnswer() {
        Source s; Queries cache; Told t;
        Observer<int> o(&cache, t.fn());
        o.watch({ "k" }, s.fn(), quick(60000)); turn();
        cache.put<int>({ "k" }, 42, quick(60000)); turn();
        QCOMPARE(t.last().status, Success); QCOMPARE(t.value(), 42); QVERIFY(!t.last().fetching);
        QVERIFY(s.asked[0].cancelled());                // the fetch it replaced was stopped
    }
    void removingStartsItsObserversFromNothing() {
        Source s; Queries cache; Told t;
        Observer<int> o(&cache, t.fn());
        o.watch({ "k" }, s.fn(), quick(60000)); turn();
        s.asked[0].ok(1); turn();
        cache.remove({ "k" }); turn();
        QCOMPARE(t.last().status, Pending); QVERIFY(!t.last().data); QCOMPARE(s.asked.size(), 2);
        cache.fetch<int>({ "gone" }, s.fn(), quick(60000), [](std::shared_ptr<const int>, const Failure &) {}); turn();
        s.asked[2].ok(1); turn();
        cache.remove({ "gone" });
        QVERIFY(!cache.peek<int>({ "gone" }));
    }
    void removingAnEntryTellsThoseWhoAskedOnce() {
        Source s; Queries cache; QStringList why; int got = 0;
        cache.fetch<int>({ "k" }, s.fn(), quick(), [&](std::shared_ptr<const int> d, const Failure &f) { got++; if (!d) why << f.reason; });
        turn();
        cache.remove({ "k" });
        QCOMPARE(got, 0);                               // not from inside the call
        turn();
        QCOMPARE(got, 1); QCOMPARE(why, QStringList { "cancelled" });
        QVERIFY(s.asked[0].cancelled());
    }
    void toldAgainAnObserverSaysWhatItShows() {
        Source s; Queries cache; Told t;
        Observer<int> o(&cache, t.fn());
        o.watch({ "k" }, s.fn(), quick(60000)); turn();
        s.asked[0].ok(1); turn();
        const int told = t.results.size();
        o.watch({ "k" }, s.fn(), quick(60000)); turn();
        QCOMPARE(t.results.size(), told);               // nothing changed: nothing said
        o.retell(); turn();
        QCOMPARE(t.results.size(), told + 1); QCOMPARE(t.value(), 1);
    }
    // an answer on another thread at the moment the cache ends finds it there or gone, never half way
    void anAnswerFromAnotherThreadMayMeetTheCachesEnd() {
        for (int round = 0; round < 300; round++) {
            auto *cache = new Queries;
            std::atomic<bool> go { false };
            QThread *worker = nullptr;
            cache->fetch<int>({ "k" }, [&](Call<int> call) {
                worker = QThread::create([call, &go] { while (!go) QThread::yieldCurrentThread(); call.ok(1); call.fail({ 0, "late" }); });
                worker->start();
            }, quick(), [](std::shared_ptr<const int>, const Failure &) {});
            go = true;
            if (round % 2) QThread::yieldCurrentThread();
            delete cache;
            worker->wait(); delete worker;
        }
    }
    void anObserverMayGoInsideItsOwnCallback() {
        Source s; Queries cache;
        Observer<int> *o = nullptr; int told = 0;
        o = new Observer<int>(&cache, [&](const Result<int> &) { ++told; delete o; o = nullptr; });
        Told t; Observer<int> other(&cache, t.fn());
        o->watch({ "k" }, s.fn(), quick());
        other.watch({ "k" }, s.fn(), quick());
        turn();
        QCOMPARE(told, 1); QVERIFY(!o);
        s.asked[0].ok(1); turn();
        QCOMPARE(t.value(), 1);
    }
    void theCacheMayGoWithFetchesUnderWay() {
        Source s; Told t;
        auto *cache = new Queries;
        auto *o = new Observer<int>(cache, t.fn());
        o->watch({ "k" }, s.fn(), quick()); turn();
        delete cache;
        QCOMPARE(s.cancelled, (QVector<int> { 0 }));
        s.asked[0].ok(1);                               // answers into nothing
        delete o;                                       // and an observer left behind watches nothing
    }
    void theLabListsWhatTheCacheHolds() {
        Source s; Queries cache; Told t;
        Observer<int> o(&cache, t.fn());
        o.watch({ "title", "tt1" }, s.fn(), quick()); turn();
        QVariantMap row = cache.lab().value(0).toMap();
        QCOMPARE(row["key"].toString(), QString("title tt1")); QCOMPARE(row["status"].toString(), QString("pending"));
        QCOMPARE(row["fetching"].toBool(), true); QCOMPARE(row["observers"].toInt(), 1); QCOMPARE(row["age"].toInt(), -1);
        s.asked[0].ok(1); turn();
        row = cache.lab().value(0).toMap();
        QCOMPARE(row["status"].toString(), QString("success")); QVERIFY(row["age"].toInt() >= 0); QVERIFY(row["took"].toInt() >= 0);
    }
};

QTEST_GUILESS_MAIN(TestQuery)
#include "tst_query.moc"
