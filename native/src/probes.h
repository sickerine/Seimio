#pragma once
// Lab measurement: key latency, frame pacing on the render thread, and an in-process log tap.
#include <QtQml>
#include <QQuickWindow>
#include <QKeyEvent>
#include <QMutex>
#include <QLoggingCategory>
#include <time.h>

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
    static double monoMs() { timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }
    struct Pending { double eventTime, arrival; bool synced; };
    QVector<Pending> m_pending;
    QVector<double> m_fromArrival, m_fromEvent;
    QMutex m_mutex;
};

// FrameStats: time between swapped frames, stamped on the render thread (a QML handler would stamp
// them on the GUI thread, where its own work shows up as fake late frames), grouped by `phase`.
class FrameStats : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString phase READ phase WRITE setPhase)
public:
    QString phase() const { QMutexLocker l(&m_mutex); return m_phase; }
    void setPhase(const QString &p) { QMutexLocker l(&m_mutex); m_phase = p; }
    Q_INVOKABLE void attach(QObject *window) {
        auto w = qobject_cast<QQuickWindow *>(window);
        if (!w) return;
        connect(w, &QQuickWindow::frameSwapped, this, [this] {
            timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
            double now = t.tv_sec * 1e3 + t.tv_nsec / 1e6;
            QMutexLocker l(&m_mutex);
            if (m_last > 0) m_gaps[m_phase].append(now - m_last);
            m_last = now;
        }, Qt::DirectConnection);
    }
    // { phase: { frames, median, max, late20, late30, short12 } } since the last call
    Q_INVOKABLE QVariantMap take() {
        QMutexLocker l(&m_mutex);
        QVariantMap out;
        for (auto it = m_gaps.begin(); it != m_gaps.end(); ++it) {
            QVector<double> g = it.value(); std::sort(g.begin(), g.end());
            int l20 = 0, l30 = 0, s12 = 0;
            for (double x : g) { l20 += x > 20; l30 += x > 30; s12 += x < 12; }
            out[it.key()] = QVariantMap{ {"frames", g.size()}, {"median", g[g.size() / 2]}, {"max", g.last()},
                                         {"late20", l20}, {"late30", l30}, {"short12", s12} };
        }
        m_gaps.clear();
        return out;
    }
private:
    mutable QMutex m_mutex;
    QString m_phase = "idle";
    double m_last = 0;
    QMap<QString, QVector<double>> m_gaps;
};


// Captures Qt log output in-process (qml-runner sends it to PmLog, which dev mode can't read).
inline QStringList g_logLines;
inline QMutex g_logMutex;
class LogTap : public QObject {
    Q_OBJECT
public:
    Q_INVOKABLE void start(const QString &rules) {
        QLoggingCategory::setFilterRules(rules);
        qInstallMessageHandler([](QtMsgType, const QMessageLogContext &ctx, const QString &msg) {
            QMutexLocker l(&g_logMutex);
            g_logLines << QString("%1 %2").arg(ctx.category ? ctx.category : "").arg(msg);
        });
    }
    Q_INVOKABLE QStringList take() { QMutexLocker l(&g_logMutex); QStringList out = g_logLines; g_logLines.clear(); return out; }
};
