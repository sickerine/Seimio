#pragma once
// Seimio.Data: the app's data held natively, outside QML's JavaScript heap. QML asks for what a screen
// needs when it needs it (one show's seasons, one day's releases), so the JS heap stays small (the
// engine's stop-the-world GC takes longer the more is alive) and nothing is parsed on the GUI thread.
//
// Catalog loads the lab data (app/art/*.json, from tools/fetch-art.py and tools/fetch-airing.py) on a
// worker thread; stremio-core will feed the same shapes later. CalendarModel is the month grid's model.
#include <QAbstractListModel>
#include <QDate>
#include <QFile>
#include <QHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocale>
#include <QThread>
#include <QTimer>
#include <QUrl>
#include <QVariant>
#include <QVector>
#include <algorithm>
#include <memory>

// One release on one day: an episode of a library show or of the airing schedule.
struct Release {
    QVariantMap item;            // the title entry Home shows for it (backdrop, logo, description, ...)
    QString name, art, title, overview, released, time;
    int season = 1, episode = 0;
    bool watched = false;
    QVariantMap toMap() const {
        return { {"item", item}, {"name", name}, {"art", art}, {"title", title}, {"overview", overview},
                 {"released", released}, {"time", time}, {"season", season}, {"episode", episode}, {"watched", watched} };
    }
};
using Calendar = QHash<QString, QVector<Release>>;   // "YYYY-MM-DD" -> releases, library first

// The 42 days (six weeks, Monday first) of a month. Rows change only through layOut(): the row given
// first at once, the rest three a frame (about 16 ms apart), nearest first, and only rows whose values
// changed are signalled. Updating every day at once cost 80-110 ms on the TV.
class CalendarModel : public QAbstractListModel {
    Q_OBJECT
    Q_PROPERTY(QString today READ today WRITE setToday NOTIFY todayChanged)
public:
    enum Role { Key = Qt::UserRole + 1, Date, Count, Opacity, IsToday, Art0, Art1, Art2, Name, Episode, More, StackRoom };
    struct Day {
        QString key, art0, art1, art2, name, episode, more;
        int date = 0, count = 0, stackRoom = 0;
        double opacity = 1;
        bool isToday = false;
        bool operator==(const Day &o) const {
            return key == o.key && count == o.count && opacity == o.opacity && isToday == o.isToday && art0 == o.art0
                && art1 == o.art1 && art2 == o.art2 && name == o.name && episode == o.episode;
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
                 {Art0, "art0"}, {Art1, "art1"}, {Art2, "art2"}, {Name, "name"}, {Episode, "episode"},
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
        if (d.count > 0) { d.art0 = list[0].art; d.name = list[0].name; d.episode = "E" + QString::number(list[0].episode); }
        if (d.count > 1) { d.art1 = list[1].art; d.more = "+" + QString::number(d.count - 1); }
        if (d.count > 2) d.art2 = list[2].art;
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

// The data: Continue Watching, popular rows (for the tabs), shows with their seasons and episodes, and
// the calendar of release days. Setting `base` (the art folder's URL) loads it on a worker thread.
class Catalog : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString base READ base WRITE setBase NOTIFY baseChanged)
    Q_PROPERTY(bool ready READ ready NOTIFY loaded)
    Q_PROPERTY(QVariantList continueWatching READ continueWatching NOTIFY loaded)
    Q_PROPERTY(QVariantList popular READ popular NOTIFY loaded)
    Q_PROPERTY(CalendarModel *calendar READ calendar CONSTANT)
    Q_PROPERTY(QString seasonName READ seasonName NOTIFY loaded)            // "Fall 2026"
    Q_PROPERTY(QStringList seasonGenres READ seasonGenres NOTIFY loaded)    // most common first
public:
    explicit Catalog(QObject *parent = nullptr) : QObject(parent), m_model(new CalendarModel(this)) {}
    QString base() const { return m_base; }
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
                i["episode"] = "E" + QString::number(m["nextEpisode"].toInt());
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

    void setBase(const QString &b) {
        if (b == m_base) return;
        m_base = b;
        emit baseChanged();
        QString dir = QUrl(b).isLocalFile() ? QUrl(b).toLocalFile() : b;
        // the result comes back through a queued connection with this object as its context, so Qt
        // drops it if the catalog is gone by then (no pointer to it crosses threads)
        auto data = std::make_shared<Data>();
        QThread *worker = QThread::create([data, dir, b] { *data = Data::load(dir, b); });
        connect(worker, &QThread::finished, this, [this, data] { take(data); });
        connect(worker, &QThread::finished, worker, &QObject::deleteLater);
        worker->start();
    }

    // a show's seasons and episodes, for the show page (empty if it isn't a library show)
    Q_INVOKABLE QVariantMap show(const QString &id) const { return m_data ? m_data->shows.value(id).toMap() : QVariantMap(); }
    Q_INVOKABLE int episodeCount(const QString &id) const { return m_data ? m_data->episodeCounts.value(id, 0) : 0; }
    // a day's releases, library shows first
    Q_INVOKABLE QVariantList day(const QString &key) const {
        QVariantList out;
        if (m_data) for (const Release &r : m_data->calendar.value(key)) out.append(r.toMap());
        return out;
    }
    Q_INVOKABLE int releaseCount(const QString &key) const { return m_data ? m_data->calendar.value(key).size() : 0; }

signals:
    void baseChanged();
    void loaded();

private:
    struct Data {
        QVariantList continueWatching, popular;
        QHash<QString, QVariant> shows;
        QHash<QString, int> episodeCounts;
        Calendar calendar;
        QVector<QVariantMap> season;            // the season's shows, most popular first (season.json)
        QString seasonName;
        QStringList seasonGenres;

        static QJsonDocument read(const QString &dir, const QString &name) {
            QFile f(dir + "/" + name);
            return f.open(QIODevice::ReadOnly) ? QJsonDocument::fromJson(f.readAll()) : QJsonDocument();
        }
        static QStringList strings(const QJsonValue &v) {
            QStringList out;
            for (const QJsonValue &x : v.toArray()) if (!x.toString().isEmpty()) out << x.toString();
            return out;
        }
        static Data load(const QString &dir, QString base) {
            if (!base.endsWith('/')) base += '/';
            auto art = [&base](const QString &f) { return f.isEmpty() ? QString() : base + f; };
            Data d;
            QHash<QString, QVariantMap> byId;
            for (const QJsonValue &v : read(dir, "cw.json").array()) {
                QJsonObject i = v.toObject();
                if (i["backdrop"].toString().isEmpty()) continue;
                QString year = i["year"].toString();
                if (year.endsWith('-') || year.endsWith(QChar(0x2013))) year.chop(1);
                QStringList chips = QStringList{year} + strings(i["genres"]);
                chips.removeAll(QString());
                QVariantMap item{ {"id", i["id"].toString()}, {"name", i["name"].toString()}, {"title", i["name"].toString()},
                                  {"art", art(i["backdrop"].toString())}, {"backdrop", art(i["backdrop"].toString())}, {"logo", art(i["logo"].toString())},
                                  {"description", i["description"].toString()}, {"chips", chips}, {"rating", QString()},
                                  {"episode", i["episode"].toString()}, {"progress", i["progress"].toDouble()} };
                d.continueWatching.append(item);
                byId[item["id"].toString()] = item;
            }
            for (const QJsonValue &row : read(dir, "rows.json").array()) {
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
            QJsonObject series = read(dir, "series.json").object();
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
                        QVariantMap ep = e.toVariantMap();
                        ep["thumb"] = art(e["thumb"].toString());
                        episodes.append(ep);
                        count++;
                        QString released = e["released"].toString();
                        if (item && !released.isEmpty()) {
                            Release r;
                            r.item = *item; r.name = show["name"].toString(); r.art = e["thumb"].toString().isEmpty() ? (*item)["backdrop"].toString() : art(e["thumb"].toString());
                            r.season = s["season"].toInt(); r.episode = e["episode"].toInt(); r.title = e["title"].toString();
                            r.overview = e["overview"].toString(); r.watched = e["watched"].toBool(); r.released = released;
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
            const QJsonObject season = read(dir, "season.json").object();
            if (!season.isEmpty()) {
                QString name = season["season"].toString().toLower();
                if (!name.isEmpty()) name[0] = name[0].toUpper();
                d.seasonName = name + " " + QString::number(season["year"].toInt());
                QHash<QString, int> genreCount;
                static const QHash<QString, QString> formats { { "TV", "TV" }, { "TV_SHORT", "TV short" }, { "MOVIE", "Movie" }, { "ONA", "ONA" }, { "OVA", "OVA" }, { "SPECIAL", "Special" } };
                for (const QJsonValue &v : season["shows"].toArray()) {
                    const QJsonObject a = v.toObject();
                    const QString cover = art(a["cover"].toString()), banner = art(a["banner"].toString());
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
                        { "art", cover }, { "cover", cover }, { "backdrop", banner.isEmpty() ? cover : banner }, { "logo", QString() },
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
            for (const QJsonValue &v : read(dir, "airing.json").array()) {
                QJsonObject a = v.toObject();
                QString artUrl = art(a["art"].toString());
                Release r;
                r.item = QVariantMap{ {"id", a["id"].toString()}, {"name", a["name"].toString()}, {"title", a["name"].toString()},
                                      {"art", artUrl}, {"backdrop", artUrl}, {"logo", QString()}, {"description", a["description"].toString()},
                                      {"chips", QStringList()}, {"rating", QString()}, {"episode", "E" + QString::number(a["episode"].toInt())}, {"progress", -1} };
                r.name = a["name"].toString(); r.art = artUrl; r.episode = a["episode"].toInt(); r.overview = a["description"].toString();
                r.released = a["date"].toString(); r.time = a["time"].toString();
                d.calendar[r.released].append(r);
            }
            return d;
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
            label = "E" + QString::number(m["nextEpisode"].toInt()) + " in "
                  + (days ? QString::number(days) + "d " + QString::number(hours) + "h" : hours ? QString::number(hours) + "h " + QString::number(minutes) + "m" : QString::number(qMax<qint64>(1, minutes)) + "m");
        }
        m["label"] = label;
        return m;
    }
    void take(std::shared_ptr<Data> data) {
        m_data = data;
        m_ready = true;
        m_model->setCalendar(&m_data->calendar);
        emit loaded();
    }

    QString m_base;
    bool m_ready = false;
    std::shared_ptr<Data> m_data;
    CalendarModel *m_model;
};
