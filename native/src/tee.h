#pragma once
// Tee: the player loads streams through a local HTTP server, which fetches every byte range from the
// real URL once, hands it to the player, and reads the same bytes for what LG's player doesn't give us:
// the file's tracks (names, languages, default/forced/hearing-impaired/commentary flags), attached
// fonts, chapters and the subtitle blocks. Ported from stremio-webos service/ass-tee.js and
// mkv-subs.js, which proved the design on this TV: one download, subtitles from the bytes the player
// pulls anyway. Matroska, and MP4's text subtitles; anything else passes through untouched.
//
// It runs on its own thread (network, parsing and socket writes never touch the GUI thread) and talks
// to the rest through queued signals. Each connection holds at most kReadAhead + kChunk, so memory
// stays bounded whatever the file's size.
#include <QtQml>
#include <QTcpServer>
#include <QTcpSocket>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QThread>
#include <functional>
#include <atomic>

// ---- Matroska, streamed ----------------------------------------------------------------------------
// pushAt(offset, bytes): contiguous ranges extend the parse; a jump (the player seeked) restarts at the
// next real Cluster, using each cluster's own timestamp. Video and audio blocks (nearly all the bytes)
// are skipped from the track number at their head, without being copied. The player reads with several
// connections, each with its own parser; the one that reads the head finds the subtitle tracks and the
// timescale, and shares them (`Shared`) with the parsers of connections that start mid-file.
class MkvSubs {
public:
    struct Shared { QSet<int> subs; quint64 scale = 1000000; int matroska = -1; };
    explicit MkvSubs(std::shared_ptr<Shared> shared = std::make_shared<Shared>()) : m_shared(shared) {}
    std::function<void()> onTracksDone;
    struct Track { int number = 0, type = 0; QString codec, lang, name; QByteArray priv; bool def = true, forced = false, hi = false, commentary = false; };
    std::function<void(const Track &)> onTrack;
    std::function<void(const QString &, const QByteArray &)> onFont;
    std::function<void(qint64, qint64, const QString &)> onChapter;           // start ms, end ms, title
    std::function<void(int, qint64, qint64, const QByteArray &)> onBlock;      // track, start ms, duration ms, payload
    bool clusterSeen = false;                                                  // past the header elements
    void pushAt(qint64 offset, const QByteArray &bytes) {
        int &m_matroska = m_shared->matroska;
        if (m_matroska == 0 || (m_matroska == -1 && offset != 0 && m_pending.isNull())) return;   // mid-file before the head is known
        if (!m_pending.isNull() && offset == m_abs + m_pending.size() + m_heldLen) {      // contiguous
            m_held << bytes; m_heldLen += bytes.size();
            if (m_pending.size() + m_heldLen < m_want) return;                          // a big leaf: join once
            for (const QByteArray &b : m_held) m_pending += b;
        } else {                                                                         // (re)start
            m_pending = bytes; m_abs = offset; m_pos = offset;
            m_stack.clear();
            if (offset != 0) { m_stack.append({ SEGMENT, LLONG_MAX }); m_resync = true; }
        }
        m_held.clear(); m_heldLen = 0; m_want = 0;
        if (m_matroska == -1 && m_abs == 0) {
            if (m_pending.size() < 4) return;
            m_matroska = be32(0) == 0x1a45dfa3 ? 1 : 0;
            if (!m_matroska) { m_pending.clear(); return; }
        }
        parse();
    }

private:
    enum : quint32 {
        SEGMENT = 0x18538067, INFO = 0x1549a966, TIMESTAMPSCALE = 0x2ad7b1, TRACKS = 0x1654ae6b, TRACKENTRY = 0xae,
        TRACKNUMBER = 0xd7, TRACKTYPE = 0x83, CODECID = 0x86, CODECPRIVATE = 0x63a2, LANGUAGE = 0x22b59c, LANGUAGEBCP47 = 0x22b59d,
        NAME = 0x536e, FLAGDEFAULT = 0x88, FLAGFORCED = 0x55aa, FLAGHI = 0x55ab, FLAGCOMMENTARY = 0x55af,
        ATTACHMENTS = 0x1941a469, ATTACHEDFILE = 0x61a7, FILENAME = 0x466e, FILEDATA = 0x465c,
        CHAPTERS = 0x1043a770, EDITIONENTRY = 0x45b9, CHAPTERATOM = 0xb6, CHAPTERDISPLAY = 0x80, CHAPSTART = 0x91, CHAPEND = 0x92, CHAPSTRING = 0x85,
        CLUSTER = 0x1f43b675, TIMESTAMP = 0xe7, SIMPLEBLOCK = 0xa3, BLOCKGROUP = 0xa0, BLOCK = 0xa1, BLOCKDURATION = 0x9b,
    };
    static bool master(quint32 id) {
        switch (id) { case SEGMENT: case INFO: case TRACKS: case TRACKENTRY: case ATTACHMENTS: case ATTACHEDFILE: case CHAPTERS:
                      case EDITIONENTRY: case CHAPTERATOM: case CHAPTERDISPLAY: case CLUSTER: case BLOCKGROUP: return true; }
        return false;
    }
    static constexpr qint64 kMaxLeaf = 64 << 20;
    struct Open { quint32 id; qint64 end; };

    quint32 be32(int at) const { auto p = reinterpret_cast<const uchar *>(m_pending.constData()) + at; return (p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3]; }
public:
    // an element ID (marker kept) at buf[pos]: its length, or 0 if not all there
    static int idAt(const uchar *b, qint64 n, qint64 pos, quint32 &id) {
        if (pos >= n) return 0;
        int len = 1; uchar mask = 0x80;
        while (len <= 4 && !(b[pos] & mask)) { mask >>= 1; len++; }
        if (len > 4 || pos + len > n) return 0;
        id = 0; for (int i = 0; i < len; i++) id = (id << 8) | b[pos + i];
        return len;
    }
    // a size vint (marker stripped): its length, or 0; `unknown` when all ones
    static int sizeAt(const uchar *b, qint64 n, qint64 pos, qint64 &value, bool &unknown) {
        if (pos >= n) return 0;
        int len = 1; uchar mask = 0x80;
        while (len <= 8 && !(b[pos] & mask)) { mask >>= 1; len++; }
        if (len > 8 || pos + len > n) return 0;
        value = b[pos] & (mask - 1); unknown = value == mask - 1;
        for (int i = 1; i < len; i++) { value = (value << 8) | b[pos + i]; if (b[pos + i] != 0xff) unknown = false; }
        return len;
    }
    static quint64 uintOf(const uchar *b, qint64 s, qint64 e) { quint64 v = 0; for (qint64 i = s; i < e; i++) v = (v << 8) | b[i]; return v; }
private:

    void openMaster(quint32 id) {
        if (id == CLUSTER) clusterSeen = true;
        if (id == TRACKENTRY) m_track = Track();
        if (id == ATTACHEDFILE) { m_fontName.clear(); m_fontData.clear(); }
        if (id == CHAPTERATOM) { m_chapStart = m_chapEnd = -1; m_chapTitle.clear(); }
    }
    void closeMaster(quint32 id) {
        if (id == TRACKENTRY) { if (m_track.type == 0x11) m_shared->subs.insert(m_track.number); if (onTrack) onTrack(m_track); }
        if (id == TRACKS && onTracksDone) onTracksDone();
        if (id == ATTACHEDFILE && !m_fontData.isEmpty() && onFont) onFont(m_fontName, m_fontData);
        if (id == CHAPTERATOM && m_chapStart >= 0 && onChapter) onChapter(m_chapStart / 1000000, m_chapEnd >= 0 ? m_chapEnd / 1000000 : -1, m_chapTitle);
    }
    void leaf(quint32 id, const uchar *b, qint64 s, qint64 e) {
        const QByteArray text = QByteArray(reinterpret_cast<const char *>(b + s), int(e - s));
        switch (id) {
        case TIMESTAMPSCALE: m_shared->scale = uintOf(b, s, e); break;
        case TRACKNUMBER: m_track.number = int(uintOf(b, s, e)); break;
        case TRACKTYPE: m_track.type = int(uintOf(b, s, e)); break;
        case CODECID: m_track.codec = QString::fromUtf8(text); break;
        case CODECPRIVATE: m_track.priv = text; break;
        case LANGUAGE: if (m_track.lang.isEmpty()) m_track.lang = QString::fromUtf8(text); break;
        case LANGUAGEBCP47: m_track.lang = QString::fromUtf8(text); break;        // the newer field wins
        case NAME: m_track.name = QString::fromUtf8(text); break;
        case FLAGDEFAULT: m_track.def = uintOf(b, s, e); break;
        case FLAGFORCED: m_track.forced = uintOf(b, s, e); break;
        case FLAGHI: m_track.hi = uintOf(b, s, e); break;
        case FLAGCOMMENTARY: m_track.commentary = uintOf(b, s, e); break;
        case FILENAME: m_fontName = QString::fromUtf8(text); break;
        case FILEDATA: m_fontData = text; break;
        case CHAPSTART: m_chapStart = qint64(uintOf(b, s, e)); break;
        case CHAPEND: m_chapEnd = qint64(uintOf(b, s, e)); break;
        case CHAPSTRING: if (m_chapTitle.isEmpty()) m_chapTitle = QString::fromUtf8(text); break;
        case TIMESTAMP: m_clusterTs = qint64(uintOf(b, s, e)); break;
        case SIMPLEBLOCK: block(text, 0); break;
        case BLOCK: m_pendBlock = text; break;                                   // its BlockDuration follows
        case BLOCKDURATION: if (!m_pendBlock.isNull()) { block(m_pendBlock, qint64(uintOf(b, s, e))); m_pendBlock.clear(); } break;
        }
    }
    bool isSub(const uchar *b, qint64 n, qint64 pos) const {
        qint64 tn; bool u; return sizeAt(b, n, pos, tn, u) && m_shared->subs.contains(int(tn));
    }
    void block(const QByteArray &data, qint64 durTicks) {
        auto b = reinterpret_cast<const uchar *>(data.constData());
        qint64 tn; bool u; int l = sizeAt(b, data.size(), 0, tn, u);
        if (!l || !m_shared->subs.contains(int(tn)) || l + 3 > data.size()) return;
        qint16 rel = qint16((b[l] << 8) | b[l + 1]);
        QByteArray payload = data.mid(l + 3);
        // zlib-compressed tracks (ContentCompression algo 0, common in anime) start with 0x78
        if (payload.size() > 2 && uchar(payload[0]) == 0x78 && (uchar(payload[1]) == 0x01 || uchar(payload[1]) == 0x9c || uchar(payload[1]) == 0xda)) {
            QByteArray z(4, 0); const quint32 guess = quint32(payload.size()) * 8;
            z[0] = char(guess >> 24); z[1] = char(guess >> 16); z[2] = char(guess >> 8); z[3] = char(guess);
            payload = qUncompress(z + payload);
            if (payload.isEmpty()) return;
        }
        const qint64 scale = qint64(m_shared->scale), startMs = (m_clusterTs + rel) * scale / 1000000, durMs = durTicks * scale / 1000000;
        if (onBlock) onBlock(int(tn), startMs, durMs, payload);
    }
    // the next real Cluster: its ID, a size, then a Timestamp (or CRC-32/Void then Timestamp); the bare ID
    // turns up by chance inside video
    qint64 findCluster(qint64 from) const {
        auto b = reinterpret_cast<const uchar *>(m_pending.constData()); const qint64 n = m_pending.size();
        for (qint64 i = from; i + 4 <= n; i++) {
            if (b[i] != 0x1f || b[i + 1] != 0x43 || b[i + 2] != 0xb6 || b[i + 3] != 0x75) continue;
            qint64 sz; bool u; int sl = sizeAt(b, n, i + 4, sz, u);
            if (!sl) return -1;
            qint64 child = i + 4 + sl;
            if (child + 1 >= n) return -1;
            if (b[child] == 0xe7) return i;
            if (b[child] == 0xbf || b[child] == 0xec) {
                qint64 cs; int cl = sizeAt(b, n, child + 1, cs, u);
                if (!cl) continue;
                qint64 next = child + 1 + cl + cs;
                if (next >= n) return -1;
                if (b[next] == 0xe7) return i;
            }
        }
        return -1;
    }
    void parse() {
        if (m_resync) {
            qint64 c = findCluster(m_pos - m_abs);
            if (c < 0) { trim(true); return; }
            m_pos = m_abs + c; m_resync = false;
        }
        auto b = reinterpret_cast<const uchar *>(m_pending.constData()); const qint64 n = m_pending.size();
        while (true) {
            while (!m_stack.isEmpty() && m_pos >= m_stack.last().end) closeMaster(m_stack.takeLast().id);
            const qint64 local = m_pos - m_abs;
            if (local >= n) break;
            quint32 id; int il = idAt(b, n, local, id); if (!il) break;
            qint64 size; bool unknown; int sl = sizeAt(b, n, local + il, size, unknown); if (!sl) break;
            const qint64 dsLocal = local + il + sl, dsAbs = m_pos + il + sl, deAbs = unknown ? LLONG_MAX : dsAbs + size;
            if (master(id)) { openMaster(id); m_stack.append({ id, deAbs }); m_pos = dsAbs; continue; }
            if (deAbs == LLONG_MAX) { m_pos = dsAbs; continue; }
            if ((id == SIMPLEBLOCK || id == BLOCK) && dsLocal + 8 <= n && !isSub(b, n, dsLocal)) { m_pos = deAbs; continue; }
            if (size > kMaxLeaf) { m_pos = deAbs; continue; }
            if (deAbs - m_abs > n) { m_want = deAbs - m_pos; break; }               // wait for the whole leaf
            leaf(id, b, dsLocal, deAbs - m_abs);
            m_pos = deAbs;
        }
        trim(false);
    }
    void trim(bool keepTail) {
        qint64 drop = m_pos - m_abs;
        if (keepTail) drop = qMax<qint64>(0, m_pending.size() - 64);
        if (drop > m_pending.size()) drop = m_pending.size();
        if (drop > 0) { m_pending.remove(0, int(drop)); m_abs += drop; if (m_pos < m_abs) m_pos = m_abs; }
    }

    std::shared_ptr<Shared> m_shared;
    QByteArray m_pending, m_pendBlock;
    QList<QByteArray> m_held;
    qint64 m_heldLen = 0, m_want = 0, m_abs = 0, m_pos = 0, m_clusterTs = 0;
    bool m_resync = false;
    QVector<Open> m_stack;
    Track m_track;
    QString m_fontName, m_chapTitle;
    QByteArray m_fontData;
    qint64 m_chapStart = -1, m_chapEnd = -1;
};

// ---- MP4, streamed -------------------------------------------------------------------------------------
// Text subtitle tracks (tx3g, ffmpeg's mov_text) of an MP4/MOV file. The player reads the top-level boxes
// from the start: ftyp, then moov (the index) or mdat (the media) and, when moov comes last, it jumps
// there. Each connection walks top-level boxes from wherever one starts; the one that reads moov finds the
// text tracks and their sample tables (stts, stsc, stsz, stco/co64, as ISO 14496-12 lays them out), and
// from then on every connection picks out the samples whose bytes it passes. A sample is a 16-bit text
// length and the text (style boxes after it are ignored). A track's edit list (elst) moves its times as
// ffmpeg's mov.c applies it: empty edits delay it, the first edit's media time is where it starts.
class Mp4Subs {
public:
    struct Sample { qint64 offset; int size, track; qint64 start, duration; };      // ms
    struct Shared {
        int mp4 = -1;                                     // -1 unknown, 0 no, 1 yes
        bool indexed = false;                             // moov read
        QSet<qint64> boxes;                               // top-level box starts seen
        QVector<Sample> samples;                          // by offset
    };
    struct Track { int number; QString lang, name; };
    explicit Mp4Subs(std::shared_ptr<Shared> shared) : m_shared(shared) {}
    std::function<void(const QVector<Track> &)> onTracks;
    std::function<void(int, qint64, qint64, const QByteArray &)> onBlock;         // track, start, duration, UTF-8 text
    void pushAt(qint64 offset, const QByteArray &bytes) {
        Shared &sh = *m_shared;
        if (sh.mp4 == 0) return;
        if (sh.mp4 == -1) {
            if (offset != 0) return;
            if (bytes.size() < 8) { sh.mp4 = 0; return; }
            sh.mp4 = bytes.mid(4, 4) == "ftyp" ? 1 : 0;
            if (!sh.mp4) return;
            sh.boxes.insert(0);
        }
        if (offset != m_end) { m_buf.clear(); m_next = sh.boxes.contains(offset) ? offset : -1; m_bufAt = offset; }
        m_end = offset + bytes.size();
        samples(offset, bytes);
        if (m_next < 0) return;
        // the top-level walk. m_buf holds the bytes from m_bufAt (the next box) on; a box's body is
        // skipped, except moov, which is read whole
        if (m_buf.isEmpty()) { if (m_bufAt >= m_end) return; m_buf = bytes.mid(int(m_bufAt - offset)); }
        else m_buf += bytes;
        while (m_next >= 0) {
            const qint64 local = m_next - m_bufAt;
            if (local + 8 > m_buf.size()) break;
            qint64 size = be32(local); int head = 8;
            if (size == 1) { if (local + 16 > m_buf.size()) break; size = qint64(be64(local + 8)); head = 16; }
            if (size < head) { m_next = -1; break; }                                // 0: to the end of the file
            if (m_buf.mid(int(local) + 4, 4) == "moov" && !sh.indexed) {
                if (size > kMaxMoov) { sh.indexed = true; if (onTracks) onTracks({}); m_next = -1; break; }
                if (local + size > m_buf.size()) break;                             // wait for all of it
                moov(m_buf.mid(int(local + head), int(size - head)));
            }
            m_next += size; sh.boxes.insert(m_next);
        }
        if (m_next < 0) { m_buf.clear(); return; }
        const qint64 drop = m_next - m_bufAt;
        if (drop >= m_buf.size()) m_buf.clear(); else if (drop > 0) m_buf.remove(0, int(drop));
        m_bufAt = m_next;
    }
private:
    static constexpr qint64 kMaxMoov = 32 << 20;
    quint32 be32(qint64 at) const { return be32(m_buf, at); }
    quint64 be64(qint64 at) const { return (quint64(be32(at)) << 32) | be32(at + 4); }
    static quint32 be32(const QByteArray &b, qint64 at) {
        auto p = reinterpret_cast<const uchar *>(b.constData()) + at; return (quint32(p[0]) << 24) | (p[1] << 16) | (p[2] << 8) | p[3];
    }
    // the boxes inside `b` from `from`: type -> payload, for each
    template <typename F> static void boxes(const QByteArray &b, int from, F each) {
        for (qint64 at = from; at + 8 <= b.size();) {
            qint64 size = be32(b, at); int head = 8;
            if (size == 1 && at + 16 <= b.size()) { size = qint64((quint64(be32(b, at + 8)) << 32) | be32(b, at + 12)); head = 16; }
            if (size == 0) size = b.size() - at;
            if (size < head || at + size > b.size()) return;
            each(b.mid(int(at) + 4, 4), b.mid(int(at + head), int(size - head)));
            at += size;
        }
    }
    void moov(const QByteArray &moov) {
        Shared &sh = *m_shared;
        QVector<Track> tracks;
        qint64 movieScale = 0;
        boxes(moov, 0, [&](const QByteArray &type, const QByteArray &d) {
            if (type == "mvhd" && d.size() >= 24) movieScale = be32(d, d[0] == 1 ? 20 : 12);
        });
        boxes(moov, 0, [&](const QByteArray &type, const QByteArray &trak) {
            if (type != "trak") return;
            int id = 0, scale = 0; QString lang, name, handler, format;
            QByteArray stts, stsc, stsz, stco, elst; bool wide = false;
            std::function<void(const QByteArray &)> walk = [&](const QByteArray &box) {
                boxes(box, 0, [&](const QByteArray &t, const QByteArray &d) {
                    if (t == "mdia" || t == "minf" || t == "stbl" || t == "edts") walk(d);
                    else if (t == "elst") elst = d;
                    else if (t == "tkhd" && d.size() >= 24) id = int(be32(d, d[0] == 1 ? 20 : 12));
                    else if (t == "mdhd" && d.size() >= 24) {
                        const int v1 = d[0] == 1; scale = int(be32(d, v1 ? 20 : 12));
                        const int packed = (uchar(d[v1 ? 32 : 20]) << 8) | uchar(d[v1 ? 33 : 21]);
                        for (int k = 2; k >= 0; k--) lang += QChar(((packed >> (5 * k)) & 31) + 0x60);
                    } else if (t == "hdlr" && d.size() >= 24) {
                        handler = QString::fromLatin1(d.mid(8, 4)); name = QString::fromUtf8(d.mid(24)).remove(QChar(0)).trimmed();
                    } else if (t == "stsd" && d.size() >= 16) format = QString::fromLatin1(d.mid(12, 4));
                    else if (t == "stts") stts = d; else if (t == "stsc") stsc = d; else if (t == "stsz") stsz = d;
                    else if (t == "stco") stco = d; else if (t == "co64") { stco = d; wide = true; }
                });
            };
            walk(trak);
            if (format != "tx3g" || !scale || stts.size() < 8 || stsc.size() < 8 || stsz.size() < 12 || stco.size() < 8) return;
            // a handler's name is often just the muxer's ("SubtitleHandler", "Core Media Text")
            if (name.contains(QRegularExpression("handler|core media|^text$", QRegularExpression::CaseInsensitiveOption))) name.clear();
            tracks.append({ id, lang == "und" ? QString() : lang, name });
            // sizes, then chunks (stsc runs of samples per chunk), then times (stts runs of durations)
            const int count = int(be32(stsz, 8)), fixed = int(be32(stsz, 4));
            const int chunks = int(be32(stco, 4)), runs = int(be32(stsc, 4));
            if (count <= 0 || count > 200000 || (!fixed && stsz.size() < 12 + 4 * count)) return;
            QVector<Sample> out; out.reserve(count);
            int sample = 0;
            for (int r = 0; r < runs && 8 + 12 * r + 12 <= stsc.size(); r++) {
                const int first = int(be32(stsc, 8 + 12 * r)), per = int(be32(stsc, 12 + 12 * r));
                const int last = r + 1 < runs ? int(be32(stsc, 8 + 12 * (r + 1))) - 1 : chunks;
                for (int c = first; c <= last && c <= chunks; c++) {
                    const int at = 8 + (wide ? 8 : 4) * (c - 1);
                    if (at + (wide ? 8 : 4) > stco.size()) break;
                    qint64 offset = wide ? qint64((quint64(be32(stco, at)) << 32) | be32(stco, at + 4)) : be32(stco, at);
                    for (int k = 0; k < per && sample < count; k++, sample++) {
                        const int size = fixed ? fixed : int(be32(stsz, 12 + 4 * sample));
                        out.append({ offset, size, id, 0, 0 });
                        offset += size;
                    }
                }
            }
            // the edit list: empty edits (media time -1) delay the track, in the movie's timescale; the first
            // real edit says which media time plays first
            qint64 delayMs = 0, firstMs = 0;
            if (elst.size() >= 8 && movieScale > 0) {
                const bool v1 = elst.at(0) == 1; const int entry = v1 ? 20 : 12;
                for (int e = 0, n = int(be32(elst, 4)); e < n && 8 + entry * (e + 1) <= elst.size(); e++) {
                    const int at = 8 + entry * e;
                    const qint64 duration = v1 ? qint64((quint64(be32(elst, at)) << 32) | be32(elst, at + 4)) : be32(elst, at);
                    const qint64 media = v1 ? qint64((quint64(be32(elst, at + 8)) << 32) | be32(elst, at + 12)) : qint32(be32(elst, at + 4));
                    if (media == -1) { delayMs += duration * 1000 / movieScale; continue; }
                    firstMs = media * 1000 / scale;
                    break;
                }
            }
            qint64 t = 0; int i = 0;
            for (int r = 0; r < int(be32(stts, 4)) && 8 + 8 * r + 8 <= stts.size(); r++) {
                const int n = int(be32(stts, 8 + 8 * r)); const qint64 d = be32(stts, 12 + 8 * r);
                for (int k = 0; k < n && i < out.size(); k++, i++) { out[i].start = t * 1000 / scale - firstMs + delayMs; out[i].duration = d * 1000 / scale; t += d; }
            }
            sh.samples += out;
        });
        std::sort(sh.samples.begin(), sh.samples.end(), [](const Sample &a, const Sample &b) { return a.offset < b.offset; });
        sh.indexed = true;
        if (onTracks) onTracks(tracks);
    }
    // the samples inside [offset, offset + bytes), and one cut by the end, finished by the next piece
    void samples(qint64 offset, const QByteArray &bytes) {
        const QVector<Sample> &all = m_shared->samples;
        if (all.isEmpty()) return;
        if (m_partial.size() && offset != m_partialEnd) m_partial.clear();      // the player jumped: it's gone
        if (m_partial.size()) {
            m_partial += bytes.left(int(m_partialWant - m_partial.size()));
            m_partialEnd = offset + bytes.size();
            if (m_partial.size() >= m_partialWant) { emitSample(m_partialSample, m_partial); m_partial.clear(); }
        }
        auto it = std::lower_bound(all.begin(), all.end(), offset, [](const Sample &s, qint64 o) { return s.offset < o; });
        const qint64 end = offset + bytes.size();
        for (; it != all.end() && it->offset < end; ++it) {
            const int local = int(it->offset - offset);
            if (it->offset + it->size <= end) emitSample(*it, bytes.mid(local, it->size));
            else { m_partialSample = *it; m_partial = bytes.mid(local); m_partialWant = it->size; m_partialEnd = end; }
        }
    }
    void emitSample(const Sample &s, const QByteArray &data) {
        if (data.size() < 2 || !onBlock) return;
        const int len = (uchar(data[0]) << 8) | uchar(data[1]);
        if (len > 0 && len <= data.size() - 2) onBlock(s.track, s.start, s.duration, data.mid(2, len));
    }
    std::shared_ptr<Shared> m_shared;
    QByteArray m_buf, m_partial;
    qint64 m_bufAt = 0, m_next = -1, m_end = -1, m_partialWant = 0, m_partialEnd = 0;
    Sample m_partialSample {};
};

// ---- the player's view without the fonts ---------------------------------------------------------------
// A port of stremio-webos service/mkv-cut.js. LG's player reads a file from byte 0 in order and works
// through attached fonts at about 5 MB a second before it shows a frame (measured here: an anime episode
// with 12 fonts started in 5.0 s, a file without in 0.6 s). Only our subtitle renderer uses them, so the
// player is served the file with its Attachments element cut out: every byte after it moves down by the
// cut, and the three places that store positions (the Segment size, the SeekHead and the Cues) are
// rewritten to match. Planned from the head of the file; nothing is cut from a layout it doesn't handle.
struct MkvCut {
    enum : quint32 { EBML = 0x1a45dfa3, SEGMENT = 0x18538067, SEEKHEAD = 0x114d9b74, SEEK = 0x4dbb, SEEKID = 0x53ab, SEEKPOSITION = 0x53ac,
                     TRACKS = 0x1654ae6b, ATTACHMENTS = 0x1941a469, CLUSTER = 0x1f43b675, CUES = 0x1c53bb6b, CUEPOINT = 0xbb,
                     CUETRACKPOSITIONS = 0xb7, CUECLUSTERPOSITION = 0xf1, CUECODECSTATE = 0xea, VOID = 0xec, CRC32 = 0xbf };
    static constexpr qint64 kMinCut = 1 << 20;                  // less costs the player a fraction of a second
    qint64 start = 0, end = 0, cut = 0, floor = 0, cuesAt = -1;  // Attachments spans real [start, end)
    QByteArray head;                                            // the real [0, start), rewritten

    struct El { quint32 id = 0; qint64 start = 0, sizeAt = 0, size = 0, data = 0, end = 0; int sizeLen = 0; bool unknown = false; };
    static bool element(const QByteArray &b, qint64 pos, El &e) {
        auto p = reinterpret_cast<const uchar *>(b.constData()); const qint64 n = b.size();
        quint32 id; const int il = MkvSubs::idAt(p, n, pos, id); if (!il) return false;
        qint64 size; bool unknown; const int sl = MkvSubs::sizeAt(p, n, pos + il, size, unknown); if (!sl) return false;
        e = { id, pos, pos + il, size, pos + il + sl, pos + il + sl + size, sl, unknown };
        return true;
    }
    // the children of a master we rewrite; a CRC-32 child would no longer match, so it becomes a Void of
    // the same shape: the master stays valid, only unchecked
    template <typename F> static void children(QByteArray &b, qint64 from, qint64 to, F visit) {
        for (qint64 pos = from; pos < to;) {
            El e; if (!element(b, pos, e) || e.unknown || e.end > to) return;
            if (e.id == CRC32) b[int(e.start)] = char(VOID); else visit(e);
            pos = e.end;
        }
    }
    static quint64 readUint(const QByteArray &b, qint64 from, qint64 to) { return MkvSubs::uintOf(reinterpret_cast<const uchar *>(b.constData()), from, to); }
    static void writeUint(QByteArray &b, qint64 from, qint64 to, quint64 v) { for (qint64 i = to - 1; i >= from; i--) { b[int(i)] = char(v & 255); v >>= 8; } }

    // -1: not enough of the head yet; 0: nothing to cut; 1: planned
    int plan(const QByteArray &h) {
        El ebml, segment, attachments;
        if (!element(h, 0, ebml)) return -1;
        if (ebml.id != EBML || ebml.unknown) return 0;
        if (!element(h, ebml.end, segment)) return -1;
        if (segment.id != SEGMENT) return 0;
        bool tracks = false, found = false; QVector<El> inHead;
        for (qint64 pos = segment.data; !found;) {
            El e; if (!element(h, pos, e)) return -1;
            if (e.id == CLUSTER || e.unknown) return 0;
            if (e.id == ATTACHMENTS) { attachments = e; found = true; break; }
            if (e.id == TRACKS) tracks = true;
            if (e.id == SEEKHEAD || e.id == CUES) { if (e.end > h.size()) return -1; inHead << e; }
            pos = e.end;
        }
        cut = attachments.end - attachments.start;
        if (cut < kMinCut || !tracks) return 0;
        head = h.left(int(attachments.start));
        floor = attachments.end - segment.data;                   // positions count from the Segment's data
        start = attachments.start; end = attachments.end; cuesAt = -1;
        bool cuesFound = false, chained = false;
        for (const El &e : inHead) {
            if (e.id == CUES) { cuesFound = true; cues(head, e.start); continue; }
            children(head, e.data, e.end, [&](const El &seek) {
                if (seek.id != SEEK) return;
                quint64 target = 0; El at; bool hasAt = false;
                children(head, seek.data, seek.end, [&](const El &c) {
                    if (c.id == SEEKID) target = readUint(head, c.data, c.end);
                    if (c.id == SEEKPOSITION) { at = c; hasAt = true; }
                });
                if (!hasAt) return;
                const qint64 position = qint64(readUint(head, at.data, at.end));
                if (target == SEEKHEAD) chained = true;
                if (target == ATTACHMENTS) {                         // no longer in the file: blank the entry
                    const qint64 length = seek.end - seek.start;
                    if (length - 2 > 126) { chained = true; return; }
                    for (qint64 i = seek.start; i < seek.end; i++) head[int(i)] = 0;
                    head[int(seek.start)] = char(VOID); head[int(seek.start + 1)] = char(0x80 | (length - 2));
                    return;
                }
                if (target == CUES) { cuesFound = true; if (position >= floor) cuesAt = segment.data + position; }
                if (position >= floor) writeUint(head, at.data, at.end, quint64(position - cut));
            });
        }
        if (chained || !cuesFound) return 0;                         // a second SeekHead, or Cues it doesn't list
        if (!segment.unknown) {
            writeUint(head, segment.sizeAt, segment.sizeAt + segment.sizeLen, quint64(segment.size - cut));
            head[int(segment.sizeAt)] = char(uchar(head[int(segment.sizeAt)]) | (1 << (8 - segment.sizeLen)));
        }
        return 1;
    }
    // the cluster and codec-state positions of a Cues element held whole in `b` at `at`, moved down
    bool cues(QByteArray &b, qint64 at) const {
        El e; if (!element(b, at, e) || e.id != CUES || e.unknown || e.end > b.size()) return false;
        children(b, e.data, e.end, [&](const El &point) {
            if (point.id != CUEPOINT) return;
            children(b, point.data, point.end, [&](const El &positions) {
                if (positions.id != CUETRACKPOSITIONS) return;
                children(b, positions.data, positions.end, [&](const El &c) {
                    if (c.id != CUECLUSTERPOSITION && c.id != CUECODECSTATE) return;
                    const quint64 v = readUint(b, c.data, c.end);
                    if (v >= quint64(floor)) writeUint(b, c.data, c.end, v - quint64(cut));   // a codec state of 0 means none
                });
            });
        });
        return true;
    }
};

// ---- the server ----------------------------------------------------------------------------------------
// One stream at a time (`open` replaces the last). Each player connection fetches its range upstream
// piece by piece (see serve()). Before the player gets an answer, a bootstrap fetch reads the file's head
// and decides the player's view (MkvCut): the file as it is, or without its fonts, which the bootstrap
// then reads on for our renderer while the picture starts.
class TeeWorker : public QObject {
    Q_OBJECT
public:
    static constexpr qint64 kReadAhead = 8 << 20;
    TeeWorker() {
        connect(&m_server, &QTcpServer::newConnection, this, [this] { while (auto s = m_server.nextPendingConnection()) serve(s); });
    }
public slots:
    void start() { m_server.listen(QHostAddress::LocalHost, 0); emit listening(m_server.serverPort()); }
    void open(int session, const QString &url) {
        m_session = session; m_url = url; m_shared = std::make_shared<MkvSubs::Shared>(); m_mp4 = std::make_shared<Mp4Subs::Shared>();
        m_tracks.clear(); m_sent = false; m_once.clear();
        for (const auto &c : m_waiting) { c->done = true; c->socket->disconnectFromHost(); }
        m_waiting.clear(); m_cuesWaiting.clear();
        stopBoot(); stopCues();
        m_view = Pending; m_cut = MkvCut(); m_size = -1; m_head.clear(); m_cues.clear(); m_cuesState = 0; m_cuesTries = 0;
        m_bootParser = std::make_shared<MkvSubs>(m_shared);
        auto none = std::make_shared<Mp4Subs>(m_mp4);
        wire(*m_bootParser, *none, session);
        boot(0, kHeadMax - 1);
        // a head that stalls must not hold the player
        QTimer::singleShot(kViewWait, this, [this, session] { if (session == m_session && m_view == Pending) decide(Whole); });
    }
signals:
    void listening(int port);
    void tracks(int session, const QVariantList &tracks, bool matroska);
    void subtitleHeader(int session, int track, const QString &codec, const QByteArray &header);
    void subtitleBlock(int session, int track, qint64 startMs, qint64 durMs, const QByteArray &payload);
    void font(int session, const QString &name, const QByteArray &data);
    void chapter(int session, qint64 startMs, qint64 endMs, const QString &title);
private:
    // One player connection: the range it asked for is fetched upstream in kChunk pieces, one at a time,
    // each asked for only once the player has taken most of what's waiting. Memory per connection stays
    // under kReadAhead + kChunk whatever the network or Qt's reply buffering does (Qt 5.12 on the TV
    // kept downloading into a reply past its read-buffer limit: the app grew ~30 MB a second).
    static constexpr qint64 kChunk = 4 << 20;
    struct Conn {
        QTcpSocket *socket = nullptr;
        QNetworkReply *reply = nullptr;
        std::shared_ptr<MkvSubs> parser;
        std::shared_ptr<Mp4Subs> mp4;
        qint64 from = 0, last = -1, next = 0, total = -1;   // the player's offsets; last: the last byte to send (-1: to the end)
        qint64 shift = 0;                                   // real offset - the player's, for the piece being fetched
        int session = 0;
        QString url;                                        // the stream as it was when the player asked
        bool ranged = false, head = false, headerSent = false, done = false;
    };
    void serve(QTcpSocket *s) {
        m_served++; m_sockets.insert(s); m_open = m_sockets.size();
        auto c = std::make_shared<Conn>();
        c->socket = s;
        auto request = std::make_shared<QByteArray>();
        connect(s, &QTcpSocket::disconnected, this, [this, s, c] {
            m_sockets.remove(s); m_open = m_sockets.size();
            c->done = true;
            // abort() emits finished at once, and that handler lets go of the reply
            if (QNetworkReply *r = c->reply) { c->reply = nullptr; r->abort(); }
            s->deleteLater();
        });
        connect(s, &QTcpSocket::bytesWritten, this, [this, c] { more(c); });
        connect(s, &QTcpSocket::readyRead, this, [this, s, c, request] {
            *request += s->readAll();
            if (!request->contains("\r\n\r\n")) return;
            disconnect(s, &QTcpSocket::readyRead, this, nullptr);
            static const QRegularExpression range("\\r\\n[Rr]ange:\\s*bytes=(\\d+)-(\\d*)"), path("^[A-Z]+ /s/(\\d+) ");
            // a player still reading a stream that has been replaced gets nothing
            if (path.match(QString::fromLatin1(*request)).captured(1).toInt() != m_session) {
                c->done = true; s->write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"); s->disconnectFromHost(); return;
            }
            const auto m = range.match(QString::fromLatin1(*request));
            c->ranged = m.hasMatch();
            c->from = c->next = c->ranged ? m.captured(1).toLongLong() : 0;
            c->last = c->ranged && !m.captured(2).isEmpty() ? m.captured(2).toLongLong() : -1;
            c->head = request->startsWith("HEAD");
            c->session = m_session; c->url = m_url;
            c->parser = std::make_shared<MkvSubs>(m_shared);
            c->mp4 = std::make_shared<Mp4Subs>(m_mp4);
            wire(*c->parser, *c->mp4, c->session);
            begin(c);
        });
    }
    // answers once the view is decided
    void begin(const std::shared_ptr<Conn> &c) {
        if (m_view == Pending) { m_waiting << c; return; }
        if (m_view == Whole) { fetch(c); return; }
        const qint64 total = m_size - m_cut.cut;
        if (c->last < 0 || c->last >= total) c->last = total - 1;
        if (c->from > c->last) {
            c->done = true;
            c->socket->write("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */" + QByteArray::number(total) + "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            c->socket->disconnectFromHost(); return;
        }
        QByteArray h = c->ranged ? "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes " + QByteArray::number(c->from) + "-" + QByteArray::number(c->last) + "/" + QByteArray::number(total) + "\r\n"
                                 : QByteArray("HTTP/1.1 200 OK\r\n");
        h += "Content-Length: " + QByteArray::number(c->last - c->from + 1) + "\r\nAccept-Ranges: bytes\r\nContent-Type: video/x-matroska\r\nConnection: close\r\n\r\n";
        c->headerSent = true;
        c->socket->write(h);
        more(c);
    }
    // the next piece of a cut view: the rewritten head, the rewritten Cues, or real bytes past the cut
    void pump(const std::shared_ptr<Conn> &c) {
        if (c->next < m_cut.start) {
            const QByteArray piece = m_cut.head.mid(int(c->next), int(qMin(m_cut.start, c->last + 1) - c->next));
            c->next += piece.size(); c->socket->write(piece);
            return;
        }
        const qint64 real = c->next + m_cut.cut, realLast = c->last + m_cut.cut;
        if (m_cut.cuesAt >= 0 && real >= m_cut.cuesAt && m_cuesState == 0) { m_cuesWaiting << c; return; }  // being rewritten
        if (m_cuesState == 1 && real >= m_cut.cuesAt && real < m_cut.cuesAt + m_cues.size()) {
            const QByteArray piece = m_cues.mid(int(real - m_cut.cuesAt), int(qMin(m_cut.cuesAt + m_cues.size(), realLast + 1) - real));
            c->next += piece.size(); c->socket->write(piece);
            return;
        }
        qint64 to = qMin(real + kChunk - 1, realLast);
        if (m_cut.cuesAt >= 0 && real < m_cut.cuesAt) to = qMin(to, m_cut.cuesAt - 1);   // the Cues come from us
        fetch(c, real, to);
    }
    // asks for the next piece when the player has room for it
    void more(const std::shared_ptr<Conn> &c) {
        if (c->done) return;
        if (c->headerSent && (c->head || (c->last >= 0 && c->next > c->last))) {     // all sent
            if (!c->socket->bytesToWrite()) { c->done = true; c->socket->disconnectFromHost(); }
            return;
        }
        if (!c->reply && c->socket->bytesToWrite() < kReadAhead / 2) { if (m_view == Cut && c->session == m_session) pump(c); else fetch(c); }
    }
    static QNetworkRequest request(const QString &url, qint64 from, qint64 to) {
        QNetworkRequest up { QUrl(url) };
        up.setHeader(QNetworkRequest::UserAgentHeader, "seimio/0.1");
        up.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
        up.setRawHeader("Range", "bytes=" + QByteArray::number(from) + "-" + QByteArray::number(to));
        return up;
    }
    // real bytes [from, to] upstream (the whole view: the player's next piece)
    void fetch(const std::shared_ptr<Conn> &c, qint64 from = -1, qint64 to = -1) {
        if (from < 0) { from = c->next; to = c->last >= 0 ? qMin(c->last, c->next + kChunk - 1) : c->next + kChunk - 1; }
        c->shift = from - c->next;
        QNetworkReply *r = c->head ? m_net.head(request(c->url, from, to)) : m_net.get(request(c->url, from, to));
        c->reply = r;
        connect(r, &QNetworkReply::metaDataChanged, this, [this, c, r] {
            if (r->attribute(QNetworkRequest::RedirectionTargetAttribute).isValid()) return;
            const int status = r->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
            // every piece must be the range asked for: a server that ignores Range would send the whole
            // file at once (unbounded memory) or the wrong bytes
            if (c->headerSent) { if (status != 206) { c->done = true; r->abort(); c->socket->disconnectFromHost(); } return; }
            static const QRegularExpression total("/(\\d+)\\s*$");
            const auto t = total.match(QString::fromLatin1(r->rawHeader("Content-Range")));
            c->total = t.hasMatch() ? t.captured(1).toLongLong() : r->header(QNetworkRequest::ContentLengthHeader).toLongLong();
            QByteArray h;
            const bool ok = status == 206 || (c->head && status == 200);             // HEAD may ignore Range
            if (ok) {
                if (c->last < 0 || c->last >= c->total) c->last = c->total - 1;
                h = c->ranged ? "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes " + QByteArray::number(c->from) + "-" + QByteArray::number(c->last) + "/" + QByteArray::number(c->total) + "\r\n"
                              : QByteArray("HTTP/1.1 200 OK\r\n");
                h += "Content-Length: " + QByteArray::number(c->last - c->from + 1) + "\r\nAccept-Ranges: bytes\r\n";
                if (r->hasRawHeader("Content-Type")) h += "Content-Type: " + r->rawHeader("Content-Type") + "\r\n";
            } else {
                h = "HTTP/1.1 " + QByteArray::number(status ? status : 502) + " Upstream\r\nContent-Length: 0\r\n";
                c->head = true;                                                      // nothing more to send
            }
            c->headerSent = true;
            c->socket->write(h + "Connection: close\r\n\r\n");
            if (!ok) r->abort();                                                      // and not its body
        });
        connect(r, &QNetworkReply::readyRead, this, [this, c, r] {
            if (!c->headerSent || c->head) return;
            const QByteArray chunk = r->readAll();
            c->socket->write(chunk);
            if (c->session == m_session) { c->parser->pushAt(c->next + c->shift, chunk); c->mp4->pushAt(c->next + c->shift, chunk); }
            c->next += chunk.size();
            // neither Matroska nor MP4: no tracks of ours (an MP4 sends its own once moov is read)
            if (c->session == m_session && !m_sent && m_shared->matroska == 0 && m_mp4->mp4 == 0) { m_sent = true; emit tracks(c->session, {}, false); }
        });
        connect(r, &QNetworkReply::finished, this, [this, c, r] {
            if (c->reply == r) c->reply = nullptr;
            r->deleteLater();
            if (c->done) return;
            if (r->error() != QNetworkReply::NoError && r->error() != QNetworkReply::OperationCanceledError) { c->done = true; c->socket->disconnectFromHost(); return; }
            more(c);
        });
    }
    // ---- the view ----
    enum View { Pending, Whole, Cut };
    static constexpr qint64 kHeadMax = 8 << 20, kCuesMax = 16 << 20;
    static constexpr int kViewWait = 8000;
    // the bootstrap: real [from, to] into its own parser (tracks, then fonts), planning while Pending
    void boot(qint64 from, qint64 to) {
        const int session = m_session;
        m_bootAt = from;
        QNetworkReply *r = m_net.get(request(m_url, from, to));
        m_boot = r;
        connect(r, &QNetworkReply::metaDataChanged, this, [this, r, session] {
            if (session != m_session || r->attribute(QNetworkRequest::RedirectionTargetAttribute).isValid()) return;
            if (r->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() != 206) { if (m_view == Pending) decide(Whole); stopBoot(); return; }
            static const QRegularExpression total("/(\\d+)\\s*$");
            const auto t = total.match(QString::fromLatin1(r->rawHeader("Content-Range")));
            if (t.hasMatch()) m_size = t.captured(1).toLongLong();
        });
        connect(r, &QNetworkReply::readyRead, this, [this, r, session] {
            if (session != m_session || m_boot != r) return;
            const QByteArray data = r->readAll();
            m_bootParser->pushAt(m_bootAt, data);
            m_bootAt += data.size();
            if (m_view == Pending) { m_head += data; plan(false); }
            // past the fonts, on to the first Cluster: Chapters or Tags after the Attachments are only read here
            if (m_view == Whole || (m_view == Cut && m_bootAt >= m_cut.end && m_bootParser->clusterSeen)) stopBoot();   // the player reads the rest
        });
        connect(r, &QNetworkReply::finished, this, [this, r, session] {
            r->deleteLater();
            if (m_boot != r) return;
            m_boot = nullptr;
            if (session != m_session) return;
            if (m_view == Pending) plan(true);
            if (m_view == Cut && r->error() == QNetworkReply::NoError && !m_bootParser->clusterSeen && m_bootAt < m_cut.end + kChunk)
                boot(m_bootAt, m_cut.end + kChunk - 1);                                                   // the rest of the fonts
        });
    }
    void stopBoot() { if (QNetworkReply *r = m_boot) { m_boot = nullptr; r->abort(); } }
    void plan(bool ended) {
        if (m_size < 0) { if (ended) decide(Whole); return; }
        const int p = m_cut.plan(m_head);
        if (p == 1) { decide(Cut); if (m_cut.cuesAt >= 0) loadCues(); }
        else if (p == 0 || ended || m_head.size() >= kHeadMax) decide(Whole);
    }
    void decide(View v) {
        m_view = v; m_head.clear();
        if (v == Whole) m_cut = MkvCut();
        const auto waiting = m_waiting; m_waiting.clear();
        for (const auto &c : waiting) if (!c->done) begin(c);
    }
    // the Cues element of a cut view, rewritten; the player asks for it on its first seek
    void loadCues() {
        const int session = m_session;
        auto data = std::make_shared<QByteArray>();
        QNetworkReply *r = m_net.get(request(m_url, m_cut.cuesAt, m_cut.cuesAt + kCuesMax - 1));
        m_cuesReply = r;
        QTimer::singleShot(10000, r, [this, r] { if (m_cuesReply == r) cuesDone(false); });
        connect(r, &QNetworkReply::readyRead, this, [this, r, data, session] {
            if (session != m_session || m_cuesReply != r) return;
            *data += r->readAll();
            MkvCut::El e;
            if (!MkvCut::element(*data, 0, e)) { if (data->size() > 16) cuesDone(false); return; }
            if (e.id != MkvCut::CUES || e.unknown || e.end > kCuesMax) { cuesDone(false); return; }
            if (data->size() < e.end) return;
            data->truncate(int(e.end));
            m_cuesState = m_cut.cues(*data, 0) ? 1 : -1; m_cues = *data;
            cuesDone(m_cuesState == 1);
        });
        connect(r, &QNetworkReply::finished, this, [this, r] { r->deleteLater(); if (m_cuesReply == r) cuesDone(false); });
    }
    // a Cues element that can't be had is tried three times, then served as it is (the player's seeks
    // may land off and resync, playing isn't affected)
    void cuesDone(bool ok) {
        stopCues();
        if (!ok && ++m_cuesTries < 3) { loadCues(); return; }
        if (!ok) { m_cuesState = -1; m_cues.clear(); }
        const auto waiting = m_cuesWaiting; m_cuesWaiting.clear();
        for (const auto &c : waiting) if (!c->done) pump(c);
    }
    void stopCues() { if (QNetworkReply *r = m_cuesReply) { m_cuesReply = nullptr; r->abort(); } }

    // every connection that reads the file's start parses its header again: each track, font and
    // chapter goes out once per stream
    bool first(const QString &key) { if (m_once.contains(key)) return false; m_once.insert(key); return true; }
    void wire(MkvSubs &p, Mp4Subs &m, int session) {
        m.onTracks = [this, session](const QVector<Mp4Subs::Track> &list) {
            QVariantList out;
            for (const Mp4Subs::Track &t : list) {
                out << QVariantMap { { "number", t.number }, { "type", 0x11 }, { "codec", "tx3g" }, { "lang", t.lang }, { "title", t.name }, { "default", false } };
                emit subtitleHeader(session, t.number, "tx3g", QByteArray());
            }
            if (!m_sent) { m_sent = true; emit tracks(session, out, false); }
        };
        m.onBlock = [this, session](int tn, qint64 s, qint64 d, const QByteArray &text) { emit subtitleBlock(session, tn, s, d, text); };
        p.onTrack = [this, session](const MkvSubs::Track &t) {
            if (!first("t" + QString::number(t.number))) return;
            m_tracks << QVariantMap { { "number", t.number }, { "type", t.type }, { "codec", t.codec }, { "lang", t.lang }, { "title", t.name },
                                      { "default", t.def }, { "forced", t.forced }, { "hi", t.hi }, { "commentary", t.commentary } };
            if (t.type == 0x11) emit subtitleHeader(session, t.number, t.codec, t.priv);
        };
        p.onTracksDone = [this, session] { if (!m_sent) { m_sent = true; emit tracks(session, m_tracks, true); } };
        p.onFont = [this, session](const QString &name, const QByteArray &data) { if (first("f" + name)) emit font(session, name, data); };
        p.onChapter = [this, session](qint64 s, qint64 e, const QString &title) { if (first("c" + QString::number(s) + title)) emit chapter(session, s, e, title); };
        p.onBlock = [this, session](int tn, qint64 s, qint64 d, const QByteArray &payload) { emit subtitleBlock(session, tn, s, d, payload); };
    }
    // children of the worker, so they move to its thread with it
    QTcpServer m_server { this };
    QNetworkAccessManager m_net { this };
    std::shared_ptr<MkvSubs::Shared> m_shared = std::make_shared<MkvSubs::Shared>();
    std::shared_ptr<Mp4Subs::Shared> m_mp4 = std::make_shared<Mp4Subs::Shared>();
    QVariantList m_tracks;
    QString m_url;
    int m_session = 0;
    QSet<QTcpSocket *> m_sockets;
    QSet<QString> m_once;
    bool m_sent = false;
    View m_view = Whole;
    MkvCut m_cut;
    qint64 m_size = -1, m_bootAt = 0;
    QByteArray m_head, m_cues;                          // the head while planning; the rewritten Cues
    int m_cuesState = 0, m_cuesTries = 0;               // state: 0 loading (or none needed), 1 rewritten, -1 as it is
    QNetworkReply *m_boot = nullptr, *m_cuesReply = nullptr;
    std::shared_ptr<MkvSubs> m_bootParser;
    QVector<std::shared_ptr<Conn>> m_waiting, m_cuesWaiting;
public:
    // for the lab, read from the GUI thread without waiting on this one
    std::atomic<int> m_served { 0 }, m_open { 0 };
};

// The QML side: `open(url)` returns the local URL for the player and starts reading that stream;
// the file's tracks, chapters, fonts and subtitle blocks arrive as signals on the GUI thread.
class Tee : public QObject {
    Q_OBJECT
    Q_PROPERTY(int port READ port NOTIFY portChanged)
public:
    Tee() {
        m_worker = new TeeWorker;
        m_worker->moveToThread(&m_thread);
        connect(&m_thread, &QThread::finished, m_worker, &QObject::deleteLater);
        connect(m_worker, &TeeWorker::listening, this, [this](int port) { m_port = port; emit portChanged(); });
        // re-emitted on the worker's thread (DirectConnection): receivers on other threads get them queued,
        // so subtitle blocks and fonts go straight to the subtitle thread without passing the GUI thread
        auto mine = [this](int session) { return session == m_session.load(); };
        connect(m_worker, &TeeWorker::tracks, this, [this, mine](int s, const QVariantList &t, bool mkv) { if (mine(s)) emit tracksRead(t, mkv); }, Qt::DirectConnection);
        connect(m_worker, &TeeWorker::chapter, this, [this, mine](int s, qint64 a, qint64 b, const QString &t) { if (mine(s)) emit chapter(a, b, t); }, Qt::DirectConnection);
        connect(m_worker, &TeeWorker::subtitleHeader, this, [this, mine](int s, int tr, const QString &c, const QByteArray &h) { if (mine(s)) emit subtitleHeader(tr, c, h); }, Qt::DirectConnection);
        connect(m_worker, &TeeWorker::subtitleBlock, this, [this, mine](int s, int tr, qint64 a, qint64 d, const QByteArray &p) { if (mine(s)) emit subtitleBlock(tr, a, d, p); }, Qt::DirectConnection);
        connect(m_worker, &TeeWorker::font, this, [this, mine](int s, const QString &n, const QByteArray &d) { if (mine(s)) emit font(n, d); }, Qt::DirectConnection);
        m_thread.start();
        QMetaObject::invokeMethod(m_worker, "start", Qt::QueuedConnection);
    }
    ~Tee() override { m_thread.quit(); m_thread.wait(); }
    int port() const { return m_port; }
    Q_INVOKABLE QString stats() const { return QString("served %1 open %2").arg(m_worker->m_served).arg(m_worker->m_open); }
    Q_INVOKABLE QString open(const QString &url) {
        if (!m_port) return url;                                                    // not listening: play directly
        const int session = ++m_session;
        QMetaObject::invokeMethod(m_worker, "open", Qt::QueuedConnection, Q_ARG(int, session), Q_ARG(QString, url));
        return QString("http://127.0.0.1:%1/s/%2").arg(m_port).arg(session);
    }
signals:
    void portChanged();
    void tracksRead(const QVariantList &tracks, bool matroska);
    void chapter(qint64 startMs, qint64 endMs, const QString &title);
    void subtitleHeader(int track, const QString &codec, const QByteArray &header);
    void subtitleBlock(int track, qint64 startMs, qint64 durMs, const QByteArray &payload);
    void font(const QString &name, const QByteArray &data);
private:
    QThread m_thread;
    TeeWorker *m_worker;
    int m_port = 0;
    std::atomic<int> m_session { 0 };
};
