#pragma once
// Pgs: Blu-ray image subtitles (HDMV PGS) as Matroska carries them (S_HDMV/PGS): each block is one
// display set's segments, without the "PG" headers of .sup files. Decoded as ffmpeg's pgssubdec.c does:
// a Presentation Composition (0x16) places objects on the video; a Palette (0x14) lists Y Cr Cb A
// entries (BT.709 for HD); an Object Definition (0x15) is a run-length coded bitmap, split across
// segments when long; End (0x80). A composition without objects clears the screen. A set that isn't an
// epoch start or acquisition point reuses the objects and palettes of the sets before it.
//
// A set usually comes as one block, but muxers that write a segment a block give several with the same
// time: they're joined (each block once, however often it's read). Sets are kept by start time. A film's track is about 6 KB a second and a remux can carry thirty, so
// only a window around where the player is reading stays (keepNear()): a seek makes the player read
// those bytes again, and the tee hands them over again. The window follows the reading, not the
// clock: right after a seek the player reads the new place before it reports its new position.
#include <QImage>
#include <QMap>
#include <QHash>
#include <QVector>
#include <QSet>

class Pgs {
public:
    // a display set (or part of one) at its start (ms); `duration` 0 when the next set ends it
    bool add(qint64 start, qint64 duration, const QByteArray &segments) {
        Set &set = m_sets[start];
        const uint key = qHash(segments);
        if (set.parts.contains(key)) return false;                  // read again after a seek
        set.parts.insert(key); set.data += segments; set.duration = qMax(set.duration, duration);
        return true;
    }
    // keeps the sets from 90 s before `ms` (the one showing then, and its epoch's start) to 30 s after:
    // the playhead trails the reading by the player's buffer. An epoch is followed back at most kEpoch
    // sets, here and when drawing, so one that never restarts can't hold a whole track
    static constexpr int kEpoch = 64;
    void keepNear(qint64 ms) {
        while (!m_sets.isEmpty() && m_sets.lastKey() > ms + 30000) m_sets.erase(--m_sets.end());
        auto keep = m_sets.upperBound(ms - 90000);
        if (keep == m_sets.begin()) return;
        --keep;
        for (int n = 0; keep != m_sets.begin() && !(state(keep.value().data) & 0xc0) && n < kEpoch; n++) --keep;
        while (m_sets.begin() != keep) m_sets.erase(m_sets.begin());
    }
    void clear() { m_sets.clear(); }
    // the start of the set showing at `ms`, or -1 when nothing shows
    qint64 at(qint64 ms) const {
        auto it = m_sets.upperBound(ms);
        if (it == m_sets.begin()) return -1;
        --it;
        if (it.value().duration > 0 && ms >= it.key() + it.value().duration) return -1;
        return it.key();
    }
    // the set starting at `start`, drawn into one image placed in 1920x1080 coordinates
    QImage render(qint64 start, QRect &box) const {
        box = QRect();
        auto end = m_sets.find(start);
        if (end == m_sets.end()) return QImage();
        auto from = end;
        for (int n = 0; from != m_sets.begin() && !(state(from.value().data) & 0xc0) && n < kEpoch; n++) --from;
        QHash<int, QVector<QRgb>> palettes;
        QHash<int, Object> objects;
        Composition shown;
        for (auto it = from;; ++it) {
            read(it.value().data, palettes, objects, shown);
            if (it == end) break;
        }
        if (shown.placed.isEmpty() || !palettes.contains(shown.palette) || shown.width <= 0) return QImage();
        const QVector<QRgb> &palette = palettes[shown.palette];
        QRect all;
        for (const Placed &p : shown.placed) if (objects.contains(p.object)) all |= QRect(p.x, p.y, objects[p.object].width, objects[p.object].height);
        if (all.isEmpty()) return QImage();
        QImage out(all.size(), QImage::Format_ARGB32_Premultiplied);
        out.fill(0);
        for (const Placed &p : shown.placed) if (objects.contains(p.object)) decode(objects[p.object], palette, out, p.x - all.x(), p.y - all.y());
        // UHD discs compose at 3840x2160: everything is placed in 1920x1080
        if (shown.width != 1920) {
            const double s = 1920.0 / shown.width;
            box = QRect(qRound(all.x() * s), qRound(all.y() * s), qMax(1, qRound(all.width() * s)), qMax(1, qRound(all.height() * s)));
            return out.scaled(box.size(), Qt::IgnoreAspectRatio, Qt::SmoothTransformation);
        }
        box = all;
        return out;
    }

private:
    struct Set { QByteArray data; qint64 duration = 0; QSet<uint> parts; };
    struct Object { int width = 0, height = 0; QByteArray rle; };
    struct Placed { int object, x, y; };
    struct Composition { int width = 0, height = 0, palette = 0; QVector<Placed> placed; };

    static int u16(const uchar *p) { return (p[0] << 8) | p[1]; }
    // the set's composition state: 0x80 epoch start, 0x40 acquisition point, 0 normal
    static int state(const QByteArray &set) {
        auto b = reinterpret_cast<const uchar *>(set.constData()); const int n = set.size();
        for (int i = 0; i + 3 <= n;) {
            const int type = b[i], len = u16(b + i + 1);
            if (type == 0x16 && len >= 11 && i + 3 + len <= n) return b[i + 3 + 7];
            i += 3 + len;
        }
        return 0;
    }
    static void read(const QByteArray &set, QHash<int, QVector<QRgb>> &palettes, QHash<int, Object> &objects, Composition &shown) {
        auto b = reinterpret_cast<const uchar *>(set.constData()); const int n = set.size();
        for (int i = 0; i + 3 <= n;) {
            const int type = b[i], len = u16(b + i + 1);
            const uchar *d = b + i + 3;
            if (i + 3 + len > n) break;
            if (type == 0x16 && len >= 11) {                                   // presentation composition
                if (d[7] & 0x80) objects.clear();                              // an epoch starts afresh
                shown.width = u16(d); shown.height = u16(d + 2); shown.palette = d[9]; shown.placed.clear();
                const int count = d[10];
                for (int k = 0, at = 11; k < count && at + 8 <= len; k++) {
                    shown.placed.append({ u16(d + at), u16(d + at + 4), u16(d + at + 6) });
                    at += (d[at + 3] & 0x80) ? 16 : 8;                         // cropped: four more fields
                }
            } else if (type == 0x14 && len >= 2) {                             // palette
                QVector<QRgb> &p = palettes[d[0]];
                if (p.isEmpty()) p.fill(0, 256);
                for (int at = 2; at + 5 <= len; at += 5) p[d[at]] = rgb(d[at + 1], d[at + 2], d[at + 3], d[at + 4]);
            } else if (type == 0x15 && len >= 4) {                             // object definition
                Object &o = objects[u16(d)];
                if (d[3] & 0x80) {                                             // first fragment
                    if (len < 11) { i += 3 + len; continue; }
                    o.width = u16(d + 7); o.height = u16(d + 9);
                    o.rle = QByteArray(reinterpret_cast<const char *>(d + 11), len - 11);
                } else o.rle.append(reinterpret_cast<const char *>(d + 4), len - 4);
            }
            i += 3 + len;
        }
    }
    // BT.709, limited range, premultiplied
    static QRgb rgb(int y, int cr, int cb, int a) {
        const double l = 1.164 * (y - 16);
        auto c = [](double v) { return qBound(0, int(v + 0.5), 255); };
        const int r = c(l + 1.793 * (cr - 128)), g = c(l - 0.213 * (cb - 128) - 0.533 * (cr - 128)), bl = c(l + 2.112 * (cb - 128));
        return qRgba(r * a / 255, g * a / 255, bl * a / 255, a);
    }
    // ffmpeg's decode_rle: a non-zero byte is one pixel; 0 starts a run (flags: 0x40 a 14-bit length,
    // 0x80 a colour follows, else colour 0); a run of 0 ends the line
    static void decode(const Object &o, const QVector<QRgb> &palette, QImage &out, int ox, int oy) {
        auto p = reinterpret_cast<const uchar *>(o.rle.constData()), end = p + o.rle.size();
        int x = 0, y = 0;
        while (p < end && y < o.height) {
            int colour = *p++, run = 1;
            if (colour == 0) {
                if (p >= end) break;
                const int flags = *p++;
                run = flags & 0x3f;
                if (flags & 0x40) { if (p >= end) break; run = (run << 8) | *p++; }
                colour = 0;
                if (flags & 0x80) { if (p >= end) break; colour = *p++; }
                if (!run) { x = 0; y++; continue; }                            // end of line
            }
            const QRgb c = palette[colour];
            run = qMin(run, o.width - x);
            if (c && run > 0 && oy + y < out.height()) {
                QRgb *row = reinterpret_cast<QRgb *>(out.scanLine(oy + y)) + ox + x;
                const int w = qMin(run, out.width() - ox - x);
                for (int k = 0; k < w; k++) row[k] = c;
            }
            x += qMax(run, 0);
        }
    }

    QMap<qint64, Set> m_sets;
};
