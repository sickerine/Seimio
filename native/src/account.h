#pragma once
// The Stremio account for QML (the core does the work, see core.h): whether it is signed in and as whom,
// signing in with a code approved on a phone (as Stremio's own TV apps do), signing out, the library, and
// what the player reports.
//   link   { state: "" | "asking" | "waiting" | "failed", code, address, qr }, once `signIn()` is asked
//   watchingChanged()   Continue Watching or a title's watch state is new (Catalog takes them again)
//
// Watch progress is the core's Player model, the same rules as every other Stremio device of the account
// (docs/stremio-integration.md): the app says what plays and where it is (`playing`, `timeChanged`,
// `seeked`, `paused`, `stopped`), and the core decides what is watched, where Continue Watching resumes and
// when a series moves on to its next episode, and syncs it. A seek is said as a seek: time jumped over is
// not time watched.
#include <QSet>
#include <QThread>
#include <QTimer>
#include <QVariantMap>
#include <memory>
#include "core.h"

class Account : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool ready READ ready NOTIFY changed)            // the stored account is loaded
    Q_PROPERTY(bool signedIn READ signedIn NOTIFY changed)
    Q_PROPERTY(QString email READ email NOTIFY changed)
    Q_PROPERTY(QString avatar READ avatar NOTIFY changed)
    Q_PROPERTY(QVariantMap link READ link NOTIFY linkChanged)
    Q_PROPERTY(int libraryRevision READ libraryRevision NOTIFY libraryChanged)   // read with inLibrary() or watched(), so a binding follows
    // What a grid shows (`browse`): the library, or one of Discover's types ("movie", "series").
    //   browsing   { what, filters: [{ key, options: [names], current }], count, more, loading }
    //   items(from, n)   that many of its titles, as the screens show a title
    Q_PROPERTY(QVariantMap browsing READ browsing NOTIFY browsingChanged)
public:
    explicit Account(QObject *parent = nullptr) : QObject(parent) {
        Core *core = Core::instance();
        connect(core, &Core::readyChanged, this, [this] { refresh(); sync(); });
        connect(core, &Core::changed, this, [this](const QStringList &models) {
            if (models.contains("ctx")) refresh();
            if (models.contains("link")) linked();
            if (models.contains("continue_watching")) emit watchingChanged();
            if (models.contains(m_browse == "library" ? "library" : "discover") && !m_browse.isEmpty()) browsed();
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
    Q_INVOKABLE bool watched(const QString &id) const { return m_watched.contains(id); }

    QVariantMap browsing() const { return m_browsing; }
    Q_INVOKABLE QVariantList items(int from, int n) const { return m_items.mid(from, n); }
    Q_INVOKABLE void browse(const QString &what) {
        if (what == m_browse) return;
        m_browse = what; m_items.clear(); m_browsing = QVariantMap { { "what", what }, { "filters", QVariantList() }, { "count", 0 }, { "more", false }, { "loading", true } };
        emit browsingChanged();
        if (what.isEmpty()) return;
        // the library keeps the choice it had; Discover is asked for the type (a list and a genre are that type's)
        if (what != "library") Core::instance()->select("discover.type", what.toUtf8());
        else if (!m_libraryAsked) { m_libraryAsked = true; Core::instance()->select("library.sort", "0"); }
        else browsed();
    }
    Q_INVOKABLE void choose(const QString &filter, int option) {
        if (!m_browse.isEmpty()) Core::instance()->select(((m_browse == "library" ? "library." : "discover.") + filter).toUtf8(), QByteArray::number(option));
    }
    Q_INVOKABLE void more() {
        if (m_browse.isEmpty() || !m_browsing.value("more").toBool() || m_browsing.value("loading").toBool()) return;
        const bool library = m_browse == "library";
        Core::instance()->dispatch(library ? "library" : "discover", Core::action(library ? "LibraryWithFilters" : "CatalogWithFilters", Core::action("LoadNextPage")));
    }

    // asks for a code and waits for it to be approved; signed in, `signedIn` turns true
    Q_INVOKABLE void signIn() {
        Core::instance()->dispatch("link", Core::load("Link"));
        m_poll.start(); m_renew.start();
    }
    Q_INVOKABLE void cancelSignIn() { m_poll.stop(); m_renew.stop(); Core::instance()->dispatch("link", Core::action("Unload")); }
    Q_INVOKABLE void signOut() { ctx("Logout"); }
    // `item`: { id, type ("movie" | "series"), name, poster }
    Q_INVOKABLE void addToLibrary(const QVariantMap &item) { ctx("AddToLibrary", preview(item)); }
    Q_INVOKABLE void removeFromLibrary(const QString &id) { ctx("RemoveFromLibrary", id); }
    Q_INVOKABLE void markWatched(const QVariantMap &item, bool watched) {
        ctx("MetaItemMarkAsWatched", QJsonObject { { "meta_item", preview(item) }, { "is_watched", watched } });
    }

    // `videoId` as Stremio names it ("tt…:2:3", "kitsu:44081:9", a film's own id), `url` what plays
    Q_INVOKABLE void playing(const QString &videoId, const QString &type, const QString &url) {
        const bool film = type == "movie";
        const QString meta = film ? videoId : videoId.section(':', 0, videoId.startsWith("kitsu:") ? 1 : 0);
        const QString base = QString(meta.startsWith("kitsu:") ? "https://anime-kitsu.strem.fun" : "https://v3-cinemeta.strem.io") + "/manifest.json";
        auto request = [&](const char *resource, const QString &id) {
            return QJsonObject { { "base", base }, { "path", QJsonObject { { "resource", resource }, { "type", type }, { "id", id }, { "extra", QJsonArray() } } } };
        };
        Core::instance()->dispatch("player", Core::load("Player", QJsonObject { { "stream", QJsonObject { { "url", url } } },
            { "streamRequest", request("stream", videoId) }, { "metaRequest", request("meta", meta) }, { "subtitlesPath", QJsonValue() } }));
        m_reporting = true;
    }
    Q_INVOKABLE void timeChanged(double position, double duration) { at("TimeChanged", position, duration); }
    Q_INVOKABLE void seeked(double position, double duration) { at("Seek", position, duration); }
    Q_INVOKABLE void paused(bool paused) { if (m_reporting) Core::instance()->dispatch("player", Core::action("Player", Core::action("PausedChanged", QJsonObject { { "paused", paused } }))); }
    Q_INVOKABLE void stopped() { if (m_reporting) Core::instance()->dispatch("player", Core::action("Unload")); m_reporting = false; }

    // lab: an account's own email and password (a tour can't approve a code)
    Q_INVOKABLE void signInWith(const QString &email, const QString &password) {
        authenticate(QJsonObject { { "type", "Login" }, { "email", email }, { "password", password }, { "facebook", false } });
    }

signals:
    void changed();
    void linkChanged();
    void browsingChanged();
    void libraryChanged();
    void watchingChanged();

private:
    static void ctx(const char *action, const QJsonValue &args = QJsonValue(QJsonValue::Undefined)) { Core::instance()->dispatch("", Core::action("Ctx", Core::action(action, args))); }
    void authenticate(const QJsonObject &how) { ctx("Authenticate", how); }
    static QJsonObject preview(const QVariantMap &item) {
        QJsonObject o { { "id", item.value("id").toString() }, { "type", item.value("type").toString() }, { "name", item.value("name").toString() } };
        if (!item.value("poster").toString().isEmpty()) o["poster"] = item.value("poster").toString();
        return o;
    }
    void at(const char *action, double position, double duration) {
        if (!m_reporting || duration <= 0) return;
        Core::instance()->dispatch("player", Core::action("Player", Core::action(action, QJsonObject { { "time", qint64(position) }, { "duration", qint64(duration) }, { "device", "tv" } })));
    }
    // the account's addons and library as Stremio has them now (other devices change them)
    void sync() {
        if (!m_signedIn || Http::replaying()) return;
        for (const char *what : { "PullAddonsFromAPI", "SyncLibraryWithAPI" }) ctx(what);
    }
    void refresh() {
        const QJsonObject a = Core::view("account").object();
        m_signedIn = a.value("signedIn").toBool(); m_email = a.value("email").toString(); m_avatar = a.value("avatar").toString();
        QSet<QString> library, watched;
        for (const QJsonValue &v : Core::view("library").array()) {
            const QJsonObject i = v.toObject();
            if (!i.value("removed").toBool()) library << i.value("_id").toString();
            if (i.value("state").toObject().value("timesWatched").toInt() > 0) watched << i.value("_id").toString();
        }
        if (m_signedIn && m_poll.isActive()) cancelSignIn();
        emit changed();
        if (library != m_library || watched != m_watched) { m_library = library; m_watched = watched; m_revision++; emit libraryChanged(); }
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
    // The grid's page as the core has it now, read and shaped on a worker: a list of Cinemeta series is
    // half a megabyte of JSON.
    void browsed() {
        const QString what = m_browse;
        const int ticket = ++m_ticket;
        auto out = std::make_shared<QPair<QVariantMap, QVariantList>>();
        QThread *worker = QThread::create([out, what] {
            const QJsonObject page = Core::view(what == "library" ? "library.page" : "discover.page").object();
            QVariantList filters;
            for (const char *key : { "type", "sort", "list", "genre" }) {
                const QJsonArray options = page.value(key).toArray();
                if (options.isEmpty()) continue;
                QStringList names; int current = 0;
                for (int i = 0; i < options.size(); i++) { names << options[i].toObject().value("name").toString(); if (options[i].toObject().value("selected").toBool()) current = i; }
                filters << QVariantMap { { "key", key }, { "options", names }, { "current", current } };
            }
            for (const QJsonValue &v : page.value("items").toArray()) {
                const QJsonObject i = v.toObject();
                QStringList chips { i.value("year").toString(), i.value("runtime").toString() };
                const QJsonArray genres = i.value("genres").toArray();
                for (int g = 0; g < genres.size() && g < 2; g++) chips << genres[g].toString();
                chips.removeAll(QString());
                out->second << QVariantMap { { "id", i.value("id").toString() }, { "type", i.value("type").toString() }, { "name", i.value("name").toString() },
                    { "title", i.value("name").toString() }, { "art", i.value("poster").toString() }, { "poster", i.value("poster").toString() },
                    { "backdrop", i.value("backdrop").toString() }, { "logo", i.value("logo").toString() }, { "description", i.value("description").toString().left(220) },
                    { "chips", chips }, { "rating", i.value("rating").toString() }, { "episode", QString() }, { "progress", -1 } };
            }
            out->first = QVariantMap { { "what", what }, { "filters", filters }, { "count", out->second.size() },
                                       { "more", page.value("more").toBool() }, { "loading", page.value("loading").toBool() } };
        });
        connect(worker, &QThread::finished, this, [this, out, ticket] {
            if (ticket != m_ticket) return;                 // a newer page is on its way
            m_items = out->second; m_browsing = out->first;
            emit browsingChanged();
        });
        connect(worker, &QThread::finished, worker, &QObject::deleteLater);
        worker->start();
    }
    QString m_browse;
    QVariantMap m_browsing;
    QVariantList m_items;
    int m_ticket = 0;
    bool m_libraryAsked = false;
    bool m_signedIn = false, m_reporting = false;
    QString m_email, m_avatar;
    QVariantMap m_link;
    QSet<QString> m_library, m_watched;                    // ids in the library; ids watched (Stremio's `timesWatched`)
    int m_revision = 0;
    QTimer m_poll, m_renew;
};
