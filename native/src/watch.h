#pragma once
// Watch: an observer of a query (query.h) for something that lives on another thread than the cache. The
// screens' side lives on the GUI thread, the cache and everything fetched on the data thread: a Watch is
// held on the one, does its watching on the other, and says what it shows on its holder's thread.
//
// The one thing two threads add is that an answer can be on its way across while the holder has already
// asked for something else. A Watch numbers what it asks for, and a result that crosses over for an
// earlier asking is dropped here, once, for everything that watches: the holder hears only of the key it
// watches now, and hears of it after every asking. (tools/tests/native/tst_watch.cpp)
#include <QCoreApplication>
#include <QPointer>
#include <atomic>
#include <memory>
#include "query.h"

template <class T> class Watch {
public:
    // `cache`: the other thread's; `changed(result)` is called on the thread of `holder`, never from inside
    // a call of the holder's own, and no more once the Watch or the holder is gone
    Watch(query::Queries *cache, QObject *holder, std::function<void(const query::Result<T> &)> changed)
        : m_cache(cache), m_holder(holder), m_far(std::make_shared<Far>()), m_near(std::make_shared<Near>()) {
        m_near->changed = std::move(changed);
    }
    ~Watch() {
        m_near->alive = false;
        // the observer goes where it lives; a cache that is gone has taken its thread's work with it
        try { if (m_cache) QMetaObject::invokeMethod(m_cache, [far = m_far] { far->observer.reset(); }, Qt::QueuedConnection); } catch (...) { }
    }
    Watch(const Watch &) = delete;
    Watch &operator=(const Watch &) = delete;

    // Points it at `key` (query::Observer::watch): `fn` runs on the cache's thread.
    void watch(const query::Key &key, query::Fetch<T> fn, const query::Options &options = query::Options(), bool keepPrevious = false) {
        const quint64 asking = ++m_near->asking;
        act([far = m_far, near = m_near, holder = m_holder, cache = m_cache, asking, key, fn, options, keepPrevious] {
            far->asking = asking;
            // (the observer is the far side's, so its callback only looks at the far side: holding it would
            // keep the two alive by each other when the cache's thread ends before the Watch does)
            if (!far->observer) far->observer.reset(new query::Observer<T>(cache, [look = std::weak_ptr<Far>(far), near, holder](const query::Result<T> &r) {
                const auto far = look.lock();
                if (!far) return;
                const quint64 asked = far->asking;
                if (holder) QMetaObject::invokeMethod(holder, [near, asked, r] {
                    if (near->alive && asked == near->asking && near->changed) near->changed(r);
                }, Qt::QueuedConnection);
            }));
            far->observer->watch(key, fn, options, keepPrevious);
            // Every asking is answered, the same key asked for again too: its result may be on its way
            // across under the number before, where it is dropped, and the observer, showing what it
            // showed, would have nothing new to tell.
            far->observer->retell();
        });
    }
    // watches nothing: what was on its way is dropped
    void stop() {
        ++m_near->asking;
        act([far = m_far] { if (far->observer) far->observer->stop(); });
    }
    // fetches what it watches again, whatever its age
    void refetch() { act([far = m_far] { if (far->observer) far->observer->refetch(); }); }

private:
    struct Far { std::unique_ptr<query::Observer<T>> observer; quint64 asking = 0; };          // the cache's thread's
    struct Near { std::atomic<quint64> asking { 0 }; std::atomic<bool> alive { true }; std::function<void(const query::Result<T> &)> changed; };
    template <class F> void act(F f) { if (m_cache) QMetaObject::invokeMethod(m_cache, f, Qt::QueuedConnection); }

    QPointer<query::Queries> m_cache;
    QPointer<QObject> m_holder;
    std::shared_ptr<Far> m_far;
    std::shared_ptr<Near> m_near;
};
