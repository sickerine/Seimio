#pragma once
// Lab measurement: key latency, frame pacing on the render thread, and an in-process log tap.
#include <QtQml>
#include <QQuickWindow>
#include <QKeyEvent>
#include <QMutex>
#include <QTimer>
#include <QLoggingCategory>
#include <time.h>
#include <atomic>

inline double monoMs() { timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }
inline double threadCpuMs() { timespec t; clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }

// The lab log: Qt's log output (once LogTap starts) and the probes' own events, each stamped with
// monoMs(), so a slow frame can be lined up with the key press or GUI stall behind it.
inline QStringList g_logLines;
inline QMutex g_logMutex;
inline std::atomic<bool> g_logOn{false};      // set on the GUI thread, read on the render thread
inline void labLog(const QString &line) {
    if (!g_logOn) return;
    QMutexLocker l(&g_logMutex);
    g_logLines << QString::number(monoMs(), 'f', 1) + " " + line;
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
// anything draws, and a tick more than 50 ms late is a stall of that length, however long. One that ends
// just after a slow swap (over 30 ms: the TV's compositor, over video) was the GUI thread waiting to
// hand over the next frame, not our work: it's logged as such and not counted.
class FrameStats : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString phase READ phase WRITE setPhase)
    Q_PROPERTY(bool heartbeat READ heartbeat WRITE setHeartbeat)
public:
    FrameStats() {
        m_beat.setTimerType(Qt::PreciseTimer); m_beat.setInterval(16);
        connect(&m_beat, &QTimer::timeout, this, [this] {
            const double now = monoMs(), gap = now - m_lastBeat, cpu = threadCpuMs(), worked = cpu - m_lastCpu;
            m_lastBeat = now; m_lastCpu = cpu;
            if (gap <= 50) return;
            QMutexLocker l(&m_mutex);
            if (now - m_slowSwap < 15) { labLog(QString("gui waited on a slow swap %1 ms").arg(gap, 0, 'f', 1)); return; }
            m_stalls[m_phase].append(gap);
            // `busy`: the GUI thread's own CPU time in the gap; far less than the gap means it was blocked
            // or starved by other threads and processes, not running our code
            labLog(QString("gui stall %1 ms busy %2").arg(gap, 0, 'f', 1).arg(worked, 0, 'f', 0));
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
    void setPhase(const QString &p) { QMutexLocker l(&m_mutex); m_phase = p; }
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
};


// Captures Qt log output in-process (qml-runner sends it to PmLog, which dev mode can't read).
class LogTap : public QObject {
    Q_OBJECT
public:
    Q_INVOKABLE void start(const QString &rules) {
        QLoggingCategory::setFilterRules(rules);
        g_logOn = true;
        qInstallMessageHandler([](QtMsgType, const QMessageLogContext &ctx, const QString &msg) {
            labLog(QString("%1 %2").arg(ctx.category ? ctx.category : "").arg(msg));
        });
    }
    Q_INVOKABLE QStringList take() { QMutexLocker l(&g_logMutex); QStringList out = g_logLines; g_logLines.clear(); return out; }
};
