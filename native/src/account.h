#pragma once
// The Stremio account for QML (the core does the work, see core.h): whether it is signed in and as whom,
// signing in with a code approved on a phone (as Stremio's own TV apps do), signing out, and which titles
// are in the library.
//   link   { state: "" | "asking" | "waiting" | "failed", code, address, qr }, once `signIn()` is asked
//   watchingChanged()   Continue Watching or a title's watch state is new (Catalog takes them again)
#include <QSet>
#include <QTimer>
#include <QVariantMap>
#include "core.h"

class Account : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool ready READ ready NOTIFY changed)            // the stored account is loaded
    Q_PROPERTY(bool signedIn READ signedIn NOTIFY changed)
    Q_PROPERTY(QString email READ email NOTIFY changed)
    Q_PROPERTY(QString avatar READ avatar NOTIFY changed)
    Q_PROPERTY(QVariantMap link READ link NOTIFY linkChanged)
    Q_PROPERTY(int libraryRevision READ libraryRevision NOTIFY libraryChanged)   // read with inLibrary(), so a binding follows
public:
    explicit Account(QObject *parent = nullptr) : QObject(parent) {
        Core *core = Core::instance();
        connect(core, &Core::readyChanged, this, [this] { refresh(); sync(); });
        connect(core, &Core::changed, this, [this](const QStringList &models) {
            if (models.contains("ctx")) refresh();
            if (models.contains("link")) linked();
            if (models.contains("continue_watching")) emit watchingChanged();
        });
        connect(core, &Core::event, this, [this](const QString &name, const QJsonObject &) { if (name == "UserAuthenticated") sync(); });
        // an unapproved code answers "not yet" until it is approved; a code left on screen is renewed
        m_poll.setInterval(3000);
        connect(&m_poll, &QTimer::timeout, this, [this] { if (m_link.value("state") == "waiting") Core::instance()->dispatch("link", Core::action("Link", Core::action("ReadData"))); });
        m_renew.setInterval(10 * 60 * 1000);
        connect(&m_renew, &QTimer::timeout, this, &Account::signIn);
        core->start();
        if (core->ready()) refresh();
    }
    bool ready() const { return Core::instance()->ready(); }
    bool signedIn() const { return m_signedIn; }
    QString email() const { return m_email; }
    QString avatar() const { return m_avatar; }
    QVariantMap link() const { return m_link; }
    int libraryRevision() const { return m_revision; }
    Q_INVOKABLE bool inLibrary(const QString &id) const { return m_library.contains(id); }

    // asks for a code and waits for it to be approved; signed in, `signedIn` turns true
    Q_INVOKABLE void signIn() {
        Core::instance()->dispatch("link", Core::load("Link"));
        m_poll.start(); m_renew.start();
    }
    Q_INVOKABLE void cancelSignIn() { m_poll.stop(); m_renew.stop(); Core::instance()->dispatch("link", Core::action("Unload")); }
    Q_INVOKABLE void signOut() { Core::instance()->dispatch("", Core::action("Ctx", Core::action("Logout"))); }
    // lab: an account's own email and password (a tour can't approve a code)
    Q_INVOKABLE void signInWith(const QString &email, const QString &password) {
        authenticate(QJsonObject { { "type", "Login" }, { "email", email }, { "password", password }, { "facebook", false } });
    }

signals:
    void changed();
    void linkChanged();
    void libraryChanged();
    void watchingChanged();

private:
    void authenticate(const QJsonObject &how) { Core::instance()->dispatch("", Core::action("Ctx", Core::action("Authenticate", how))); }
    // the account's addons and library as Stremio has them now (other devices change them)
    void sync() {
        if (!m_signedIn || Http::replaying()) return;
        for (const char *what : { "PullAddonsFromAPI", "SyncLibraryWithAPI" }) Core::instance()->dispatch("", Core::action("Ctx", Core::action(what)));
    }
    void refresh() {
        const QJsonObject a = Core::view("account").object();
        m_signedIn = a.value("signedIn").toBool(); m_email = a.value("email").toString(); m_avatar = a.value("avatar").toString();
        QSet<QString> library;
        for (const QJsonValue &v : Core::view("library").array()) if (!v.toObject().value("removed").toBool()) library << v.toObject().value("_id").toString();
        if (m_signedIn && m_poll.isActive()) cancelSignIn();
        emit changed();
        if (library != m_library) { m_library = library; m_revision++; emit libraryChanged(); }
    }
    void linked() {
        const QJsonObject l = Core::state("link").object(), code = l.value("code").toObject(), data = l.value("data").toObject();
        if (data.value("type") == "Ready") {                     // approved: its key signs the app in
            authenticate(QJsonObject { { "type", "LoginWithToken" }, { "token", data.value("content").toObject().value("authKey") } });
            return;
        }
        const QString type = code.value("type").toString();
        QVariantMap link;
        if (type == "Ready") {
            const QJsonObject c = code.value("content").toObject();
            link = { { "state", "waiting" }, { "code", c.value("code").toString() }, { "qr", c.value("qrcode").toString() },
                     { "address", c.value("link").toString().remove("https://").section('/', 0, 0) } };
        } else if (type == "Loading") link = { { "state", "asking" } };
        else if (type == "Err") { link = { { "state", "failed" } }; QTimer::singleShot(5000, this, [this] { if (m_link.value("state") == "failed") signIn(); }); }
        if (link != m_link) { m_link = link; emit linkChanged(); }
    }
    bool m_signedIn = false;
    QString m_email, m_avatar;
    QVariantMap m_link;
    QSet<QString> m_library;
    int m_revision = 0;
    QTimer m_poll, m_renew;
};
