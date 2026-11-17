#pragma once
// Tracks: which audio and subtitle track plays, and the choices that decide it. Nothing here is our own
// invention:
// - Languages match as in mpv (misc/language.c, mp_match_lang): ISO 639-1 and both ISO 639-2 forms are
//   the same language ("ja", "jpn"; "fr", "fre", "fra"), and BCP 47 subtags ("pt-BR") narrow a match.
//   A track with no language, or "und", takes one from its title: a code in capitals ("JPN") or a
//   language's name in English or in itself ("Japanese", "日本語"), from Qt's CLDR data.
// - Tracks are chosen as mpv chooses them (player/loadfile.c, select_default_track and compare_track),
//   with mpv's defaults: subs-fallback=default (a subtitle flagged default plays when none matches the
//   language), subs-fallback-forced=yes (forced subtitles in the audio's language play), and
//   subs-with-matching-audio=yes (preferred subtitles play even when the audio is in that language).
//   Tracks the TV can't decode are never chosen on their own.
// - Subtitles named for signs follow mpv-sub-select's default rules (CogentRedTester/mpv-sub-select,
//   sub-select.json): with audio in another language, tracks whose title contains "sign" are passed
//   over for dialogue (its blacklist), and come back only if nothing else fits; with the audio in the
//   subtitles' language (a dub), they count as forced, as its whitelist of "sign" and "song" does.
//   Files often leave a "Signs & Songs" track unflagged, or flag it default.
// Preferences: for each group ("anime", "other"), the audio and subtitle language, or "off". Only an
// active choice in the menus (prefer()) sets one; whatever choose() falls back to is never saved.
// Subtitle delay is kept per file.
#include <QtQml>
#include <QLocale>
#include "store.h"

namespace lang {

struct Pair { const char *match, *canonical; };
static const Pair table[] = {
#include "langmap.inc"
};

// the ISO 639-2 code mpv compares by ("ja" -> "jpn", "fre" -> "fre", "fra" -> "fre")
inline QString canonical(const QString &code) {
    const QByteArray key = code.toLower().toLatin1();
    auto it = std::lower_bound(std::begin(table), std::end(table), key,
                               [](const Pair &p, const QByteArray &k) { return qstricmp(p.match, k.constData()) < 0; });
    return it != std::end(table) && qstricmp(it->match, key.constData()) == 0 ? QString::fromLatin1(it->canonical) : code.toLower();
}
// mp_match_lang: how well `lang` matches the list (0 none; earlier entries score higher)
inline int match(const QStringList &langs, const QString &lang) {
    if (lang.isEmpty()) return 0;
    const QStringList parts = lang.split('-');
    int best = 0;
    for (int idx = 0; idx < langs.size(); idx++) {
        const QStringList want = langs[idx].split('-');
        if (want.isEmpty() || want[0].isEmpty() || canonical(parts[0]) != canonical(want[0])) continue;
        int score = INT_MAX - idx, part = 1;
        for (; part < want.size() && part < parts.size(); part++)
            if (QString::compare(parts[part], want[part], Qt::CaseInsensitive)) score -= 1000;
        score -= (parts.size() - qMin(part, parts.size())) * 1000;
        best = qMax(best, score);
    }
    return best;
}
inline bool undefined(const QString &l) {
    return l.isEmpty() || !l.compare("und", Qt::CaseInsensitive) || !l.compare("mul", Qt::CaseInsensitive) || !l.compare("zxx", Qt::CaseInsensitive);
}
// language names (English and native, lower case) -> ISO 639-2, from Qt's CLDR data
inline const QHash<QString, QString> &names() {
    static const QHash<QString, QString> n = [] {
        QHash<QString, QString> out;
        for (int l = QLocale::AnyLanguage + 1; l <= QLocale::LastLanguage; l++) {
            const QLocale loc(static_cast<QLocale::Language>(l));
            if (loc.language() != l) continue;
            const QString code = canonical(loc.name().section('_', 0, 0));
            out.insert(QLocale::languageToString(loc.language()).toLower(), code);
            if (!loc.nativeLanguageName().isEmpty()) out.insert(loc.nativeLanguageName().toLower(), code);
        }
        return out;
    }();
    return n;
}
// a language read from a title: "JPN", "Japanese (original)", "English Dub", "日本語"; "" if none
inline QString fromTitle(const QString &title) {
    static const QRegularExpression word("[\\p{L}]+");
    QString found;
    for (auto it = word.globalMatch(title); it.hasNext();) {
        const QString w = it.next().captured(0);
        const QString code = names().value(w.toLower());
        if (!code.isEmpty()) return code;
        // a code in capitals, as in "ENG" or "JA", that the table knows
        if (found.isEmpty() && (w.size() == 2 || w.size() == 3) && w == w.toUpper() && canonical(w) != w.toLower()) found = canonical(w);
        else if (found.isEmpty() && w.size() == 3 && w == w.toUpper())
            for (const Pair &p : table) if (QString::compare(p.canonical, w, Qt::CaseInsensitive) == 0) { found = w.toLower(); break; }
    }
    return found;
}
// the language a track is in, as mpv would compare it
inline QString of(const QString &tag, const QString &title) { return undefined(tag) ? fromTitle(title) : tag; }
// a language's name, for the menus ("jpn" -> "Japanese")
inline QString name(const QString &code) {
    if (undefined(code)) return QString();
    QString two;
    for (const Pair &p : table) if (strlen(p.match) == 2 && canonical(p.match) == canonical(code)) { two = p.match; break; }
    const QLocale loc(two.isEmpty() ? code : two);
    return loc.language() == QLocale::C ? code : QLocale::languageToString(loc.language());
}

} // namespace lang

class Tracks : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString dataDir READ dataDir WRITE setDataDir NOTIFY changed)
    Q_PROPERTY(QString status MEMBER m_status NOTIFY changed)    // the last save, for the lab
public:
    QString dataDir() const { return m_dir; }
    void setDataDir(const QString &d) { m_dir = d; m_store.setDir(d); emit changed(); }

    // Chooses the tracks to play. `tracks` are { id, type: "audio" | "sub", lang, title, default, forced,
    // playable, external } in container order (`external`: loaded for the file, as the OpenSubtitles
    // addon's are). Returns { audio: id or -1, sub: id or -1, audioOff, subsOff }.
    Q_INVOKABLE QVariantMap choose(const QVariantList &tracks, const QString &group) {
        const QJsonObject pref = m_store.data().value("prefs").toObject().value(group).toObject();
        const QString audioPref = pref.value("audio").toString(), subPref = pref.value("sub").toString();
        QVector<T> all;
        for (const QVariant &v : tracks) {
            const QVariantMap m = v.toMap();
            static const QRegularExpression sign("sign|song", QRegularExpression::CaseInsensitiveOption);
            const QString title = m.value("title").toString();
            all.append({ m.value("id").toInt(), m.value("type").toString() == "sub",
                         lang::of(m.value("lang").toString(), title),
                         m.value("default").toBool(), m.value("forced").toBool(), m.value("playable", true).toBool(),
                         title.contains(QRegularExpression("sign", QRegularExpression::CaseInsensitiveOption)), sign.match(title).hasMatch(),
                         m.value("external").toBool(), QRegularExpression("^(S_HDMV/PGS|S_VOBSUB)").match(m.value("codec").toString()).hasMatch() });
        }
        const QStringList alang = audioPref.isEmpty() || audioPref == "off" ? QStringList() : QStringList { audioPref };
        const T *audio = pick(all, false, alang, QString());
        const QStringList slang = subPref.isEmpty() || subPref == "off" ? QStringList() : QStringList { subPref };
        const T *sub = subPref == "off" ? nullptr : pick(all, true, slang, audio ? audio->lang : QString());
        return { { "audio", audio ? audio->id : -1 }, { "sub", sub ? sub->id : -1 },
                 { "audioOff", audioPref == "off" }, { "subsOff", subPref == "off" } };
    }
    // An active choice in a menu: `type` "audio" or "sub", `language` the chosen track's (as passed to
    // choose(): tag and title) or "off". It becomes the default for the group.
    Q_INVOKABLE void prefer(const QString &group, const QString &type, const QString &tag, const QString &title) {
        const QString l = tag == "off" ? QString("off") : lang::canonical(lang::of(tag, title));
        QJsonObject prefs = m_store.data().value("prefs").toObject(), g = prefs.value(group).toObject();
        if (l.isEmpty()) g.remove(type); else g[type] = l;     // a track with no language clears it
        prefs[group] = g; m_store.data()["prefs"] = prefs;
        // how often each language is picked, for the lists' order (topLanguages)
        if (!l.isEmpty() && l != "off") {
            QJsonObject picks = m_store.data().value("picks").toObject(), counts = picks.value(type).toObject();
            const QString base = lang::canonical(l.section('-', 0, 0));
            counts[base] = counts.value(base).toInt() + 1;
            picks[type] = counts; m_store.data()["picks"] = picks;
        }
        m_status = m_store.save(); emit changed();
    }
    // The three languages a list shows before "Other languages": the most picked for that type
    // ("audio", "sub"), then English, Japanese and Arabic to make up three
    Q_INVOKABLE QStringList topLanguages(const QString &type) {
        static const QStringList defaults { "eng", "jpn", "ara" };
        const QJsonObject counts = m_store.data().value("picks").toObject().value(type).toObject();
        QStringList codes = counts.keys();
        std::sort(codes.begin(), codes.end(), [&](const QString &a, const QString &b) {
            const int ca = counts.value(a).toInt(), cb = counts.value(b).toInt();
            if (ca != cb) return ca > cb;
            const int da = defaults.indexOf(a), db = defaults.indexOf(b);
            return (da < 0 ? 99 : da) < (db < 0 ? 99 : db);
        });
        for (const QString &d : defaults) if (!codes.contains(d)) codes << d;
        return codes.mid(0, 3);
    }
    // a track's language without its region, as topLanguages() names it ("pt-BR" -> "por")
    Q_INVOKABLE QString baseLanguage(const QString &tag, const QString &title) const { return lang::canonical(lang::of(tag, title).section('-', 0, 0)); }
    // the lab: forget a group's choices, or every one (test runs make choices of their own)
    Q_INVOKABLE void clearPreferences(const QString &group = QString()) {
        QJsonObject prefs = m_store.data().value("prefs").toObject();
        if (group.isEmpty()) { prefs = {}; m_store.data().remove("picks"); } else prefs.remove(group);
        m_store.data()["prefs"] = prefs; m_status = m_store.save(); emit changed();
    }
    Q_INVOKABLE QVariantMap preferences(const QString &group) { return m_store.data().value("prefs").toObject().value(group).toObject().toVariantMap(); }
    // subtitle delay for a file, in ms (positive shows them later)
    Q_INVOKABLE int delay(const QString &file) { return m_store.data().value("delays").toObject().value(file).toInt(); }
    Q_INVOKABLE void setDelay(const QString &file, int ms) {
        QJsonObject d = m_store.data().value("delays").toObject();
        if (ms) d[file] = ms; else d.remove(file);
        m_store.data()["delays"] = d; m_status = m_store.save(); emit changed();
    }
    // a track's language and its name, for the menus
    Q_INVOKABLE QString languageOf(const QString &tag, const QString &title) const { return lang::of(tag, title); }
    Q_INVOKABLE QString languageName(const QString &code) const { return lang::name(code); }
signals:
    void changed();
private:
    // signs: the title names signs (sub-select's blacklist); signsOrSongs: signs or songs (its whitelist)
    // external: loaded for the file (mpv's auto_loaded)
    // image: a picture subtitle (PGS, VobSub)
    struct T { int id; bool sub; QString lang; bool def, forced, playable, signs, signsOrSongs, external, image; bool forcedSelect = false; };
    // mpv's compare_track for tracks of one file: is a preferred over b? mpv ranks auto-loaded tracks
    // after the file's own before it looks at languages; here a track in the chosen language comes first
    // (choose() only sees tracks that qualify), then the file's own, then how closely the tag matches
    static bool better(const T &a, const T &b, const QStringList &langs) {
        const int la = lang::match(langs, a.lang), lb = lang::match(langs, b.lang);
        if ((la > 0) != (lb > 0)) return la > 0;
        if (a.external != b.external) return !a.external;
        if (la != lb) return la > lb;
        if (a.forcedSelect != b.forcedSelect) return a.forcedSelect;
        if (a.def != b.def) return a.def;
        if (a.sub && (a.forced || a.signsOrSongs) != (b.forced || b.signsOrSongs)) return !(a.forced || a.signsOrSongs);
        if (a.image != b.image) return !a.image;                    // text before pictures
        return a.id <= b.id;
    }
    // mpv's select_default_track, with mpv's default options; for subtitles, a first pass that passes over
    // signs tracks when the audio is in another language, then one that doesn't
    static const T *pick(QVector<T> &all, bool sub, const QStringList &langs, const QString &audioLang) {
        const T *best = pickPass(all, sub, langs, audioLang, true);
        return best || !sub ? best : pickPass(all, sub, langs, audioLang, false);
    }
    static const T *pickPass(QVector<T> &all, bool sub, const QStringList &langs, const QString &audioLang, bool strict) {
        const T *best = nullptr;
        for (T &t : all) {
            if (t.sub != sub || !t.playable) continue;
            if (sub) {
                const bool audioMatches = lang::match({ audioLang }, t.lang) > 0;
                if (strict && !audioMatches && t.signs) continue;          // sub-select: blacklist "sign"
                const bool forced = (t.forced || t.signsOrSongs) && audioMatches;   // subs-fallback-forced=yes; sub-select's whitelist
                const bool langMatch = lang::match(langs, t.lang) > 0;
                const bool fallback = t.def;                                // subs-fallback=default
                if (!forced && !langMatch && !fallback) continue;           // (subs-with-matching-audio=yes)
                t.forcedSelect = forced;
            }
            if (!best || better(t, *best, langs)) best = &t;
        }
        return best;
    }
    JsonStore m_store { "tracks.json" };
    QString m_dir, m_status;
};
