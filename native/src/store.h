#pragma once
// A JSON object kept in a file in the app's data folder (/home/root/.local/share/com.seimio.tv on the
// TV), read on first use and written whole on each change. For small things: AI picks, track choices.
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStandardPaths>

class JsonStore {
public:
    explicit JsonStore(const QString &name) : m_name(name) {}
    QString path() const { return (m_dir.isEmpty() ? QStandardPaths::writableLocation(QStandardPaths::AppDataLocation) : m_dir) + "/" + m_name; }
    void setDir(const QString &dir) { m_dir = dir; }
    QJsonObject &data() {
        if (!m_read) { QFile f(path()); if (f.open(QIODevice::ReadOnly)) m_data = QJsonDocument::fromJson(f.readAll()).object(); m_read = true; }
        return m_data;
    }
    // writes the object; returns what happened, for the lab
    QString save() {
        QDir().mkpath(QFileInfo(path()).path());
        QFile f(path());
        return f.open(QIODevice::WriteOnly) && f.write(QJsonDocument(data()).toJson(QJsonDocument::Compact)) > 0
            ? "saved " + path() : "can't save to " + path() + ": " + f.errorString();
    }
private:
    QString m_name, m_dir;
    QJsonObject m_data;
    bool m_read = false;
};
