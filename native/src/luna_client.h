#pragma once
// LunaClient: calls webOS Luna services from QML through luna-service2 directly. LG's QML Service type
// can't register on the bus from a dev-mode app; an anonymous registration from here can.
#include <QtQml>
#include "lg/luna.h"

class LunaClient : public QObject {
    Q_OBJECT
public:
    // Registers on the bus under `name` (empty = anonymous). Returns "" or the error.
    Q_INVOKABLE QString init(const QString &name) {
        LSError e; LSErrorInit(&e);
        QByteArray n = name.toUtf8();
        if (!LSRegister(name.isEmpty() ? nullptr : n.constData(), &m_handle, &e)) return err(e);
        if (!LSGmainContextAttach(m_handle, g_main_context_default(), &e)) return err(e);
        return QString();
    }
    Q_INVOKABLE QString name() const { return m_handle ? QString::fromUtf8(LSHandleGetName(m_handle)) : QString(); }
    // Returns the call token, or -1 with lastError set.
    Q_INVOKABLE double call(const QString &uri, const QString &payload) {
        if (!m_handle) { m_lastError = "not registered"; return -1; }
        LSError e; LSErrorInit(&e);
        LSMessageToken token = 0;
        if (!LSCall(m_handle, uri.toUtf8().constData(), payload.toUtf8().constData(), &LunaClient::reply, this, &token, &e)) { m_lastError = err(e); return -1; }
        return double(token);
    }
    Q_INVOKABLE void cancel(double token) {
        if (!m_handle) return;
        LSError e; LSErrorInit(&e);
        if (!LSCallCancel(m_handle, LSMessageToken(token), &e)) LSErrorFree(&e);
    }
    Q_INVOKABLE QString lastError() const { return m_lastError; }
signals:
    void response(double token, const QString &payload);
private:
    static bool reply(LSHandle *, LSMessage *msg, void *ctx) {
        auto self = static_cast<LunaClient *>(ctx);
        emit self->response(double(LSMessageGetResponseToken(msg)), QString::fromUtf8(LSMessageGetPayload(msg)));
        return true;
    }
    static QString err(LSError &e) { QString s = QString::fromUtf8(e.message ? e.message : "unknown"); LSErrorFree(&e); return s; }
    LSHandle *m_handle = nullptr;
    QString m_lastError;
};
