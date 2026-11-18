#pragma once
// Lab measurement: key latency, frame pacing on the render thread, and an in-process log tap.
#include <QtQml>
#include <QQuickWindow>
#include <QKeyEvent>
#include <QMutex>
#include <QTimer>
#include <QLoggingCategory>
#include <QThread>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <time.h>
#include <atomic>
#include <thread>
#include <csignal>
#include <cerrno>
#include <cstring>
#include <cxxabi.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <fcntl.h>
#include <pthread.h>
#include <ucontext.h>
#include <unistd.h>
#include <sys/syscall.h>

inline double monoMs() { timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }
inline double threadCpuMs() { timespec t; clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }

// The lab log: Qt's log output (once LogTap starts) and the probes' own events, each as
// "phase | monoMs() line", so a slow frame can be lined up with the key press or GUI stall behind it
// and with what was animating then.
inline QStringList g_logLines;
inline QString g_logPhase = "idle";           // FrameStats' phase (under g_logMutex)
inline QMutex g_logMutex;
inline std::atomic<bool> g_logOn{false};      // set on the GUI thread, read on the render thread
inline void labLog(const QString &line, double at = monoMs()) {
    if (!g_logOn) return;
    QMutexLocker l(&g_logMutex);
    g_logLines << g_logPhase + " | " + QString::number(at, 'f', 1) + " " + line;
}

// Where the GUI thread's time goes (LogTap.sample): every 4 ms a watcher looks at whether the GUI thread
// is running (its state in /proc) and, if it is, signals it; the handler notes where it was (the program
// counter, the caller and the call stack). The watcher names the frames and logs each as
// "stack leaf < caller < ...", stamped with when it was taken, so a GUI stall can be read as what ran in
// it (tools/lab-stacks.py). A GUI thread at rest is never interrupted.
// For lab runs only, behind its switch: walking the stack inside a signal handler is not safe everywhere
// (a thread stopped inside the loader or the allocator can hang there), and the app never does it unasked.
// With the window given, the render thread is sampled the same way (its lines start "rstack"): what the
// renderer does in a frame that takes too long.
struct GuiSample { double at; int count; void *frames[20]; };
inline GuiSample g_samples[2][256];           // the GUI thread's and the render thread's: one writer each
inline std::atomic<int> g_sampled[2];
inline pthread_t g_guiThread;
inline void guiSampled(int, siginfo_t *, void *context) {
    const int error = errno, ring = pthread_equal(pthread_self(), g_guiThread) ? 0 : 1;
    GuiSample &s = g_samples[ring][g_sampled[ring].load(std::memory_order_relaxed) & 255];
    const auto *machine = &static_cast<ucontext_t *>(context)->uc_mcontext;
    s.at = monoMs();
    s.frames[0] = reinterpret_cast<void *>(machine->arm_pc);
    s.frames[1] = reinterpret_cast<void *>(machine->arm_lr);
    // (the render thread: where it is and its caller only; unwinding through the GPU driver crashed the app)
    s.count = ring ? 2 : 2 + backtrace(s.frames + 2, 18);
    g_sampled[ring].fetch_add(1, std::memory_order_release);
    errno = error;
}
inline void logGuiSample(const GuiSample &s, const char *label) {
    QStringList names;
    for (int i = 0; i < s.count && names.size() < 14; i++) {
        Dl_info info;
        QString name = "?";                                  // code no library holds: JavaScript the engine compiled
        if (dladdr(s.frames[i], &info) && info.dli_fname) {
            int failed = 0;
            char *plain = info.dli_sname ? abi::__cxa_demangle(info.dli_sname, nullptr, nullptr, &failed) : nullptr;
            name = info.dli_sname ? QString::fromLatin1(plain && !failed ? plain : info.dli_sname).section('(', 0, 0) : QString::fromLocal8Bit(info.dli_fname).section('/', -1);
            free(plain);
        }
        // the handler's own frames, and a frame named twice (the program counter is also the stack's first)
        if (name != "guiSampled" && !name.contains("sa_restorer") && (names.isEmpty() || names.last() != name)) names << name;
    }
    labLog(label + names.join(" < "), s.at);
}

// KeyLatency: for each key press, the time from the key reaching the app (and from the compositor's
// event timestamp) to the first frame swapped after a scene sync that includes the key's changes.
class KeyLatency : public QObject {
    Q_OBJECT
public:
    Q_INVOKABLE void attach(QObject *window) {
        auto w = qobject_cast<QQuickWindow *>(window);
        if (!w) return;
        w->installEventFilter(this);
        connect(w, &QQuickWindow::beforeSynchronizing, this, [this] {   // render thread, GUI blocked
            QMutexLocker l(&m_mutex);
            for (auto &p : m_pending) p.synced = true;
        }, Qt::DirectConnection);
        connect(w, &QQuickWindow::frameSwapped, this, [this] {           // render thread
            double now = monoMs();
            QMutexLocker l(&m_mutex);
            for (int i = m_pending.size() - 1; i >= 0; i--) {
                if (!m_pending[i].synced) continue;
                m_fromArrival << now - m_pending[i].arrival;
                m_fromEvent << now - m_pending[i].eventTime;
                m_pending.removeAt(i);
            }
        }, Qt::DirectConnection);
    }
    bool eventFilter(QObject *, QEvent *e) override {
        if (e->type() == QEvent::KeyPress) {
            QMutexLocker l(&m_mutex);
            m_pending.append({ double(static_cast<QKeyEvent *>(e)->timestamp()), monoMs(), false });
            labLog(QString("key %1").arg(static_cast<QKeyEvent *>(e)->key(), 0, 16));
        }
        return false;
    }
    Q_INVOKABLE QString stats() {
        QMutexLocker l(&m_mutex);
        auto line = [](QVector<double> v) {
            if (v.isEmpty()) return QString("none");
            std::sort(v.begin(), v.end());
            return QString("n %1 median %2 p90 %3 max %4").arg(v.size()).arg(v[v.size() / 2], 0, 'f', 1)
                .arg(v[v.size() * 9 / 10], 0, 'f', 1).arg(v.last(), 0, 'f', 1);
        };
        QString s = "from app arrival: " + line(m_fromArrival) + " | from input event: " + line(m_fromEvent);
        m_fromArrival.clear(); m_fromEvent.clear();
        return s;
    }
private:
    struct Pending { double eventTime, arrival; bool synced; };
    QVector<Pending> m_pending;
    QVector<double> m_fromArrival, m_fromEvent;
    QMutex m_mutex;
};

// FrameStats: time between swapped frames, stamped on the render thread (a QML handler would stamp
// them on the GUI thread, where its own work shows up as fake late frames), grouped by `phase`.
// Frame gaps can't tell a long stall from a pause in drawing, so GUI stalls are measured apart: with
// `heartbeat` on (the lab sets it during tours), a 16 ms timer on the GUI thread ticks whether or not
// anything draws, and a tick more than 50 ms late is a stall of that length, however long. Time the GUI
// thread spent waiting to hand a frame to the render thread is not our work and comes off it: a tick that
// ends just after a slow swap (over 30 ms: the TV's compositor, over video), and the wait measured at each
// hand-over (afterSynchronizing). Both are logged as waits and not counted.
class FrameStats : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString phase READ phase WRITE setPhase)
    Q_PROPERTY(bool heartbeat READ heartbeat WRITE setHeartbeat)
public:
    FrameStats() {
        m_beat.setTimerType(Qt::PreciseTimer); m_beat.setInterval(16);
        connect(&m_beat, &QTimer::timeout, this, [this] {
            const double now = monoMs(), gap = now - m_lastBeat, cpu = threadCpuMs(), worked = cpu - m_lastCpu;
            const double stall = gap - m_handing.exchange(0);       // less what it waited handing frames over
            m_lastBeat = now; m_lastCpu = cpu;
            if (gap <= 50) return;
            QMutexLocker l(&m_mutex);
            if (now - m_slowSwap < 15) { labLog(QString("gui waited on a slow swap %1 ms").arg(gap, 0, 'f', 1)); return; }
            if (stall <= 50) { labLog(QString("gui waited %1 ms of %2 to hand a frame over, busy %3").arg(gap - stall, 0, 'f', 1).arg(gap, 0, 'f', 1).arg(worked, 0, 'f', 0)); return; }
            m_stalls[m_phase].append(stall);
            // `busy`: the GUI thread's own CPU time in the gap; far less than the gap means it was blocked
            // or starved by other threads and processes, not running our code
            labLog(QString("gui stall %1 ms busy %2").arg(stall, 0, 'f', 1).arg(worked, 0, 'f', 0));
        });
    }
    bool heartbeat() const { return m_beat.isActive(); }
    // the app's resident memory in MB (Linux /proc; 0 elsewhere)
    Q_INVOKABLE int rssMb() const {
        QFile f("/proc/self/statm");
        if (!f.open(QIODevice::ReadOnly)) return 0;
        const QList<QByteArray> v = f.readAll().split(' ');
        return v.size() > 1 ? int(v[1].toLongLong() * 4096 / (1 << 20)) : 0;
    }
    void setHeartbeat(bool on) { if (on == m_beat.isActive()) return; m_lastBeat = monoMs(); m_lastCpu = threadCpuMs(); if (on) m_beat.start(); else m_beat.stop(); }
    QString phase() const { QMutexLocker l(&m_mutex); return m_phase; }
    void setPhase(const QString &p) { QMutexLocker l(&m_mutex); m_phase = p; QMutexLocker g(&g_logMutex); g_logPhase = p; }
    Q_INVOKABLE void attach(QObject *window) {
        auto w = qobject_cast<QQuickWindow *>(window);
        if (!w) return;
        connect(w, &QQuickWindow::afterRendering, this, [this] { m_rendered = monoMs(); }, Qt::DirectConnection);   // render thread
        connect(w, &QQuickWindow::frameSwapped, this, [this] {
            double now = monoMs();
            QMutexLocker l(&m_mutex);
            if (now - m_rendered > 30) m_slowSwap = now;
            // Qt draws only when something changes. A frame is late when it breaks a run of frames (the one
            // before it came on time); one that follows a pause (nothing animating, a subtitle waiting for its
            // next line, a key press after a moment) only shows when something next changed
            const double gap = now - m_last;
            if (m_last > 0 && m_lastGap > 0 && m_lastGap <= 20 && gap < 150) {
                m_gaps[m_phase].append(gap);
                if (gap > 20) labLog(QString("late frame %1 ms").arg(gap, 0, 'f', 1));
            }
            m_lastGap = m_last > 0 ? gap : 0;
            m_last = now;
        }, Qt::DirectConnection);
        // GUI thread: a long wait between two animation ticks means key handling, JS or item creation
        // held the GUI thread up
        connect(w, &QQuickWindow::afterAnimating, this, [this] {
            double now = monoMs(), cpu = threadCpuMs();
            // the same for the GUI thread: a stall breaks a run of on-time ticks; a tick after a pause doesn't
            const double tick = now - m_lastTick;
            if (m_lastTick > 0 && m_lastTickGap > 0 && m_lastTickGap <= 20 && tick > 20 && tick < 150)
                labLog(QString("gui stall %1 ms busy %2").arg(tick, 0, 'f', 1).arg(cpu - m_lastTickCpu, 0, 'f', 0));
            m_lastTickGap = m_lastTick > 0 ? tick : 0;
            m_lastTick = now; m_lastTickCpu = cpu;
            m_handFrom = now; m_handCpu = cpu;
        }, Qt::DirectConnection);
        // Render thread, the GUI thread still blocked: how long it has waited to hand this frame over, which
        // is the time since its animation tick less what it worked in it (polishing). With something
        // animating on the render thread (Ambient, at rest) the render loop runs by itself and the GUI
        // thread waits for the frame in hand to finish, up to two frames; that wait isn't a stall.
        pthread_getcpuclockid(pthread_self(), &m_guiClock);
        connect(w, &QQuickWindow::afterSynchronizing, this, [this] {
            timespec t; clock_gettime(m_guiClock, &t);
            const double from = m_handFrom.exchange(0), waited = monoMs() - from - (t.tv_sec * 1e3 + t.tv_nsec / 1e6 - m_handCpu);
            if (from > 0 && waited > 0) m_handing = m_handing + waited;
        }, Qt::DirectConnection);
    }
    // { phase: { frames, median, max, late20, late30, short12, stalls, stallMax } } since the last call
    Q_INVOKABLE QVariantMap take() {
        QMutexLocker l(&m_mutex);
        QVariantMap out;
        for (auto it = m_stalls.begin(); it != m_stalls.end(); ++it) if (!m_gaps.contains(it.key())) m_gaps[it.key()];
        for (auto it = m_gaps.begin(); it != m_gaps.end(); ++it) {
            QVector<double> g = it.value(); std::sort(g.begin(), g.end());
            int l20 = 0, l30 = 0, s12 = 0;
            for (double x : g) { l20 += x > 20; l30 += x > 30; s12 += x < 12; }
            const QVector<double> st = m_stalls.value(it.key());
            out[it.key()] = QVariantMap{ {"frames", g.size()}, {"median", g.isEmpty() ? 0 : g[g.size() / 2]}, {"max", g.isEmpty() ? 0 : g.last()},
                                         {"late20", l20}, {"late30", l30}, {"short12", s12},
                                         {"stalls", st.size()}, {"stallMax", st.isEmpty() ? 0 : *std::max_element(st.begin(), st.end())} };
        }
        m_gaps.clear(); m_stalls.clear();
        return out;
    }
private:
    mutable QMutex m_mutex;
    QString m_phase = "idle";
    double m_last = 0, m_lastGap = 0;
    double m_lastTick = 0, m_lastTickGap = 0; double m_lastTickCpu = 0;
    QMap<QString, QVector<double>> m_gaps, m_stalls;
    QTimer m_beat;
    double m_lastBeat = 0; double m_lastCpu = 0;
    std::atomic<double> m_rendered { 0 };
    double m_slowSwap = 0;                  // when the last slow swap ended (under m_mutex)
    clockid_t m_guiClock = 0;               // the GUI thread's CPU time, readable from the render thread
    std::atomic<double> m_handFrom { 0 }, m_handCpu { 0 };      // the animation tick a hand-over starts from
    std::atomic<double> m_handing { 0 };    // time waited handing frames over since the last heartbeat
};


// Captures Qt log output in-process (qml-runner sends it to PmLog, which dev mode can't read).
// watch() is always on: it keeps the warnings and errors (a handler that threw, a binding reading
// nothing: silent on the TV otherwise, where a broken handler just does nothing), which costs nothing
// while nothing goes wrong, and passes every message on as before. An image that isn't there is not
// one of them: art goes missing all the time. start(rules) is the lab's switch: every line of the
// categories asked for (Qt's per-frame render timing), which does perturb the frames it times.
inline QStringList g_errorLines;
inline QtMessageHandler g_handlerBefore = nullptr;
class LogTap : public QObject {
    Q_OBJECT
public:
    Q_INVOKABLE void watch() {
        if (g_handlerBefore) return;
        g_handlerBefore = qInstallMessageHandler([](QtMsgType type, const QMessageLogContext &ctx, const QString &msg) {
            labLog(QString("%1 %2").arg(ctx.category ? ctx.category : "").arg(msg));
            // not ours to fix: art that isn't there, LG's platform announcing the video window, and Qt's
            // network code complaining about itself when a reply is aborted as it fails
            static const QStringList noise { "QML Image:", "[Client:", "QNetworkReplyImplPrivate::error", "libpng warning" };
            bool ours = type != QtDebugMsg && type != QtInfoMsg;
            for (const QString &n : noise) ours = ours && !msg.contains(n);
            if (ours) {
                QMutexLocker l(&g_logMutex);
                if (g_errorLines.size() < 200) g_errorLines << msg;
            }
            if (g_handlerBefore) g_handlerBefore(type, ctx, msg);
        });
    }
    Q_INVOKABLE void start(const QString &rules) { QLoggingCategory::setFilterRules(rules); g_logOn = true; watch(); }
    // Posts the lines logged since the last call to `url` as { "log": [...] }, from a thread of its own:
    // as part of LabProbe's report they were turned into JSON by the GUI thread, 30 ms of it every
    // report on the TV, so a run that timed stalls measured one of its own every three seconds.
    Q_INVOKABLE void send(const QString &url) {
        QStringList lines; { QMutexLocker l(&g_logMutex); lines.swap(g_logLines); }
        if (lines.isEmpty()) return;
        if (!m_poster) {
            m_poster = new QObject; m_poster->moveToThread(&m_thread);
            connect(&m_thread, &QThread::finished, m_poster, &QObject::deleteLater);
            m_thread.start();
        }
        QMetaObject::invokeMethod(m_poster, [this, lines, url] {
            if (!m_net) m_net = new QNetworkAccessManager(m_poster);
            QNetworkRequest request{QUrl(url)};
            request.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
            QNetworkReply *reply = m_net->post(request, QJsonDocument(QJsonObject{{"log", QJsonArray::fromStringList(lines)}}).toJson(QJsonDocument::Compact));
            connect(reply, &QNetworkReply::finished, reply, &QObject::deleteLater);
        });
    }
    Q_INVOKABLE QStringList errors() { QMutexLocker l(&g_logMutex); QStringList out = g_errorLines; g_errorLines.clear(); return out; }
    // starts sampling the GUI thread (the thread this is called on) into the log, and the window's render
    // thread too if one is given; see guiSampled
    Q_INVOKABLE void sample(QObject *window = nullptr) {
        if (m_sampling.exchange(true)) return;
        void *warm[2]; backtrace(warm, 2);                  // loads the unwinder now, not inside the handler
        struct sigaction action {};
        action.sa_sigaction = guiSampled; action.sa_flags = SA_SIGINFO | SA_RESTART;
        sigaction(SIGPROF, &action, nullptr);
        g_guiThread = pthread_self();
        const long gui = syscall(SYS_gettid);
        if (auto w = qobject_cast<QQuickWindow *>(window))
            connect(w, &QQuickWindow::beforeRendering, this, [this] { if (!m_renderId) { m_render = pthread_self(); m_renderId = syscall(SYS_gettid); } }, Qt::DirectConnection);
        m_sampler = std::thread([this, gui] {
            // a thread's state follows its name in brackets in its stat: R while it runs
            auto running = [](long thread) {
                char line[256] = {0};
                const int fd = open(("/proc/self/task/" + QByteArray::number(qlonglong(thread)) + "/stat").constData(), O_RDONLY);
                if (fd >= 0) { if (read(fd, line, sizeof line - 1) < 0) line[0] = 0; close(fd); }
                const char *name = strrchr(line, ')');
                return name && name[1] && name[2] == 'R';
            };
            for (int logged[2] = {0, 0}; m_sampling; ) {
                usleep(4000);
                if (running(gui)) pthread_kill(g_guiThread, SIGPROF);
                if (m_renderId && running(m_renderId)) pthread_kill(m_render, SIGPROF);
                for (int ring = 0; ring < 2; ring++)
                    for (; logged[ring] != g_sampled[ring].load(std::memory_order_acquire); logged[ring]++) logGuiSample(g_samples[ring][logged[ring] & 255], ring ? "rstack " : "stack ");
            }
        });
    }
    ~LogTap() { m_thread.quit(); m_thread.wait(); if (m_sampling.exchange(false)) m_sampler.join(); }
private:
    std::atomic<bool> m_sampling{false};
    std::thread m_sampler;
    pthread_t m_render {};                      // the render thread, once it has drawn a frame
    std::atomic<long> m_renderId{0};
    QThread m_thread;
    QObject *m_poster = nullptr;
    QNetworkAccessManager *m_net = nullptr;     // the poster's thread only
};
