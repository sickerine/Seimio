#pragma once
// Seimio.Data: the app's data held natively, outside QML's JavaScript heap. QML asks for what a screen
// needs when it needs it (one show's seasons, one day's releases), so the JS heap stays small (the
// engine's stop-the-world GC takes longer the more is alive) and nothing is parsed on the GUI thread.
//
// Catalog's data comes live from the services when the app starts (Live, live.h), parsed on a worker thread;
// only the Stremio account is a stand-in for now. CalendarModel is the month grid's model.
#include <QAbstractListModel>
#include <QDate>
#include <QFile>
#include <QHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocale>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QThread>
#include <QTimer>
#include <QUrl>
#include <QVariant>
#include <QVector>
#include "franchise.h"
#include "live.h"
#include "store.h"
#include <algorithm>
#include <climits>
#include <memory>

// how an episode is named on a card (Episodes.chip in QML)
inline QString episodeChip(int n) { return "E" + QString::number(n); }

// One release on one day: an episode of a show in the library.
struct Release {
    QVariantMap item;            // the title entry Home shows for it (backdrop, logo, description, ...)
    QString name, art, title, overview, released, time, video;     // video: the episode's id
    int season = 1, episode = 0;
    bool watched = false;
    // what its card shows when its own still can't be had (an episode still to come has none): its title's backdrop
    QString fallback() const { return item.value("backdrop").toString(); }
    QVariantMap toMap() const {
        return { {"item", item}, {"name", name}, {"art", art}, {"fallback", fallback()}, {"title", title}, {"overview", overview},
                 {"released", released}, {"time", time}, {"season", season}, {"episode", episode}, {"watched", watched}, {"video", video} };
    }
};
using Calendar = QHash<QString, QVector<Release>>;   // "YYYY-MM-DD" -> releases

// The 42 days (six weeks, Monday first) of a month. Rows change only through layOut(): the row given
// first at once, the rest three a frame (about 16 ms apart), nearest first, and only rows whose values
// changed are signalled. Updating every day at once cost 80-110 ms on the TV.
class CalendarModel : public QAbstractListModel {
    Q_OBJECT
    Q_PROPERTY(QString today READ today WRITE setToday NOTIFY todayChanged)
public:
    enum Role { Key = Qt::UserRole + 1, Date, Count, Opacity, IsToday, Art0, Art1, Art2, Back0, Back1, Back2, Name, Episode, More, StackRoom };
    struct Day {
        QString key, art0, art1, art2, back0, back1, back2, name, episode, more;     // (`back`: each art's fallback)
        int date = 0, count = 0, stackRoom = 0;
        double opacity = 1;
        bool isToday = false;
        bool operator==(const Day &o) const {
            return key == o.key && count == o.count && opacity == o.opacity && isToday == o.isToday && art0 == o.art0
                && art1 == o.art1 && art2 == o.art2 && back0 == o.back0 && back1 == o.back1 && back2 == o.back2
                && name == o.name && episode == o.episode;
        }
    };

    explicit CalendarModel(QObject *parent = nullptr) : QAbstractListModel(parent), m_days(42) {
        m_stager.setInterval(16);
        connect(&m_stager, &QTimer::timeout, this, [this] {
            for (int n = 0; n < 3 && !m_pending.isEmpty(); n++) apply(m_pending.takeFirst());
            if (m_pending.isEmpty()) m_stager.stop();
        });
    }
    int rowCount(const QModelIndex &parent = {}) const override { return parent.isValid() ? 0 : 42; }
    QHash<int, QByteArray> roleNames() const override {
        return { {Key, "key"}, {Date, "date"}, {Count, "count"}, {Opacity, "dayOpacity"}, {IsToday, "isToday"},
                 {Art0, "art0"}, {Art1, "art1"}, {Art2, "art2"}, {Back0, "back0"}, {Back1, "back1"}, {Back2, "back2"},
                 {Name, "name"}, {Episode, "episode"},
                 {More, "more"}, {StackRoom, "stackRoom"} };
    }
    QVariant data(const QModelIndex &index, int role) const override {
        if (!index.isValid() || index.row() >= 42) return {};
        const Day &d = m_days[index.row()];
        switch (role) {
        case Key: return d.key;
        case Date: return d.date;
        case Count: return d.count;
        case Opacity: return d.opacity;
        case IsToday: return d.isToday;
        case Art0: return d.art0;
        case Art1: return d.art1;
        case Art2: return d.art2;
        case Back0: return d.back0;
        case Back1: return d.back1;
        case Back2: return d.back2;
        case Name: return d.name;
        case Episode: return d.episode;
        case More: return d.more;
        case StackRoom: return d.stackRoom;
        }
        return {};
    }

    QString today() const { return m_today; }
    void setToday(const QString &t) { if (t == m_today) return; m_today = t; emit todayChanged(); relayOut(0); }

    // shows month (1-12) of year; `firstRow` updates at once and the others follow (-1: all at once)
    Q_INVOKABLE void layOut(int year, int month, int firstRow) {
        m_month = QDate(year, month, 1);
        relayOut(firstRow);
    }
    void setCalendar(const Calendar *calendar) { m_calendar = calendar; relayOut(0); }

signals:
    void todayChanged();

private:
    Day compute(int i) const {
        Day d;
        if (!m_month.isValid()) return d;
        QDate day = m_month.addDays(1 - m_month.dayOfWeek() + i);       // dayOfWeek: Monday 1
        d.key = day.toString("yyyy-MM-dd");
        d.date = day.day();
        static const QVector<Release> none;
        const QVector<Release> &list = m_calendar ? m_calendar->value(d.key, none) : none;
        d.count = list.size();
        d.opacity = (day.month() != m_month.month() || day.year() != m_month.year()) ? 0.28 : (d.key < m_today ? 0.72 : 1);
        d.isToday = d.key == m_today;
        if (d.count > 0) { d.art0 = list[0].art; d.back0 = list[0].fallback(); d.name = list[0].name; d.episode = episodeChip(list[0].episode); }
        if (d.count > 1) { d.art1 = list[1].art; d.back1 = list[1].fallback(); d.more = "+" + QString::number(d.count - 1); }
        if (d.count > 2) { d.art2 = list[2].art; d.back2 = list[2].fallback(); }
        d.stackRoom = std::min(2, std::max(0, d.count - 1)) * 6;
        return d;
    }
    void apply(int row) {
        Day d = compute(row);
        if (d == m_days[row]) return;
        m_days[row] = d;
        emit dataChanged(index(row), index(row));
    }
    void relayOut(int firstRow) {
        m_stager.stop();
        m_pending.clear();
        if (firstRow < 0 || firstRow > 5) { for (int i = 0; i < 42; i++) apply(i); return; }
        for (int c = 0; c < 7; c++) apply(firstRow * 7 + c);
        QVector<int> rows = {0, 1, 2, 3, 4, 5};
        rows.removeAll(firstRow);
        std::stable_sort(rows.begin(), rows.end(), [firstRow](int a, int b) { return std::abs(a - firstRow) < std::abs(b - firstRow); });
        for (int r : rows) for (int c = 0; c < 7; c++) m_pending.append(r * 7 + c);
        m_stager.start();
    }

    QVector<Day> m_days;
    QDate m_month;
    QString m_today;
    const Calendar *m_calendar = nullptr;
    QVector<int> m_pending;
    QTimer m_stager;
};

// The resting rule (resting.h) for a show put together in QML: the app's own shows come with their
// `rest`, and tools/tests/tst_episodes.qml checks the rule through this.
class Rest : public QObject {
    Q_OBJECT
public:
    using QObject::QObject;
    // the id of the episode a show ({ current, seasons }) rests on, judged on `today`
    Q_INVOKABLE QString of(const QVariantMap &show, const QString &today) const { return Episodes::rest(show.value("seasons").toList(), show.value("current").toString(), today); }
};

// The data: Continue Watching, popular rows (for the tabs), shows with their seasons and episodes, and
// the calendar of release days. It loads once the account's stored state is in (Core); `reload()` takes
// Continue Watching and the watch states again (the app asks when the account says they changed).
class Catalog : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool ready READ ready NOTIFY loaded)
    Q_PROPERTY(QVariantList continueWatching READ continueWatching NOTIFY loaded)
    Q_PROPERTY(QVariantList popular READ popular NOTIFY loaded)
    Q_PROPERTY(CalendarModel *calendar READ calendar CONSTANT)
    Q_PROPERTY(bool seasonReady READ seasonReady NOTIFY seasonLoaded)      // the Anime tab's season, with its art
    Q_PROPERTY(QString seasonName READ seasonName NOTIFY seasonLoaded)      // "Fall 2026": the season the chart holds
    // the season picked (showSeason): seasonName once it is in, another while it's being fetched
    Q_PROPERTY(QString seasonAsked READ seasonAsked NOTIFY seasonAskedChanged)
    Q_PROPERTY(QVariantList seasons READ seasons CONSTANT)                  // the ones on offer, newest first
    Q_PROPERTY(QStringList seasonGenres READ seasonGenres NOTIFY seasonLoaded)    // most common first
    Q_PROPERTY(QString searchKind READ searchKind WRITE setSearchKind NOTIFY searchKindChanged)
    // The app's day ("YYYY-MM-DD"): what has aired goes by it, and with that the episode a show rests on
    // (resting.h). Another day (midnight, or a preview's pinned one) takes Home's data again.
    Q_PROPERTY(QString today READ today WRITE setToday NOTIFY todayChanged)
public:
    explicit Catalog(QObject *parent = nullptr) : QObject(parent), m_model(new CalendarModel(this)) {
        // Live and Franchise fetch, read and assemble on a thread of their own: a show's meta is hundreds of
        // kilobytes of JSON, and reading it where it arrived, on the GUI thread, stalled it 20 to 60 ms
        // whenever the network answered. `work` runs something there; what it produces comes `back` here.
        m_live->moveToThread(&m_thread); m_franchise->moveToThread(&m_thread);
        connect(m_franchise, &Franchise::ready, this, &Catalog::franchiseReady);
        connect(m_franchise, &Franchise::failed, this, &Catalog::franchiseFailed);
        m_thread.start();
        Core *core = Core::instance();
        connect(core, &Core::readyChanged, this, &Catalog::load);
        m_again.setSingleShot(true); m_again.setInterval(400);          // a sign-in changes it several times over
        connect(&m_again, &QTimer::timeout, this, &Catalog::reloadNow);
        core->start();
        if (core->ready()) load();
    }
    ~Catalog() override { m_thread.quit(); m_thread.wait(); delete m_live; delete m_franchise; }
    bool ready() const { return m_ready; }
    QVariantList continueWatching() const { return m_data ? m_data->continueWatching : QVariantList(); }
    QVariantList popular() const { return m_data ? m_data->popular : QVariantList(); }
    CalendarModel *calendar() const { return m_model; }
    QString seasonName() const { return m_data ? m_data->seasonName : QString(); }
    QStringList seasonGenres() const { return m_data ? m_data->seasonGenres : QStringList(); }

    // The season's chart, as AniChart lists it. `format` "all", "tv" (TV, TV short), "movie", "other"
    // (ONA, OVA, specials); `genre` "" for all; `sort` "popular", "score", "airing" (next episode
    // soonest), "title". Each item's `label` counts down to its next episode from `now` (epoch s).
    Q_INVOKABLE QVariantList seasonChart(const QString &format, const QString &genre, const QString &sort, qint64 now) const {
        QVector<QVariantMap> out;
        if (m_data) for (const QVariantMap &m : m_data->season) if (fits(m, format, genre)) out << withCountdown(m, now);
        auto key = [&](const QVariantMap &m) { return m["nextAt"].toLongLong() > now ? m["nextAt"].toLongLong() : LLONG_MAX; };
        if (sort == "score") std::stable_sort(out.begin(), out.end(), [](const QVariantMap &a, const QVariantMap &b) { return a["score"].toInt() > b["score"].toInt(); });
        else if (sort == "title") std::stable_sort(out.begin(), out.end(), [](const QVariantMap &a, const QVariantMap &b) { return QString::localeAwareCompare(a["name"].toString(), b["name"].toString()) < 0; });
        else if (sort == "airing") std::stable_sort(out.begin(), out.end(), [&](const QVariantMap &a, const QVariantMap &b) { return key(a) < key(b); });
        QVariantList list; for (const QVariantMap &m : out) list << m;
        return list;
    }
    // An anime as one show with all its seasons, films and specials, each with its own art and facts
    // (Franchise); `source` is what the screen showed, with an AniList or Kitsu id. Ends in
    // `franchiseReady(sourceId, item, show)` (item: the title as the screen showed it, id "kitsu:N", `video`
    // where its page opens) or `franchiseFailed`.
    // A Cinemeta title (a film or a series from a list, the library or a search) answers the same way:
    // its facts and art filled in, and a series' seasons with the library's watch state.
    Q_INVOKABLE void loadFranchise(const QVariantMap &source) {
        const QString id = source.value("id").toString(), type = source.value("type").toString() == "movie" ? "movie" : "series";
        if (!id.startsWith("tt")) { work([this, source] { m_franchise->load(source); }); return; }
        const QJsonObject state = m_docs.library.value(id).toObject();
        work([this, source, id, type, state] {
            m_live->title(type, id, [this, source, id, type, state](const QJsonObject &meta) {
                if (meta.isEmpty()) { back([this, id] { emit franchiseFailed(id, "Couldn't load it"); }); return; }
                const QVariantMap show = type == "series" ? Live::show(meta, state).toVariantMap() : QVariantMap();
                // what the screen showed, with the meta's facts and art; its own place in the title stays
                QVariantMap item = source;
                const QVariantMap fresh = Live::item(meta);
                for (auto it = fresh.begin(); it != fresh.end(); ++it) if ((it.key() != "episode" && it.key() != "progress") || !item.contains(it.key())) item[it.key()] = it.value();
                item["type"] = type; item.remove("thin");
                back([this, source, id, item, show, state] {
                    // watched while it was on its way: its seasons are made again with what the library says now
                    if (m_docs.library.value(id).toObject() != state) { loadFranchise(source); return; }
                    emit franchiseReady(id, item, show);
                });
            });
        });
    }
    // Titles by name (Live::search): `found(query, results)`, the titles of each kind { anime, series,
    // movie }. A film or a series is as Cinemeta's search gives it, a name, a year and pictures (`thin`):
    // its facts come with its page (`loadFranchise`). Only the last search asked for answers. Films and
    // series are all Cinemeta has to give (twenty of each); the anime are the first fifty, and
    // `searchMore()` asks for the next fifty when there are more: `foundMore(query, anime)`.
    Q_INVOKABLE void search(const QString &query) {
        const QString q = query.trimmed();
        // the same text asked again (a space typed after it) is answered again, and its anime stay where
        // their pages are: started over, the next page asked for was one the grid already had
        const bool again = q == m_searching;
        m_searching = q;
        if (!again) { m_animePage = 1; m_animeMore = m_animeAsked = false; }
        if (q.size() < 2) { emit found(q, QVariantMap()); return; }
        work([this, q, again] {
            m_live->search(q, [this, q, again](const QJsonObject &r) {
                QVariantList movies, series;
                auto thin = [](const QJsonValue &v) { QVariantMap m = Live::item(v.toObject()); m["thin"] = true; return m; };
                for (const QJsonValue &v : r.value("movies").toArray()) movies << thin(v);
                for (const QJsonValue &v : r.value("series").toArray()) series << thin(v);
                const QVariantMap results { { "anime", shows(r.value("anime").toArray()) }, { "series", series }, { "movie", movies } };
                const bool more = r.value("animeMore").toBool();
                back([this, q, results, more, again] { if (q != m_searching) return; if (!again) m_animeMore = more; emit this->found(q, results); });
            });
        });
    }
    Q_INVOKABLE void searchMore() {
        if (!m_animeMore || m_animeAsked) return;
        m_animeAsked = true;
        const QString q = m_searching;
        const int page = ++m_animePage;
        work([this, q, page] {
            m_live->searchAnime(q, page, [this, q](const QJsonArray &found, bool more) {
                const QVariantList anime = shows(found);
                back([this, q, anime, more] { if (q != m_searching) return; m_animeAsked = false; m_animeMore = more; emit this->foundMore(q, anime); });
            });
        });
    }
    QString today() const { return m_today; }
    void setToday(const QString &day) {
        if (day == m_today) return;
        const bool other = day != Episodes::today();        // (the clock's day, the first time: nothing to take again)
        m_today = day; Episodes::setToday(day);
        emit todayChanged();
        if (other) reloadNow();
    }
    // which kind of title a search shows ("anime", "series" or "movie"): the last one picked, kept between
    // runs (a preview starts on anime and keeps nothing)
    QString searchKind() {
        if (m_searchKind.isEmpty()) m_searchKind = Http::replaying() ? QString("anime") : m_choices.data().value("searchKind").toString("anime");
        return m_searchKind;
    }
    void setSearchKind(const QString &kind) {
        if (kind == searchKind()) return;
        m_searchKind = kind;
        if (!Http::replaying()) { m_choices.data()["searchKind"] = kind; m_choices.save(); }
        emit searchKindChanged();
    }
    // The week ahead, a day at a time from `now`: [{ title ("Today", "Tomorrow", "Thursday"), date,
    // items }], each item's `label` its local air time
    Q_INVOKABLE QVariantList seasonSchedule(const QString &format, const QString &genre, qint64 now) const {
        QVariantList days;
        const QDate today = QDateTime::fromSecsSinceEpoch(now).date();
        for (int d = 0; d < 7; d++) {
            const QDate day = today.addDays(d);
            QVector<QVariantMap> items;
            if (m_data) for (const QVariantMap &m : m_data->season) {
                const qint64 at = m["nextAt"].toLongLong();
                if (at < now || !fits(m, format, genre) || QDateTime::fromSecsSinceEpoch(at).date() != day) continue;
                QVariantMap i = m;
                i["label"] = QDateTime::fromSecsSinceEpoch(at).toString("HH:mm");
                i["episode"] = episodeChip(m["nextEpisode"].toInt());
                i["art"] = m["backdrop"];                                    // the wide banner suits a row
                items << i;
            }
            std::sort(items.begin(), items.end(), [](const QVariantMap &a, const QVariantMap &b) { return a["nextAt"].toLongLong() < b["nextAt"].toLongLong(); });
            QVariantList list; for (const QVariantMap &m : items) list << m;
            days << QVariantMap { { "title", d == 0 ? QStringLiteral("Today") : d == 1 ? QStringLiteral("Tomorrow") : QLocale().dayName(day.dayOfWeek()) },
                                  { "date", day.toString("d MMMM") }, { "items", list } };
        }
        return days;
    }

    // Home's data arrives first (`loaded`), the Anime tab's season with its art after (`seasonLoaded`).
    void load() {
        const int generation = ++m_generation;
        work([this, generation] {
            m_live->fetch([this, generation](Live::Docs docs) { built(docs, generation); }, [this](Live::Docs docs) {
                auto season = std::make_shared<Data>();
                Data::loadSeason(*season, docs.season);
                back([this, season] {
                    m_seasons[season->seasonName] = season;
                    if (!m_seasonAsked.isEmpty()) return;                                // another was picked while it loaded
                    m_seasonAsked = season->seasonName; emit seasonAskedChanged();
                    takeSeason(season->seasonName);
                });
            });
        });
    }
    // Continue Watching and the watch states again (a title played, another device, a sign-in); `loaded` after
    Q_INVOKABLE void reload() { m_again.start(); }
    void reloadNow() {
        if (!m_ready) { m_stale = true; return; }                   // the first load is on its way: after it
        auto docs = std::make_shared<Live::Docs>(m_docs);
        const int generation = ++m_generation;
        work([this, docs, generation] { m_live->continueWatching(docs, [this, docs, generation] { built(*docs, generation); }); });
    }
    // on the data thread: Home's documents are in, so its data is made there and handed over whole. Only
    // the newest load's is taken: two can overlap, and the older one finishing last would put back an
    // older library and older progress.
    void built(const Live::Docs &docs, int generation) {
        auto data = std::make_shared<Data>(Data::load(docs));
        back([this, docs, data, generation] {
            if (generation != m_generation) return;
            m_docs = docs;
            // the library first: `loaded` has the page in hand ask for its franchise again, which is put
            // together from what was fetched at once, with the library the franchise has then
            const QJsonObject library = docs.library, airing = docs.airing;
            work([this, library, airing] { m_franchise->setLibrary(library, airing); });
            Core::instance()->setAiring(airing);       // (a title marked watched is its episodes out by the same days)
            take(data);
        });
    }
    bool seasonReady() const { return m_seasonReady; }
    QString seasonAsked() const { return m_seasonAsked; }
    // The seasons the Anime tab offers: the next one, the one now, and three years back, as
    // { season, year, label, detail } ("WINTER", 2027, "Winter 2027", "Next" | "Now" | "").
    static QVariantList seasonsFrom(const QDate &today) {
        static const QStringList order { "WINTER", "SPRING", "SUMMER", "FALL" };
        const auto now = Live::seasonAt(today);
        int i = order.indexOf(now.first) + 1, year = now.second;                // the next one first
        if (i > 3) { i = 0; year++; }
        QVariantList out;
        for (int n = 0; n < 14; n++) {
            out << QVariantMap { { "season", order[i] }, { "year", year }, { "label", seasonLabel(order[i], year) },
                                 { "detail", n == 0 ? "Next" : order[i] == now.first && year == now.second ? "Now" : "" } };
            if (--i < 0) { i = 3; year--; }
        }
        return out;
    }
    QVariantList seasons() const { return seasonsFrom(QDate::currentDate()); }
    Q_INVOKABLE QVariantList seasonsOn(const QString &day) const { return seasonsFrom(QDate::fromString(day, "yyyy-MM-dd")); }   // tests
    static QString seasonLabel(const QString &season, int year) { return season.left(1) + season.mid(1).toLower() + " " + QString::number(year); }
    // Shows another season on the Anime tab: at once if it has been fetched this run, else once it is in
    // whole (its list and every show's art), the one on screen staying until then. `seasonFailed` if it
    // couldn't be had, and the season shown stays.
    Q_INVOKABLE void showSeason(const QString &season, int year) {
        const QString name = seasonLabel(season, year);
        if (name == m_seasonAsked) return;
        m_seasonAsked = name; emit seasonAskedChanged();
        if (m_seasons.contains(name)) { takeSeason(name); return; }
        work([this, season, year, name] {
            m_live->seasonChart(season, year, [this, name](QJsonObject doc) {
                auto data = std::make_shared<Data>();
                Data::loadSeason(*data, doc);
                back([this, data, name] {
                    if (!data->season.isEmpty()) m_seasons[name] = data;
                    if (m_seasonAsked != name) return;                                  // another was picked since
                    if (data->season.isEmpty()) { m_seasonAsked = seasonName(); emit seasonAskedChanged(); emit seasonFailed(name); }
                    else takeSeason(name);
                });
            });
        });
    }

    // a show's seasons and episodes, for the show page (empty if it isn't a library show)
    Q_INVOKABLE QVariantMap show(const QString &id) const { return m_data ? m_data->shows.value(id).toMap() : QVariantMap(); }
    Q_INVOKABLE int episodeCount(const QString &id) const { return m_data ? m_data->episodeCounts.value(id, 0) : 0; }
    // whether a title is one the catalog has whole (Continue Watching's, with their seasons); any other is fetched
    Q_INVOKABLE bool holds(const QString &id) const { return m_data && m_data->held.contains(id); }
    // The backdrop of a title that comes without one (the library lists a name and a poster): the one it
    // has here if it's held, Cinemeta's for an IMDb title, nothing otherwise (until it is fetched)
    Q_INVOKABLE QString backdrop(const QString &id) const {
        if (m_data && m_data->held.contains(id)) return m_data->held.value(id);
        return id.startsWith("tt") ? Live::metahub("background", id) : QString();
    }
    // a day's releases (the library's shows)
    Q_INVOKABLE QVariantList day(const QString &key) const {
        QVariantList out;
        if (m_data) for (const Release &r : m_data->calendar.value(key)) out.append(r.toMap());
        return out;
    }
    Q_INVOKABLE int releaseCount(const QString &key) const { return m_data ? m_data->calendar.value(key).size() : 0; }

signals:
    void loaded();
    void seasonLoaded();
    void seasonAskedChanged();
    void seasonFailed(const QString &name);
    void franchiseReady(const QString &sourceId, const QVariantMap &item, const QVariantMap &show);
    void franchiseFailed(const QString &sourceId, const QString &reason);
    void found(const QString &query, const QVariantMap &results);
    void foundMore(const QString &query, const QVariantList &anime);
    void todayChanged();
    void searchKindChanged();

private:
    struct Data {
        QVariantList continueWatching, popular;
        QHash<QString, QString> held;           // Continue Watching's and the library's shows: id -> backdrop
        QHash<QString, QVariant> shows;
        QHash<QString, int> episodeCounts;
        Calendar calendar;
        QVector<QVariantMap> season;            // the season's shows, most popular first (season.json)
        QString seasonName;
        QStringList seasonGenres;

        static QStringList strings(const QJsonValue &v) {
            QStringList out;
            for (const QJsonValue &x : v.toArray()) if (!x.toString().isEmpty()) out << x.toString();
            return out;
        }
        // the live documents (Live) as the catalog's data; images are their URLs
        static Data load(const Live::Docs &docs) {
            auto art = [](const QString &url) { return url; };
            Data d;
            QHash<QString, QVariantMap> byId;
            for (const QJsonValue &v : docs.cw) {
                QJsonObject i = v.toObject();
                if (i["backdrop"].toString().isEmpty()) continue;
                QString year = i["year"].toString();
                if (year.endsWith('-') || year.endsWith(QChar(0x2013))) year.chop(1);
                QStringList chips = QStringList{year} + strings(i["genres"]);
                chips.removeAll(QString());
                // (`type` and `poster`: the title as Stremio's library has it, for what Home's menu does with it)
                QVariantMap item{ {"id", i["id"].toString()}, {"name", i["name"].toString()}, {"title", i["name"].toString()},
                                  {"type", i["type"].toString()}, {"poster", i["poster"].toString()},
                                  {"art", art(i["backdrop"].toString())}, {"backdrop", art(i["backdrop"].toString())}, {"logo", art(i["logo"].toString())},
                                  {"description", i["description"].toString()}, {"chips", chips}, {"rating", QString()},
                                  {"episode", QString()}, {"progress", i["progress"].toDouble()} };
                // A show's card is the episode it rests on (`rest`, resting.h: the one its page opens on and
                // Play names there): that episode's still, with the title's backdrop when it has none, its
                // name on the chip and how far through it you are. `video` is what the page opens on.
                const QJsonObject resting = docs.series.value(i["id"].toString()).toObject();
                for (const QJsonValue &sv : resting["seasons"].toArray()) {
                    for (const QJsonValue &ev : sv.toObject()["episodes"].toArray()) {
                        const QJsonObject e = ev.toObject();
                        if (e["id"] != resting["rest"]) continue;
                        const QString chip = episodeChip(e["episode"].toInt());
                        item["video"] = e["id"].toString();
                        item["episode"] = item["id"].toString().startsWith("kitsu:") ? chip : "S" + QString::number(sv.toObject()["season"].toInt()) + " " + chip;
                        item["progress"] = e["progress"].toDouble();
                        if (!e["thumb"].toString().isEmpty()) { item["art"] = art(e["thumb"].toString()); item["fallback"] = item["backdrop"]; }
                    }
                }
                // a library show that isn't being watched: on the calendar, not on Continue Watching
                if (!i["kept"].toBool()) d.continueWatching.append(item);
                d.held[item["id"].toString()] = item["backdrop"].toString();
                byId[item["id"].toString()] = item;
            }
            for (const QJsonValue &row : docs.rows) {
                QVariantList items;
                for (const QJsonValue &v : row.toObject()["items"].toArray()) {
                    QJsonObject m = v.toObject();
                    QStringList chips = QStringList{m["year"].toString(), m["runtime"].toString()} + strings(m["genres"]);
                    chips.removeAll(QString());
                    items.append(QVariantMap{ {"id", m["id"].toString()}, {"name", m["name"].toString()}, {"title", m["name"].toString()},
                                              {"art", art(m["poster"].toString())}, {"backdrop", art(m["backdrop"].toString())}, {"logo", art(m["logo"].toString())},
                                              {"description", m["description"].toString()}, {"chips", chips}, {"rating", m["rating"].toString()},
                                              {"episode", QString()}, {"progress", -1} });
                }
                d.popular.append(QVariantMap{ {"title", row.toObject()["title"].toString()}, {"kind", "portrait"}, {"items", items} });
            }
            // The calendar is the library's: the episodes its shows list, each on the day it comes out. (A
            // title being watched without having been added is on Continue Watching, not here.) An anime's
            // episode airs when AniList says (`airing`: the day and the time where you are), and its show's
            // page has that day too (here and in Franchise), so the two never disagree on what is still to
            // come; the rest have their date.
            QSet<QString> mine;                              // the library's titles
            for (const QJsonValue &v : docs.cw) if (v.toObject()["library"].toBool()) mine << v.toObject()["id"].toString();
            const QJsonObject series = docs.series;
            for (auto it = series.begin(); it != series.end(); ++it) {
                QJsonObject show = it.value().toObject();
                QVariantList seasons;
                int count = 0;
                const QVariantMap *item = byId.contains(it.key()) ? &byId[it.key()] : nullptr;
                for (const QJsonValue &sv : show["seasons"].toArray()) {
                    QJsonObject s = sv.toObject();
                    QVariantList episodes;
                    for (const QJsonValue &ev : s["episodes"].toArray()) {
                        QJsonObject e = ev.toObject();
                        const QJsonObject air = docs.airing.value(e["id"].toString()).toObject();
                        const QString released = air.isEmpty() ? e["released"].toString() : air["date"].toString();
                        QVariantMap ep = e.toVariantMap();
                        ep["thumb"] = art(e["thumb"].toString());
                        ep["released"] = released;
                        episodes.append(ep);
                        count++;
                        if (item && mine.contains(it.key()) && !released.isEmpty()) {
                            Release r;
                            r.item = *item; r.name = show["name"].toString(); r.art = e["thumb"].toString().isEmpty() ? (*item)["backdrop"].toString() : art(e["thumb"].toString());
                            r.season = s["season"].toInt(); r.episode = e["episode"].toInt(); r.title = e["title"].toString();
                            r.overview = e["overview"].toString(); r.watched = e["watched"].toBool(); r.released = released; r.time = air["time"].toString();
                            r.video = e["id"].toString();
                            d.calendar[released].append(r);
                        }
                    }
                    seasons.append(QVariantMap{ {"season", s["season"].toInt()}, {"episodes", episodes} });
                }
                QVariantMap m = show.toVariantMap();
                m["seasons"] = seasons;
                d.shows[it.key()] = m;
                d.episodeCounts[it.key()] = count;
            }
            return d;
        }
        // the Anime tab's season (Live's season document) as the catalog's chart
        static void loadSeason(Data &d, const QJsonObject &season) {
            auto art = [](const QString &url) { return url; };
            if (season.isEmpty()) return;
                QString name = season["season"].toString().toLower();
            if (!name.isEmpty()) name[0] = name[0].toUpper();
            d.seasonName = name + " " + QString::number(season["year"].toInt());
            QHash<QString, int> genreCount;
            static const QHash<QString, QString> formats { { "TV", "TV" }, { "TV_SHORT", "TV short" }, { "MOVIE", "Movie" }, { "ONA", "ONA" }, { "OVA", "OVA" }, { "SPECIAL", "Special" } };
            for (const QJsonValue &v : season["shows"].toArray()) {
                const QJsonObject a = v.toObject();
                // the backdrop: the full-screen fanart, or AniList's banner strip, or the cover
                const QString cover = art(a["cover"].toString()), banner = art(a["banner"].toString()), background = art(a["background"].toString());
                const QString format = formats.value(a["format"].toString(), a["format"].toString());
                const int episodes = a["episodes"].toInt();
                QStringList chips { format };
                if (episodes > 1) chips << QString::number(episodes) + " episodes";
                else if (a["duration"].toInt() > 0 && a["format"].toString() == "MOVIE") chips << QString::number(a["duration"].toInt()) + " min";
                if (!a["studio"].toString().isEmpty()) chips << a["studio"].toString();
                const QStringList genres = strings(a["genres"]);
                chips += genres.mid(0, 2);
                for (const QString &g : genres) genreCount[g]++;
                const QJsonObject next = a["next"].toObject();
                d.season.append(QVariantMap{
                    { "id", a["id"].toString() }, { "name", a["name"].toString() }, { "title", a["name"].toString() },
                    { "kitsu", a["kitsu"].toString() },          // the title Stremio's library knows it by, if Kitsu has it
                    { "art", cover }, { "cover", cover }, { "backdrop", !background.isEmpty() ? background : !banner.isEmpty() ? banner : cover }, { "logo", art(a["logo"].toString()) },
                    { "description", a["description"].toString() }, { "chips", chips }, { "genres", genres },
                    { "rating", a["score"].toInt() ? QString::number(a["score"].toInt()) + "%" : QString() }, { "score", a["score"].toInt() },
                    { "format", a["format"].toString() }, { "studio", a["studio"].toString() }, { "color", a["color"].toString() },
                    { "leftover", a["leftover"].toBool() }, { "start", a["start"].toString() },
                    { "nextEpisode", next["episode"].toInt() }, { "nextAt", qint64(next["at"].toDouble()) },
                    { "episodes", episodes }, { "episode", QString() }, { "progress", -1 } });
            }
            QList<QPair<int, QString>> ranked;
            for (auto it = genreCount.begin(); it != genreCount.end(); ++it) ranked << qMakePair(-it.value(), it.key());
            std::sort(ranked.begin(), ranked.end());
            for (const auto &g : ranked) d.seasonGenres << g.second;
        }
    };
    static bool fits(const QVariantMap &m, const QString &format, const QString &genre) {
        const QString f = m["format"].toString();
        if (format == "tv" && f != "TV" && f != "TV_SHORT") return false;
        if (format == "movie" && f != "MOVIE") return false;
        if (format == "other" && f != "ONA" && f != "OVA" && f != "SPECIAL") return false;
        return genre.isEmpty() || m["genres"].toStringList().contains(genre);
    }
    // "E8 in 2d 4h", "E8 in 3h", "E8 in 12m"; a film or a finished show has no countdown
    static QVariantMap withCountdown(QVariantMap m, qint64 now) {
        const qint64 at = m["nextAt"].toLongLong(), left = at - now;
        QString label;
        if (at > 0 && left > 0) {
            const qint64 days = left / 86400, hours = left % 86400 / 3600, minutes = left % 3600 / 60;
            label = episodeChip(m["nextEpisode"].toInt()) + " in "
                  + (days ? QString::number(days) + "d " + QString::number(hours) + "h" : hours ? QString::number(hours) + "h " + QString::number(minutes) + "m" : QString::number(qMax<qint64>(1, minutes)) + "m");
        }
        m["label"] = label;
        return m;
    }
    void take(std::shared_ptr<Data> data) {
        // the season on show is the Anime tab's own, fetched apart: a new Home keeps it
        if (m_data) { data->season = m_data->season; data->seasonName = m_data->seasonName; data->seasonGenres = m_data->seasonGenres; }
        m_data = data;
        m_ready = true;
        m_model->setCalendar(&m_data->calendar);
        emit loaded();
        if (m_stale) { m_stale = false; reloadNow(); }
    }

    QString m_searching;                                   // the last search asked for
    int m_animePage = 1;                                   // its anime: the last page asked for, whether one follows, and whether it is on its way
    bool m_animeMore = false, m_animeAsked = false;
    QString m_searchKind, m_today;
    JsonStore m_choices { "choices.json" };                // what was last picked where the app remembers it
    int m_generation = 0;                                  // the newest load of Home's documents
    Live::Docs m_docs;                                     // Home's documents as last fetched
    QTimer m_again;
    bool m_stale = false;
    bool m_ready = false, m_seasonReady = false;
    QString m_seasonAsked;
    QHash<QString, std::shared_ptr<Data>> m_seasons;       // the seasons fetched this run, by name ("Fall 2026")
    void takeSeason(const QString &name) {
        const auto s = m_seasons.value(name);
        if (!m_data) m_data = std::make_shared<Data>();
        m_data->season = s->season; m_data->seasonName = s->seasonName; m_data->seasonGenres = s->seasonGenres;
        m_seasonReady = true;
        emit seasonLoaded();
    }
    QThread m_thread;
    Live *m_live = new Live;                               // both live on m_thread
    Franchise *m_franchise = new Franchise;
    // AniList's shows (Live::shown) as the screens show a title: a search's anime, as a season's chart has them
    static QVariantList shows(const QJsonArray &found) {
        Data d; Data::loadSeason(d, QJsonObject { { "shows", found } });
        QVariantList out;
        for (const QVariantMap &m : d.season) out << m;
        return out;
    }
    template <typename F> void work(F f) { QMetaObject::invokeMethod(m_live, f, Qt::QueuedConnection); }
    template <typename F> void back(F f) { QMetaObject::invokeMethod(this, f, Qt::QueuedConnection); }
    std::shared_ptr<Data> m_data;
    CalendarModel *m_model;
};
