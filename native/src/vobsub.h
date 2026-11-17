#pragma once
// VobSub: DVD image subtitles as Matroska carries them (S_VOBSUB). The track's CodecPrivate is the .idx
// header (the picture `size:` and a 16-colour `palette:` of RGB); each block is one subpicture (SPU).
// Decoded as ffmpeg's dvdsubdec.c does: control sequences give the display start and stop (in 1024/90000
// s units after the block's time), the four colours and alphas picked from the palette, the rectangle,
// and where the two interlaced fields' 2-bit run-length data start. Pictures are placed in 1920x1080 by
// scaling the DVD frame (720x480 or 720x576, anamorphic) to it.
//
// Packets are kept by time in a window around where the player reads, like Pgs.
#include <QImage>
#include <QMap>
#include <QRegularExpression>

class VobSub {
public:
    void setHeader(const QByteArray &idx) {
        const QString text = QString::fromLatin1(idx);
        const auto size = QRegularExpression("size:\\s*(\\d+)x(\\d+)").match(text);
        if (size.hasMatch()) { m_width = size.captured(1).toInt(); m_height = size.captured(2).toInt(); }
        const auto pal = QRegularExpression("palette:\\s*([0-9a-fA-F, ]+)").match(text);
        if (pal.hasMatch()) {
            const QStringList c = pal.captured(1).split(',', QString::SkipEmptyParts);
            for (int i = 0; i < 16 && i < c.size(); i++) m_palette[i] = c[i].trimmed().toUInt(nullptr, 16);
        }
    }
    bool add(qint64 start, qint64 duration, const QByteArray &packet) {
        if (m_packets.contains(start)) return false;
        m_packets.insert(start, { packet, duration });
        return true;
    }
    void keepNear(qint64 ms) {
        while (!m_packets.isEmpty() && m_packets.lastKey() > ms + 30000) m_packets.erase(--m_packets.end());
        while (m_packets.size() > 1 && m_packets.firstKey() < ms - 90000 && (++m_packets.begin()).key() <= ms - 90000) m_packets.erase(m_packets.begin());
    }
    // the start of the packet showing at `ms`, or -1
    qint64 at(qint64 ms) const {
        auto it = m_packets.upperBound(ms);
        if (it == m_packets.begin()) return -1;
        --it;
        const Times t = times(it.value().data);
        const qint64 from = it.key() + t.start, to = t.stop >= 0 ? it.key() + t.stop : it.value().duration > 0 ? it.key() + it.value().duration : LLONG_MAX;
        return ms >= from && ms < to ? it.key() : -1;
    }
    QImage render(qint64 start, QRect &box) const {
        box = QRect();
        auto it = m_packets.find(start);
        if (it == m_packets.end()) return QImage();
        const QByteArray &p = it.value().data;
        auto b = reinterpret_cast<const uchar *>(p.constData()); const int n = p.size();
        if (n < 4) return QImage();
        int colour[4] = { 0, 1, 2, 3 }, alpha[4] = { 0, 15, 15, 15 }, x1 = 0, x2 = -1, y1 = 0, y2 = -1, field[2] = { -1, -1 };
        for (int cmd = u16(b + 2), guard = 0; cmd > 0 && cmd + 4 <= n && guard < 32; guard++) {
            const int next = u16(b + cmd + 2);
            for (int at = cmd + 4; at < n;) {
                const int op = b[at++];
                if (op == 0xff) break;
                if (op == 0x03 && at + 2 <= n) { colour[3] = b[at] >> 4; colour[2] = b[at] & 15; colour[1] = b[at + 1] >> 4; colour[0] = b[at + 1] & 15; at += 2; }
                else if (op == 0x04 && at + 2 <= n) { alpha[3] = b[at] >> 4; alpha[2] = b[at] & 15; alpha[1] = b[at + 1] >> 4; alpha[0] = b[at + 1] & 15; at += 2; }
                else if (op == 0x05 && at + 6 <= n) {
                    x1 = (b[at] << 4) | (b[at + 1] >> 4); x2 = ((b[at + 1] & 15) << 8) | b[at + 2];
                    y1 = (b[at + 3] << 4) | (b[at + 4] >> 4); y2 = ((b[at + 4] & 15) << 8) | b[at + 5]; at += 6;
                } else if (op == 0x06 && at + 4 <= n) { field[0] = u16(b + at); field[1] = u16(b + at + 2); at += 4; }
                else if (op > 0x02) break;                                    // unknown: stop reading this sequence
            }
            if (next <= cmd) break;
            cmd = next;
        }
        const int w = x2 - x1 + 1, h = y2 - y1 + 1;
        if (w <= 0 || h <= 0 || w > 4096 || h > 4096 || field[0] < 0 || field[1] < 0) return QImage();
        QRgb rgba[4];
        for (int i = 0; i < 4; i++) {
            const QRgb c = m_palette[colour[i] & 15]; const int a = alpha[i] * 17;
            rgba[i] = qRgba(qRed(c) * a / 255, qGreen(c) * a / 255, qBlue(c) * a / 255, a);
        }
        QImage out(w, h, QImage::Format_ARGB32_Premultiplied);
        out.fill(0);
        decode(b, n, field[0], out, 0, rgba);                             // even lines
        decode(b, n, field[1], out, 1, rgba);                             // odd lines
        const double sx = 1920.0 / m_width, sy = 1080.0 / m_height;
        box = QRect(qRound(x1 * sx), qRound(y1 * sy), qMax(1, qRound(w * sx)), qMax(1, qRound(h * sy)));
        return out.scaled(box.size(), Qt::IgnoreAspectRatio, Qt::SmoothTransformation);
    }

private:
    struct Packet { QByteArray data; qint64 duration; };
    struct Times { qint64 start = 0, stop = -1; };
    static int u16(const uchar *p) { return (p[0] << 8) | p[1]; }
    static Times times(const QByteArray &p) {
        Times t;
        auto b = reinterpret_cast<const uchar *>(p.constData()); const int n = p.size();
        if (n < 4) return t;
        for (int cmd = u16(b + 2), guard = 0; cmd > 0 && cmd + 4 <= n && guard < 32; guard++) {
            const qint64 date = (qint64(u16(b + cmd)) << 10) / 90;
            const int next = u16(b + cmd + 2);
            for (int at = cmd + 4; at < n;) {
                const int op = b[at++];
                if (op == 0x01) t.start = date;
                else if (op == 0x02) t.stop = date;
                else if (op == 0x03 || op == 0x04) at += 2;
                else if (op == 0x05) at += 6;
                else if (op == 0x06) at += 4;
                else if (op != 0x00) break;                                   // 0xff ends the sequence
            }
            if (next <= cmd) break;
            cmd = next;
        }
        return t;
    }
    // one field: every other line from `line`, nibble-coded runs (dvdsubdec's decode_run_2bit), each
    // line byte-aligned; a run code under 4 fills the rest of the line
    static void decode(const uchar *b, int n, int offset, QImage &out, int line, const QRgb *rgba) {
        qint64 bit = qint64(offset) * 8; const qint64 end = qint64(n) * 8;
        auto nibble = [&]() -> unsigned { if (bit + 4 > end) return 0; const unsigned v = (b[bit >> 3] >> (4 - (bit & 4))) & 15; bit += 4; return v; };
        const int w = out.width();
        for (int y = line; y < out.height() && bit < end; y += 2) {
            QRgb *row = reinterpret_cast<QRgb *>(out.scanLine(y));
            for (int x = 0; x < w;) {
                unsigned v = 0;
                for (unsigned t = 1; v < t && t <= 0x40; t <<= 2) v = (v << 4) | nibble();
                const int run = v < 4 ? w - x : qMin(int(v >> 2), w - x);
                const QRgb c = rgba[v & 3];
                if (c) for (int k = 0; k < run; k++) row[x + k] = c;
                x += run;
                if (bit >= end) break;
            }
            bit = (bit + 7) & ~qint64(7);
        }
    }
    QMap<qint64, Packet> m_packets;
    QRgb m_palette[16] = {};
    int m_width = 720, m_height = 480;
};
