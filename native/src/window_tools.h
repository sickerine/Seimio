#pragma once
#include <QtQml>
#include <QWindow>
#include <QGuiApplication>
#include <qpa/qplatformnativeinterface.h>

// WindowTools: sets webOS window properties that LG's QML window type doesn't expose, such as
// _WEBOS_ACCESS_POLICY_KEYS_BACK, which decides whether Back reaches the app or opens the exit menu.
class WindowTools : public QObject {
    Q_OBJECT
public:
    Q_INVOKABLE QString setWindowProperty(QObject *window, const QString &name, const QString &value) {
        auto w = qobject_cast<QWindow *>(window);
        if (!w || !w->handle()) return "window not created yet";
        auto native = QGuiApplication::platformNativeInterface();
        if (!native) return "no native interface";
        native->setWindowProperty(w->handle(), name, value);
        return QString();
    }
    // every key press that reaches the window, before any control takes it: `keyPressed()`
    Q_INVOKABLE void watchKeys(QObject *window) { if (window) window->installEventFilter(this); }
    bool eventFilter(QObject *, QEvent *e) override { if (e->type() == QEvent::KeyPress) emit keyPressed(); return false; }
    Q_INVOKABLE QVariantMap windowProperties(QObject *window) {
        auto w = qobject_cast<QWindow *>(window);
        auto native = QGuiApplication::platformNativeInterface();
        return (w && w->handle() && native) ? native->windowProperties(w->handle()) : QVariantMap();
    }
signals:
    void keyPressed();
};
