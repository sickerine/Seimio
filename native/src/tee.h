#pragma once
// Tee: the player loads streams through a local HTTP server, which fetches every byte range from the
// real URL once, hands it to the player, and reads the same bytes for what LG's player doesn't give us:
// the file's tracks (names, languages, default/forced/hearing-impaired/commentary flags), attached
// fonts, chapters and the subtitle blocks. Ported from stremio-webos service/ass-tee.js and
// mkv-subs.js, which proved the design on this TV: one download, subtitles from the bytes the player
// pulls anyway. Matroska only; anything else passes through untouched.
//
// It runs on its own thread (network, parsing and socket writes never touch the GUI thread) and talks
// to the rest through queued signals. Read-ahead per connection is capped (`kReadAhead`), so memory
// stays bounded whatever the file's size.
#include <QtQml>
#include <QTcpServer>
#include <QTcpSocket>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QThread>
#include <functional>

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
// One stream at a time (`open` replaces the last). Each player connection gets its own upstream
// request for the range it asked for; bytes go out as they come in, and upstream reading pauses while a
// connection has more than kReadAhead waiting to be written.
class TeeWorker : public QObject {
    Q_OBJECT
public:
    static constexpr qint64 kReadAhead = 16 << 20;
    TeeWorker() {
        connect(&m_server, &QTcpServer::newConnection, this, [this] { while (auto s = m_server.nextPendingConnection()) serve(s); });
    }
public slots:
    void start() { m_server.listen(QHostAddress::LocalHost, 0); emit listening(m_server.serverPort()); }
    void open(int session, const QString &url) {
        m_session = session; m_url = url; m_shared = std::make_shared<MkvSubs::Shared>(); m_tracks.clear(); m_sent = false;
    }
signals:
    void listening(int port);
    void tracks(int session, const QVariantList &tracks, bool matroska);
    void subtitleHeader(int session, int track, const QString &codec, const QByteArray &header);
    void subtitleBlock(int session, int track, qint64 startMs, qint64 durMs, const QByteArray &payload);
    void font(int session, const QString &name, const QByteArray &data);
    void chapter(int session, qint64 startMs, qint64 endMs, const QString &title);
private:
    void serve(QTcpSocket *s) {
        auto request = std::make_shared<QByteArray>();
        connect(s, &QTcpSocket::disconnected, s, &QObject::deleteLater);
        connect(s, &QTcpSocket::readyRead, this, [this, s, request] {
            *request += s->readAll();
            if (!request->contains("\r\n\r\n")) return;
            disconnect(s, &QTcpSocket::readyRead, this, nullptr);
            static const QRegularExpression range("\\r\\n[Rr]ange:\\s*bytes=(\\d+)-(\\d*)");
            const auto m = range.match(QString::fromLatin1(*request));
            const qint64 from = m.hasMatch() ? m.captured(1).toLongLong() : 0;
            const bool head = request->startsWith("HEAD");
            QNetworkRequest up { QUrl(m_url) };
            up.setHeader(QNetworkRequest::UserAgentHeader, "seimio/0.1");
            up.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
            if (m.hasMatch()) up.setRawHeader("Range", ("bytes=" + m.captured(1) + "-" + m.captured(2)).toLatin1());
            QNetworkReply *reply = head ? m_net.head(up) : m_net.get(up);
            reply->setReadBufferSize(1 << 20);
            const int session = m_session;
            auto offset = std::make_shared<qint64>(from);
            auto sentHeader = std::make_shared<bool>(false);
            auto parser = std::make_shared<MkvSubs>(m_shared);
            wire(*parser, session);
            auto pump = [this, s, reply, offset, session, parser] {
                // bytes go to the player as they come, and to this connection's parser while it's the stream
                while (reply->bytesAvailable() && s->bytesToWrite() < kReadAhead) {
                    const QByteArray chunk = reply->read(256 << 10);
                    if (chunk.isEmpty()) break;
                    s->write(chunk);
                    if (session == m_session) parser->pushAt(*offset, chunk);
                    *offset += chunk.size();
                }
                // not Matroska: the player gets the bytes, and the app hears there's nothing to read
                if (session == m_session && !m_sent && m_shared->matroska == 0) { m_sent = true; emit tracks(session, {}, false); }
            };
            connect(reply, &QNetworkReply::metaDataChanged, this, [s, reply, sentHeader] {
                if (*sentHeader || reply->attribute(QNetworkRequest::RedirectionTargetAttribute).isValid()) return;
                *sentHeader = true;
                const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
                QByteArray h = "HTTP/1.1 " + QByteArray::number(status ? status : 502) + " " + reply->attribute(QNetworkRequest::HttpReasonPhraseAttribute).toByteArray() + "\r\n";
                for (const char *k : { "Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "Last-Modified", "ETag" })
                    if (reply->hasRawHeader(k)) h += QByteArray(k) + ": " + reply->rawHeader(k) + "\r\n";
                h += "Connection: close\r\n\r\n";
                s->write(h);
            });
            connect(reply, &QNetworkReply::readyRead, this, pump);
            connect(s, &QTcpSocket::bytesWritten, reply, pump);
            connect(reply, &QNetworkReply::finished, s, [s, reply, pump] {
                pump();
                if (reply->bytesAvailable()) return;                                // the socket drains the rest
                reply->deleteLater(); s->disconnectFromHost();
            });
            connect(s, &QTcpSocket::bytesWritten, s, [s, reply] {
                if (reply->isFinished() && !reply->bytesAvailable() && !s->bytesToWrite()) { reply->deleteLater(); s->disconnectFromHost(); }
            });
            connect(s, &QTcpSocket::disconnected, reply, [reply] { reply->abort(); reply->deleteLater(); });
        });
    }
    void wire(MkvSubs &p, int session) {
        p.onTrack = [this, session](const MkvSubs::Track &t) {
            m_tracks << QVariantMap { { "number", t.number }, { "type", t.type }, { "codec", t.codec }, { "lang", t.lang }, { "title", t.name },
                                      { "default", t.def }, { "forced", t.forced }, { "hi", t.hi }, { "commentary", t.commentary } };
            if (t.type == 0x11) emit subtitleHeader(session, t.number, t.codec, t.priv);
        };
        p.onTracksDone = [this, session] { if (!m_sent) { m_sent = true; emit tracks(session, m_tracks, true); } };
        p.onFont = [this, session](const QString &name, const QByteArray &data) { emit font(session, name, data); };
        p.onChapter = [this, session](qint64 s, qint64 e, const QString &title) { emit chapter(session, s, e, title); };
        p.onBlock = [this, session](int tn, qint64 s, qint64 d, const QByteArray &payload) { emit subtitleBlock(session, tn, s, d, payload); };
    }
    QTcpServer m_server;
    QNetworkAccessManager m_net;
    std::shared_ptr<MkvSubs::Shared> m_shared = std::make_shared<MkvSubs::Shared>();
    QVariantList m_tracks;
    QString m_url;
    int m_session = 0;
    bool m_sent = false;
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
        auto mine = [this](int session) { return session == m_session; };
        connect(m_worker, &TeeWorker::tracks, this, [this, mine](int s, const QVariantList &t, bool mkv) { if (mine(s)) emit tracksRead(t, mkv); });
        connect(m_worker, &TeeWorker::chapter, this, [this, mine](int s, qint64 a, qint64 b, const QString &t) { if (mine(s)) emit chapter(a, b, t); });
        connect(m_worker, &TeeWorker::subtitleHeader, this, [this, mine](int s, int tr, const QString &c, const QByteArray &h) { if (mine(s)) emit subtitleHeader(tr, c, h); });
        connect(m_worker, &TeeWorker::subtitleBlock, this, [this, mine](int s, int tr, qint64 a, qint64 d, const QByteArray &p) { if (mine(s)) emit subtitleBlock(tr, a, d, p); });
        connect(m_worker, &TeeWorker::font, this, [this, mine](int s, const QString &n, const QByteArray &d) { if (mine(s)) emit font(n, d); });
        m_thread.start();
        QMetaObject::invokeMethod(m_worker, "start", Qt::QueuedConnection);
    }
    ~Tee() override { m_thread.quit(); m_thread.wait(); }
    int port() const { return m_port; }
    Q_INVOKABLE QString open(const QString &url) {
        if (!m_port) return url;                                                    // not listening: play directly
        ++m_session;
        QMetaObject::invokeMethod(m_worker, "open", Qt::QueuedConnection, Q_ARG(int, m_session), Q_ARG(QString, url));
        return QString("http://127.0.0.1:%1/s/%2").arg(m_port).arg(m_session);
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
    int m_port = 0, m_session = 0;
};
