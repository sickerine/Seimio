#pragma once
// Queries: one cache for everything asked of a service, and the one place that decides what a request's
// state is. It follows TanStack Query's core (docs/state-and-query-research.md has the sources); no such
// library exists for C++ or Qt, which is why this one is ours. The rules, each tested in
// tools/tests/native/tst_query.cpp:
//  - A query has a key. The cache holds one entry a key, and everyone asking for a key shares it.
//  - An entry answers two questions apart: `status` (Pending: no data yet, Error: the last fetch failed,
//    Success) and `fetching` (a fetch is under way). Data stays while it is fetched again, and stays
//    after a later fetch has failed.
//  - A fetch asked for while one is under way joins it.
//  - `freshMs` is how long data needs no asking again; `keepMs` how long an entry nobody uses stays.
//  - A failed fetch is tried again (`retries` times, after 1 s, 2 s, 4 s, ... 30 s at most, or as
//    `retryDelay` says) before the failure shows.
//  - A fetch nobody waits for any more goes on, and its answer is kept (`finishUnobserved`), or is
//    cancelled, which puts the entry back as it was before the fetch.
//  - `invalidate` marks entries to be asked again; the ones in use are fetched again at once, a fetch
//    under way replaced, so the newest asking is the one that answers. (A first fetch is let finish, to
//    have something to show, and fetched again when it has.)
//  - Nobody is told of a change from inside a call into the cache: changes are gathered and told on the
//    next turn of the event loop, each observer once with the entry's latest state. So no callback runs
//    half way through the caller's own work, and none sees a state that is about to change again.
//  - An observer (`Observer`) watches one key at a time. Pointed at another, it hears only of that one:
//    an answer for a key it has left is the cache's and no longer its own. With `keepPrevious` it shows
//    the data it had (`placeholder`) until the new key has its own.
// A cache belongs to one thread and is used from it; a fetch function may answer from any thread, and
// one that is work to do (`onWorker`) does it on a pooled thread.
// Tooling: `lab()` lists every entry, `counts()` what the cache did, and `fault()` makes the queries it
// names slow or failing, to see how a screen takes it.
#include <QHash>
#include <QMutex>
#include <QObject>
#include <QPointer>
#include <QRunnable>
#include <QSet>
#include <QStringList>
#include <QThread>
#include <QThreadPool>
#include <QTimer>
#include <QVariant>
#include <QVector>
#include <atomic>
#include <chrono>
#include <functional>
#include <memory>
#include <typeindex>
#include <vector>

namespace query {

using Key = QStringList;
inline QString idOf(const Key &key) { return key.join(QChar(0x1f)); }

enum Status { Pending, Error, Success };

// why a fetch failed: the service's status (0 when nothing answered) and a word on it; `final` when
// trying again can't help (nothing is there, the wait ran out), `waitMs` when the service said how long
// to stay away
struct Failure {
    int status = 0;
    QString reason;
    bool final = false;
    int waitMs = 0;
    bool operator==(const Failure &o) const { return status == o.status && reason == o.reason; }
};

struct Options {
    qint64 freshMs = 0;                 // how long data needs no asking again
    qint64 keepMs = 5 * 60 * 1000;      // how long an entry nobody uses is kept
    int retries = 3;                    // tries after the first, before the failure shows
    // how long before the n-th try again (n from 1); under 0: no more tries. None: `backoff`, which is 1 s
    // doubling to 30 s, the wait the service asked for if it named one, and no more tries after a failure
    // that is final
    std::function<int(int, const Failure &)> retryDelay;
    bool finishUnobserved = true;       // a fetch nobody waits for goes on (its answer is kept), else it is cancelled
    int priority = 0;                   // for the fetch function to pass on (Call::priority)
};
inline int backoff(int n, const Failure &why) {
    return why.final ? -1 : why.waitMs > 0 ? why.waitMs : int(qMin<qint64>(qint64(1000) << qMin(n - 1, 20), 30000));
}

// `work` on one of Qt's pooled threads. It answers through a Call, which finds its cache there or gone;
// anything else it touches is its own to keep alive.
inline void onPool(std::function<void()> work) {
    // (Qt 5.12's pool takes a QRunnable only; a function as it is came with 5.15)
    struct Job : QRunnable { std::function<void()> go; void run() override { go(); } };
    auto *job = new Job;                        // the pool's from here: deleted when it has run
    job->go = std::move(work);
    QThreadPool::globalInstance()->start(job);
}

// ---- putting what was asked for together -----------------------------------------------------------------
// Several things asked for at once, and one call when the last of them is in: `part()` gives the function
// a part calls when it is in, `then(done)` says what follows. `done` runs once, when every part handed out
// has been called: with the last of them, or at once when they all were (or there were none). A part
// called twice counts once. (QtPromise's `all` is this and more, and is not used: its handlers belong to
// no object, so one that captures `this` runs after the object is gone, where an answer from the cache or
// from Net is dropped with its owner; and it has no way to stop. docs/state-and-query-research.md.)
class All {              // (a handle: copies are the same gathering)
public:
    std::function<void()> part() const {
        const auto s = m_state;
        const auto called = std::make_shared<bool>(false);
        ++s->left;
        return [s, called] { if (*called) return; *called = true; if (--s->left == 0) fire(s); };
    }
    void then(std::function<void()> done) const { m_state->done = std::move(done); if (m_state->left == 0) fire(m_state); }
private:
    struct State { int left = 0; std::function<void()> done; };
    static void fire(const std::shared_ptr<State> &s) {
        const auto done = std::move(s->done);
        s->done = nullptr;
        if (done) done();
    }
    std::shared_ptr<State> m_state = std::make_shared<State>();
};
// The same for `count` of a kind, `atOnce` of them out at a time: `ask(n, in)` asks for the n-th and calls
// `in` when it is in; `done` when all are (at once when there are none). For many requests to one host: a
// request waiting its turn inside Qt has its clock running (Net gives up on one that brings nothing).
inline void inTurns(int count, int atOnce, std::function<void(int, std::function<void()>)> ask, std::function<void()> done) {
    struct Turns : std::enable_shared_from_this<Turns> {
        int count = 0, next = 0, left = 0;
        std::function<void(int, std::function<void()>)> ask;
        std::function<void()> done;
        void step() {
            if (next >= count) return;
            const int n = next++;
            const auto self = shared_from_this();
            const auto called = std::make_shared<bool>(false);
            ask(n, [self, called] { if (*called) return; *called = true; if (--self->left == 0) self->done(); else self->step(); });
        }
    };
    if (count <= 0) { done(); return; }
    const auto turns = std::make_shared<Turns>();
    turns->count = turns->left = count; turns->ask = std::move(ask); turns->done = std::move(done);
    for (int k = 0; k < atOnce && k < count; k++) turns->step();
}

// One go at fetching. The fetch function keeps its Call for as long as it works, and answers through it.
// The way from a fetch back to its cache. A fetch function may answer on any thread, and the cache may
// end while it does: both go through the gate's lock, so an answer finds the cache there or gone, never
// half way.
class Queries;
struct Gate { QMutex lock; Queries *cache = nullptr; };

struct Run {
    std::shared_ptr<Gate> gate;
    QString id;
    int attempt = 1, priority = 0;
    std::atomic<bool> over { false };           // answered, cancelled or replaced: what it says after is dropped
    std::vector<std::function<void()>> stops;   // what to stop if it is cancelled (the transfer)
};

template <class T> class Call {
public:
    void ok(T value) const;
    void fail(Failure why) const;
    bool cancelled() const { return run->over; }
    // (from the cache's thread, in the fetch function itself) what to do if the fetch is cancelled
    void onCancel(std::function<void()> stop) const { run->stops.push_back(std::move(stop)); }
    int attempt() const { return run->attempt; }
    int priority() const { return run->priority; }
    const QString &id() const { return run->id; }
private:
    friend class Queries;
    std::shared_ptr<Run> run;
};
template <class T> using Fetch = std::function<void(Call<T>)>;

// A fetch that is work rather than a request (a megabyte of JSON to read and shape): `work` runs on one
// of Qt's pooled threads and what it returns is the answer. Work can't be stopped half way: cancelled or
// replaced, it runs to its end and its answer is dropped.
template <class T> Fetch<T> onWorker(std::function<T()> work) {
    return [work](Call<T> call) { onPool([work, call] { call.ok(work()); }); };
}

struct ObserverBase {
    virtual ~ObserverBase() = default;
    virtual void changed() = 0;
};

struct Entry {
    Key key; QString id;
    std::type_index type { typeid(void) };
    Status status = Pending;
    bool fetching = false;
    std::shared_ptr<const void> data;
    qint64 dataAt = 0;                          // when the data came, on the cache's clock
    Failure error;                              // the failure that shows (status Error)
    Failure lastFailure; int failures = 0;      // of the fetch under way: tries that failed so far
    bool invalidated = false;
    bool again = false;                         // invalidated during its first fetch: to be fetched again when that one is in
    Options options;
    std::function<void(const std::shared_ptr<Run> &)> start;        // the fetch function, bound to its type
    std::shared_ptr<Run> run;
    struct { Status status = Pending; Failure error; bool invalidated = false; } before;   // to go back to if the fetch is cancelled
    QVector<ObserverBase *> observers;
    std::vector<std::function<void(Entry &)>> waiters;              // those who asked once (`Queries::fetch`)
    quint64 left = 0;                           // each time it is taken up or left: an older keep timer does nothing
    int fetches = 0, joined = 0; qint64 startedAt = 0, tookMs = -1;        // lab
};

struct Counts { int fetches = 0, joined = 0, fresh = 0, retries = 0, cancelled = 0, dropped = 0, failed = 0; };
struct Finished { QString key; int tookMs; bool ok; qint64 at; };        // a fetch that ended (the lab's history)

class Queries : public QObject {
public:
    explicit Queries(QObject *parent = nullptr) : QObject(parent) { m_gate->cache = this; }
    // (nothing may leave a destructor, and the compiler's own way of saying so is newer than the TV's C++
    // runtime: native/check-symbols.sh. The same in ~Observer and ~Watch.)
    ~Queries() override {
        try {
            { QMutexLocker closing(&m_gate->lock); m_gate->cache = nullptr; }       // no answer comes in from here on
            for (auto &e : m_entries) if (e->run) stop(*e->run);
        } catch (...) { }
    }

    // Asks once. `then(data, failure)` on a later turn: the data, kept if it is still fresh, or none and
    // why it couldn't be had (after the tries Options allow).
    template <class T>
    void fetch(const Key &key, Fetch<T> fn, const Options &options, std::function<void(std::shared_ptr<const T>, const Failure &)> then) {
        Entry &e = entry<T>(key, std::move(fn), options);
        ++e.left;
        e.waiters.push_back([then](Entry &e) {
            if (e.data && e.status != Error) then(std::static_pointer_cast<const T>(e.data), Failure());
            else then(nullptr, e.status == Error ? e.error : Failure { 0, "cancelled" });
        });
        if (fresh(e)) ++m_counts.fresh; else ask(e);
        dirty(e);
    }
    // what the cache holds for a key now, fresh or not (none: nothing)
    template <class T> std::shared_ptr<const T> peek(const Key &key) const {
        const auto it = m_entries.constFind(idOf(key));
        return it == m_entries.constEnd() || (*it)->type != std::type_index(typeid(T)) ? nullptr : std::static_pointer_cast<const T>((*it)->data);
    }
    // how many of the keys that begin with `prefix` are being fetched now
    int fetching(const Key &prefix) const { int n = 0; for (const auto &e : matching(prefix)) n += e->fetching; return n; }
    // puts data in by hand (what another answer already carried), as if it had just been fetched
    template <class T> void put(const Key &key, T value, const Options &options = Options()) {
        Entry &e = entry<T>(key, nullptr, options);
        if (e.run) cancel(e);
        e.data = std::make_shared<const T>(std::move(value));
        e.dataAt = now(); e.status = Success; e.error = Failure(); e.invalidated = false;
        dirty(e); settle(e);
    }

    // The entries whose keys begin with `prefix` are to be asked again: the ones observed at once, the
    // others when next asked for. A fetch under way may have read what has just changed. One that has
    // data to show meanwhile is replaced; a first fetch is let finish, so that there is something to
    // show, and is fetched again the moment it has.
    void invalidate(const Key &prefix) {
        for (const auto &e : matching(prefix)) {
            const bool observed = !e->observers.isEmpty() && e->start;
            if (observed && e->fetching && !e->data) { e->again = true; continue; }
            if (observed && e->fetching) cancel(*e);
            e->invalidated = true;
            dirty(*e);
            if (observed) ask(*e);
        }
    }
    // stops the fetches under way for these keys; each entry goes back to what it was before its fetch
    void cancel(const Key &prefix) { for (const auto &e : matching(prefix)) if (e->run) cancel(*e); }
    // forgets these keys (their observers start again from nothing)
    void remove(const Key &prefix) {
        for (const auto &e : matching(prefix)) {
            if (e->run) cancel(*e);
            e->data.reset(); e->status = Pending; e->error = Failure(); e->invalidated = false;
            if (e->observers.isEmpty()) {
                // those who asked once are told it was cancelled, on a later turn like any answer
                const auto waiters = std::move(e->waiters);
                e->waiters.clear();
                m_entries.remove(e->id);
                if (!waiters.empty()) QTimer::singleShot(0, this, [waiters, e] { for (const auto &w : waiters) w(*e); });
                continue;
            }
            dirty(*e);
            if (e->start) ask(*e);
        }
    }

    // ---- tooling ---------------------------------------------------------------------------------------
    // every entry: { key, status, fetching, observers, age (ms since its data came, -1: none), failures,
    // error, took (ms the last fetch took), fetches, joined }
    QVariantList lab() const {
        static const char *names[] = { "pending", "error", "success" };
        QVariantList out;
        for (const auto &e : m_entries)
            out << QVariantMap { { "key", e->key.join(" ") }, { "status", names[e->status] }, { "fetching", e->fetching }, { "observers", e->observers.size() },
                                 { "age", e->data ? now() - e->dataAt : -1 }, { "failures", e->failures }, { "error", e->status == Error ? e->error.reason : QString() },
                                 { "took", e->tookMs }, { "fetches", e->fetches }, { "joined", e->joined } };
        return out;
    }
    const Counts &counts() const { return m_counts; }
    // the last fetches that ended, oldest first: { key, took (ms), ok, ago (ms) }; entries that are gone too
    QVariantList history() const {
        QVariantList out;
        for (const Finished &f : m_history) out << QVariantMap { { "key", f.key }, { "took", f.tookMs }, { "ok", f.ok }, { "ago", now() - f.at } };
        return out;
    }
    // the lab report's part: the entries in use (`held`), how many more are only kept, the last forty
    // fetches that ended, and the counts
    QVariantMap summary() const {
        QVariantList held; int kept = 0;
        for (const QVariant &v : lab()) { const QVariantMap e = v.toMap(); if (e["observers"].toInt() || e["fetching"].toBool()) held << e; else kept++; }
        const QVariantList ended = history();
        return { { "held", held }, { "kept", kept }, { "history", ended.mid(qMax(0, ended.size() - 40)) },
                 { "counts", QVariantMap { { "fetches", m_counts.fetches }, { "joined", m_counts.joined }, { "fresh", m_counts.fresh }, { "retries", m_counts.retries },
                                           { "cancelled", m_counts.cancelled }, { "dropped", m_counts.dropped }, { "failed", m_counts.failed } } } };
    }
    int size() const { return m_entries.size(); }
    // The queries whose key holds `match` take `delayMs` longer and, with `fail`, fail: to see what a
    // screen does with a slow or a failed answer. `clearFaults` ends it.
    void fault(const QString &match, int delayMs, bool fail) { m_faults.push_back({ match, delayMs, fail }); }
    void clearFaults() { m_faults.clear(); }
    qint64 now() const { return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count(); }

private:
    template <class T> friend class Observer;
    template <class T> friend class Call;
    struct Fault { QString match; int delayMs; bool fail; };

    template <class T> Entry &entry(const Key &key, Fetch<T> fn, const Options &options) {
        Q_ASSERT(QThread::currentThread() == thread());
        const QString id = idOf(key);
        auto it = m_entries.find(id);
        if (it == m_entries.end()) {
            auto e = std::make_shared<Entry>();
            e->key = key; e->id = id; e->type = std::type_index(typeid(T));
            it = m_entries.insert(id, e);
        }
        Entry &e = **it;
        if (e.type != std::type_index(typeid(T))) qFatal("query: the key %s is asked for as two types of data", qPrintable(key.join(" ")));
        e.options = options;
        if (fn) e.start = [this, fn](const std::shared_ptr<Run> &run) { Call<T> call; call.run = run; fn(call); };
        return e;
    }
    QVector<std::shared_ptr<Entry>> matching(const Key &prefix) const {
        QVector<std::shared_ptr<Entry>> out;
        for (const auto &e : m_entries) if (e->key.mid(0, prefix.size()) == prefix) out << e;
        return out;
    }
    bool fresh(const Entry &e) const { return e.data && !e.invalidated && e.status != Error && now() - e.dataAt < e.options.freshMs; }

    // a fetch for it, unless one is under way already (which this asking then joins)
    void ask(Entry &e) {
        if (e.fetching) { ++e.joined; ++m_counts.joined; return; }
        if (!e.start) return;
        e.before.status = e.status; e.before.error = e.error; e.before.invalidated = e.invalidated;
        e.fetching = true; e.failures = 0; e.lastFailure = Failure();
        e.startedAt = now(); ++e.fetches; ++m_counts.fetches;
        launch(e, 1);
        dirty(e);
    }
    void launch(Entry &e, int attempt) {
        auto run = std::make_shared<Run>();
        run->gate = m_gate; run->id = e.id; run->attempt = attempt; run->priority = e.options.priority;
        e.run = run;
        for (const Fault &f : m_faults) if (e.id.contains(f.match)) {
            const bool fail = f.fail;
            QTimer::singleShot(f.delayMs, this, [this, run, fail] {
                if (run->over) return;
                if (fail) { failed(run, Failure { 0, "made to fail" }); return; }
                if (const auto e = m_entries.value(run->id)) if (e->run == run) e->start(run);
            });
            return;
        }
        e.start(run);
    }
    static void stop(Run &run) {
        run.over = true;
        const auto stops = std::move(run.stops);
        run.stops.clear();
        for (const auto &s : stops) s();
    }
    // the fetch under way is stopped and the entry is as it was before it
    void cancel(Entry &e) {
        const auto run = e.run;
        e.run.reset();
        e.fetching = false; e.failures = 0; e.lastFailure = Failure(); e.again = false;
        e.status = e.before.status; e.error = e.before.error; e.invalidated = e.before.invalidated;
        ++m_counts.cancelled;
        if (run) stop(*run);
        dirty(e); settle(e);
    }

    // a fetch function's answer, on the cache's thread (Call brings it over from any other)
    void arrived(const std::shared_ptr<Run> &run, std::shared_ptr<const void> data) {
        const auto e = m_entries.value(run->id);
        if (run->over || !e || e->run != run) { ++m_counts.dropped; return; }
        run->over = true; run->stops.clear(); e->run.reset();
        e->data = std::move(data); e->dataAt = now();
        e->status = Success; e->error = Failure(); e->invalidated = false;
        e->fetching = false; e->failures = 0; e->lastFailure = Failure(); e->tookMs = now() - e->startedAt;
        note(*e, true);
        dirty(*e); settle(*e);
        if (e->again) { e->again = false; if (!e->observers.isEmpty()) { e->invalidated = true; ask(*e); } }
    }
    void note(const Entry &e, bool ok) {
        m_history.push_back({ e.key.join(" "), int(e.tookMs), ok, now() });
        if (m_history.size() > 200) m_history.erase(m_history.begin(), m_history.begin() + 50);
    }
    void failed(const std::shared_ptr<Run> &run, const Failure &why) {
        const auto e = m_entries.value(run->id);
        if (run->over || !e || e->run != run) { ++m_counts.dropped; return; }
        run->over = true; run->stops.clear();
        ++e->failures; e->lastFailure = why;
        const int wait = e->failures <= e->options.retries ? (e->options.retryDelay ? e->options.retryDelay(e->failures, why) : backoff(e->failures, why)) : -1;
        if (wait >= 0) {
            // the next try: a run of its own from now, so that cancelling in the wait finds it
            ++m_counts.retries;
            auto next = std::make_shared<Run>();
            next->gate = m_gate; next->id = e->id; next->attempt = run->attempt + 1; next->priority = e->options.priority;
            e->run = next;
            QTimer::singleShot(wait, this, [this, next] {
                const auto e = m_entries.value(next->id);
                if (next->over || !e || e->run != next) return;
                launch(*e, next->attempt);
            });
            dirty(*e);
            return;
        }
        e->run.reset(); e->again = false;
        e->status = Error; e->error = why; e->invalidated = true;
        e->fetching = false; e->tookMs = now() - e->startedAt; ++m_counts.failed;
        note(*e, false);
        dirty(*e); settle(*e);
    }

    // left alone (nobody observes it, nothing is fetched): it goes after `keepMs`, unless taken up again
    void settle(Entry &e) {
        if (!e.observers.isEmpty() || e.fetching || !e.waiters.empty()) return;
        const quint64 left = ++e.left;
        const QString id = e.id;
        QTimer::singleShot(int(qMin<qint64>(e.options.keepMs, INT_MAX)), this, [this, id, left] {
            const auto e = m_entries.value(id);
            if (e && e->left == left && e->observers.isEmpty() && !e->fetching && e->waiters.empty()) m_entries.remove(id);
        });
    }
    void unobserve(Entry &e, ObserverBase *o) {
        e.observers.removeOne(o);
        if (!e.observers.isEmpty()) return;
        if (e.fetching && !e.options.finishUnobserved && e.waiters.empty()) cancel(e); else settle(e);
    }

    // changes are told on the next turn, each entry's observers once
    void dirty(Entry &e) {
        m_dirty.insert(e.id);
        if (m_told) return;
        m_told = true;
        QTimer::singleShot(0, this, [this] { tell(); });
    }
    void tell() {
        m_told = false;
        const QSet<QString> ids = std::move(m_dirty);
        m_dirty.clear();
        for (const QString &id : ids) {
            auto e = m_entries.value(id);
            if (!e) continue;
            const QVector<ObserverBase *> observers = e->observers;
            for (ObserverBase *o : observers) if (m_observers.contains(o)) o->changed();       // (one may have gone in another's callback)
            e = m_entries.value(id);
            if (!e || e->fetching || e->waiters.empty()) continue;
            const auto waiters = std::move(e->waiters);
            e->waiters.clear();
            for (const auto &w : waiters) w(*e);
            if ((e = m_entries.value(id))) settle(*e);
        }
    }

    std::shared_ptr<Gate> m_gate = std::make_shared<Gate>();
    QHash<QString, std::shared_ptr<Entry>> m_entries;
    QSet<ObserverBase *> m_observers;           // the ones alive
    QSet<QString> m_dirty;
    bool m_told = false;
    Counts m_counts;
    std::vector<Finished> m_history;
    std::vector<Fault> m_faults;
};

// An answer goes to the cache on the cache's thread: straight in from there, and from another thread
// posted to it under the gate's lock, where the cache is either still there to post to or gone. (An
// answer to a fetch that is over is dropped by the cache, which counts it.)
template <class T> void Call<T>::ok(T value) const {
    auto data = std::make_shared<const T>(std::move(value));
    const auto r = run;
    QMutexLocker here(&r->gate->lock);
    Queries *cache = r->gate->cache;
    if (!cache) return;
    if (QThread::currentThread() == cache->thread()) { here.unlock(); cache->arrived(r, data); }
    else QMetaObject::invokeMethod(cache, [cache, r, data] { cache->arrived(r, data); }, Qt::QueuedConnection);
}
template <class T> void Call<T>::fail(Failure why) const {
    const auto r = run;
    QMutexLocker here(&r->gate->lock);
    Queries *cache = r->gate->cache;
    if (!cache) return;
    if (QThread::currentThread() == cache->thread()) { here.unlock(); cache->failed(r, why); }
    else QMetaObject::invokeMethod(cache, [cache, r, why] { cache->failed(r, why); }, Qt::QueuedConnection);
}

// what an observer shows of the query it watches
template <class T> struct Result {
    Status status = Pending;
    bool fetching = false;
    std::shared_ptr<const T> data;          // the query's, or with `placeholder` what the observer showed before
    bool placeholder = false;
    Failure error;                          // with status Error
    int failures = 0;                       // tries of the fetch under way that failed
    bool operator==(const Result &o) const {
        return status == o.status && fetching == o.fetching && data == o.data && placeholder == o.placeholder && error == o.error && failures == o.failures;
    }
};

// Watches one query at a time and says when what it shows of it changes (`changed(result)`, never from
// inside a call of the caller's). It lives on the cache's thread; gone, it watches nothing.
template <class T> class Observer : public ObserverBase {
public:
    Observer(Queries *cache, std::function<void(const Result<T> &)> changed) : m_cache(cache), m_changed(std::move(changed)) { cache->m_observers.insert(this); }
    ~Observer() override { try { if (m_cache) { stop(); m_cache->m_observers.remove(this); } } catch (...) { } }
    Observer(const Observer &) = delete;
    Observer &operator=(const Observer &) = delete;

    // Points it at `key`: fetched now unless its data is fresh. With `keepPrevious`, the data it showed
    // stays (`placeholder`) until this key has data of its own.
    void watch(const Key &key, Fetch<T> fn, const Options &options = Options(), bool keepPrevious = false) {
        if (!m_cache) return;
        const QString id = idOf(key);
        if (id != m_id) {
            if (keepPrevious) { if (const auto shown = result().data) m_held = shown; } else m_held.reset();
            detach();
        }
        Entry &e = m_cache->entry<T>(key, std::move(fn), options);
        if (id != m_id) { m_id = id; e.observers << this; ++e.left; }
        if (!m_cache->fresh(e)) m_cache->ask(e); else ++m_cache->m_counts.fresh;
        m_cache->dirty(e);
    }
    void stop() { detach(); m_held.reset(); m_told = Result<T>(); }
    // fetches what it watches again, whatever its age (a fetch under way is joined)
    void refetch() { if (const auto e = entry()) m_cache->ask(*e); }
    // tells what it shows once more on the next turn, changed or not (for one who may have missed it: Watch)
    void retell() { m_again = true; if (const auto e = entry()) m_cache->dirty(*e); }
    Result<T> result() const {
        Result<T> r;
        const auto e = entry();
        if (!e) return r;
        r.status = e->status; r.fetching = e->fetching; r.failures = e->failures;
        if (e->status == Error) r.error = e->error;
        r.data = std::static_pointer_cast<const T>(e->data);
        if (!r.data && e->status == Pending && m_held) { r.data = m_held; r.placeholder = true; }
        return r;
    }
    bool watching() const { return !m_id.isEmpty(); }
    bool watching(const Key &key) const { return m_id == idOf(key); }

private:
    std::shared_ptr<Entry> entry() const { return m_cache && !m_id.isEmpty() ? m_cache->m_entries.value(m_id) : nullptr; }
    void detach() {
        if (const auto e = entry()) m_cache->unobserve(*e, this);
        m_id.clear();
    }
    void changed() override {
        const Result<T> r = result();
        if (r.data && !r.placeholder) m_held.reset();
        if (r == m_told && !m_again) return;
        m_told = r; m_again = false;
        const auto changed = m_changed;     // (its own: the callback may be the end of this observer)
        if (changed) changed(r);
    }

    QPointer<Queries> m_cache;
    std::function<void(const Result<T> &)> m_changed;
    QString m_id;
    std::shared_ptr<const T> m_held;        // what it showed of the key before, for `placeholder`
    Result<T> m_told;                       // the last result it told of
    bool m_again = false;                   // to be told once more whatever it is (`retell`)
};

}  // namespace query
