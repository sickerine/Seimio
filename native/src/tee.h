#pragma once
// Tee: the player loads streams through a local HTTP server, which fetches every byte range from the
// real URL once, hands it to the player, and reads the same bytes for what LG's player doesn't give us:
// the file's tracks (names, languages, default/forced/hearing-impaired/commentary flags), attached
// fonts, chapters and the subtitle blocks. Ported from stremio-webos service/ass-tee.js and
// mkv-subs.js, which proved the design on this TV: one download, subtitles from the bytes the player
// pulls anyway. Matroska only; anything else passes through untouched.
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

    void openMaster(quint32 id) {
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

// ---- the server ----------------------------------------------------------------------------------------
// One stream at a time (`open` replaces the last). Each player connection fetches its range upstream
// piece by piece (see serve()).
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
        m_session = session; m_url = url; m_shared = std::make_shared<MkvSubs::Shared>(); m_tracks.clear(); m_sent = false; m_once.clear();
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
        qint64 from = 0, last = -1, next = 0, total = -1;   // last: the last byte to send (-1: to the end)
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
            wire(*c->parser, c->session);
            fetch(c);
        });
    }
    // asks for the next piece when the player has room for it
    void more(const std::shared_ptr<Conn> &c) {
        if (c->done) return;
        if (c->headerSent && (c->head || (c->last >= 0 && c->next > c->last))) {     // all sent
            if (!c->socket->bytesToWrite()) { c->done = true; c->socket->disconnectFromHost(); }
            return;
        }
        if (!c->reply && c->socket->bytesToWrite() < kReadAhead / 2) fetch(c);
    }
    void fetch(const std::shared_ptr<Conn> &c) {
        QNetworkRequest up { QUrl(c->url) };
        up.setHeader(QNetworkRequest::UserAgentHeader, "seimio/0.1");
        up.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
        const qint64 end = c->last >= 0 ? qMin(c->last, c->next + kChunk - 1) : c->next + kChunk - 1;
        up.setRawHeader("Range", "bytes=" + QByteArray::number(c->next) + "-" + QByteArray::number(end));
        QNetworkReply *r = c->head ? m_net.head(up) : m_net.get(up);
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
            if (c->session == m_session) c->parser->pushAt(c->next, chunk);
            c->next += chunk.size();
            if (c->session == m_session && !m_sent && m_shared->matroska == 0) { m_sent = true; emit tracks(c->session, {}, false); }
        });
        connect(r, &QNetworkReply::finished, this, [this, c, r] {
            if (c->reply == r) c->reply = nullptr;
            r->deleteLater();
            if (c->done) return;
            if (r->error() != QNetworkReply::NoError && r->error() != QNetworkReply::OperationCanceledError) { c->done = true; c->socket->disconnectFromHost(); return; }
            more(c);
        });
    }
    // every connection that reads the file's start parses its header again: each track, font and
    // chapter goes out once per stream
    bool first(const QString &key) { if (m_once.contains(key)) return false; m_once.insert(key); return true; }
    void wire(MkvSubs &p, int session) {
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
    QVariantList m_tracks;
    QString m_url;
    int m_session = 0;
    QSet<QTcpSocket *> m_sockets;
    QSet<QString> m_once;
    bool m_sent = false;
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
