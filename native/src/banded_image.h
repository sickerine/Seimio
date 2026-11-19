#pragma once
// BandedImage: a picture for a shader to read, as Image { visible: false; asynchronous: true } is, whose
// pixels go to the GPU a band a frame. Sent whole, a 1920 x 1080 picture took the TV 15 to 20 ms in the
// frame that first drew it, so every backdrop's crossfade began on a late frame (with backdrops decoded at
// a quarter of the size, a Home tour's late frames fell from 11-14 to 6).
//
// The picture comes from the picture loader (pictures.h, through the engine's "art" image provider):
// fetched from whichever of its places is at hand, kept on disk, and decoded on the loader's threads
// down to fit `sourceSize`, never up, in the byte order the GPU takes. It is uploaded after each frame's
// drawing into a texture nothing reads yet: the TV's driver stalls 10-15 ms when a texture the last frame
// read is written to. `status` (Image's values) turns Ready when all of it is there, and only then does a
// shader get it.
//
// Two threads: the GUI thread owns the source and the decoded picture, the render thread the textures.
// `m_mutex` covers what is handed from one to the other; `m_rendering` is held for a whole upload step, so
// the GUI thread can wait one out before it lets go of a window or is destroyed.
#include <QQuickItem>
#include <QQuickWindow>
#include <QSGTextureProvider>
#include <QSGTexture>
#include <QQuickAsyncImageProvider>
#include <QQuickImageResponse>
#include <QQuickTextureFactory>
#include <QQmlEngine>
#include <QOpenGLContext>
#include <QOpenGLFunctions>
#include <QMutex>
#include <QPointer>
#include <QVector>
#include <algorithm>
#include <QThread>
#include <QTimer>
#include <QRunnable>
#include <atomic>
#include <memory>

class BandedProvider : public QSGTextureProvider {
    Q_OBJECT
public:
    QSGTexture *texture() const override { return shown; }
    void show(QSGTexture *next) { delete shown; shown = next; emit textureChanged(); }
    ~BandedProvider() override { delete shown; }
    QSGTexture *shown = nullptr;
};

class BandedImage : public QQuickItem {
    Q_OBJECT
    // the picture's address: one the picture loader lists places in (pictures.h), or any other
    Q_PROPERTY(QUrl address READ source WRITE setSource NOTIFY sourceChanged)
    Q_PROPERTY(QSize sourceSize MEMBER m_sourceSize)
    Q_PROPERTY(int status READ status NOTIFY statusChanged)         // Image's: 0 Null, 1 Ready, 2 Loading, 3 Error
public:
    enum Status { Null, Ready, Loading, Error };
    // (nothing may leave a destructor, and the compiler's own way of saying so, __cxa_call_terminate, is
    // newer than the TV's C++ runtime: with it the plugin doesn't load. native/check-symbols.sh watches)
    ~BandedImage() override { try { drop(); attach(nullptr); } catch (...) { } }
    QUrl source() const { return m_source; }
    int status() const { return m_status; }
    // lab: how far the picture wanted has come ("fetching", "sending 408", "ready"; the loader's own
    // report says from where and how long it took)
    Q_INVOKABLE QString stage() const {
        switch (m_stage) {
        case 1: return "fetching";
        case 3: return QString("sending %1").arg(m_row);
        case 4: return "ready";
        case 5: return "failed: " + m_why;
        }
        return "none";
    }
    void setSource(const QUrl &url) {
        if (url == m_source) return;
        m_source = url; emit sourceChanged();
        load();
    }
    bool isTextureProvider() const override { return true; }
    // render thread. A shader always has something to read: until a picture is in, one black pixel
    QSGTextureProvider *textureProvider() const override {
        if (!m_provider) { m_provider = new BandedProvider; m_provider->shown = blank(window()); }
        return m_provider;
    }
signals:
    void sourceChanged();
    void statusChanged();
protected:
    void itemChange(ItemChange change, const ItemChangeData &data) override {
        if (change == ItemSceneChange) attach(data.window);
        QQuickItem::itemChange(change, data);
    }
private:
    // render thread: the scene graph and every texture in it are gone, so what was on the GPU is fetched
    // and sent again
    void sceneGone() {
        QMutexLocker r(&m_rendering);
        if (m_id && QOpenGLContext::currentContext()) QOpenGLContext::currentContext()->functions()->glDeleteTextures(1, &m_id);
        delete m_provider; m_provider = nullptr; m_id = 0; m_uploading = 0;
        QMetaObject::invokeMethod(this, [this] { load(); }, Qt::QueuedConnection);
    }
    static QSGTexture *blank(QQuickWindow *window) { QImage none(1, 1, QImage::Format_RGBX8888); none.fill(Qt::black); return window->createTextureFromImage(none); }
    void setStatus(int s) { if (s != m_status) { m_status = s; emit statusChanged(); } }
    // the picture on its way is no longer wanted here (the loader goes on with what it keeps for next time)
    void drop() {
        if (!m_response) return;
        m_response->disconnect(this);
        connect(m_response, &QQuickImageResponse::finished, m_response, &QObject::deleteLater);
        m_response->cancel();
        m_response = nullptr;
    }

    // GUI thread: asks the picture loader for `source`; the picture it had goes at once.
    void load() {
        const int ticket = ++m_ticket;
        drop();
        hand(QImage(), ticket);
        setImplicitSize(0, 0);
        m_stage = 0;
        if (m_source.isEmpty()) { setStatus(Null); return; }
        setStatus(Loading);
        m_stage = 1;
        QQmlEngine *engine = qmlEngine(this);
        QQmlImageProviderBase *loader = engine ? engine->imageProvider("art") : nullptr;
        if (!loader || loader->imageType() != QQmlImageProviderBase::ImageResponse) { m_why = "no picture loader"; m_stage = 5; setStatus(Error); return; }
        // The loader's address, asked for as a backdrop is ("f": inside the size, never up, in the GPU's
        // byte order, and ahead of every other picture); any other address as the one place it is.
        static const QString art = QStringLiteral("image://art/");
        const QString address = m_source.toString();
        const int slash = address.indexOf('/', art.size());
        const QString id = address.startsWith(art) && slash > 0 ? address.mid(art.size(), slash - art.size()) + "f" + address.mid(slash)
                         : "f/" + QString::fromLatin1(address.toUtf8().toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals));
        QQuickImageResponse *response = static_cast<QQuickAsyncImageProvider *>(loader)->requestImageResponse(id, m_sourceSize);
        m_response = response;
        connect(response, &QQuickImageResponse::finished, this, [this, ticket, response] {
            response->deleteLater();
            if (ticket != m_ticket || response != m_response) return;
            m_response = nullptr;
            QQuickTextureFactory *factory = response->textureFactory();
            const QImage image = factory ? factory->image() : QImage();
            delete factory;
            if (image.isNull()) { m_why = response->errorString(); m_stage = 5; setStatus(Error); return; }
            setImplicitSize(image.width(), image.height());
            m_stage = 3;
            hand(image, ticket);
        });
    }
    // GUI thread: the picture for the render thread to take (none: its texture goes). Each hand-over has
    // its own number: a picture decoded while the render thread was still clearing the last one is another
    void hand(const QImage &image, int ticket) {
        { QMutexLocker l(&m_mutex); m_image = image; m_handedFor = ticket; ++m_handed; }
        m_work = true;
        if (m_window) m_window->update();
    }
    // GUI thread: out of one window's rendering and into another's (Qt takes an item out of its window
    // before putting it in the next). What it had on the GPU goes with the window it was in, on that
    // window's render thread, so in the next window the picture is fetched and sent again.
    void attach(QQuickWindow *window) {
        if (window == m_window) return;
        if (m_window) {
            struct Gone : QRunnable {
                BandedProvider *provider; GLuint id;
                void run() override { delete provider; if (id && QOpenGLContext::currentContext()) QOpenGLContext::currentContext()->functions()->glDeleteTextures(1, &id); }
            };
            disconnect(m_window, nullptr, this, nullptr);
            QMutexLocker r(&m_rendering);                   // an upload step under way ends first, and none starts after
            auto *gone = new Gone; gone->provider = m_provider; gone->id = m_id;
            m_provider = nullptr; m_id = 0; m_uploading = 0;
            m_window->scheduleRenderJob(gone, QQuickWindow::BeforeSynchronizingStage);
            m_window = nullptr; m_left = true;
        }
        if (!window) return;
        { QMutexLocker r(&m_rendering); m_window = window; }
        connect(window, &QQuickWindow::afterRendering, this, [this, window] { upload(window); }, Qt::DirectConnection);
        connect(window, &QQuickWindow::sceneGraphInvalidated, this, &BandedImage::sceneGone, Qt::DirectConnection);
        if (m_left) { m_left = false; load(); } else if (m_work) window->update();
    }
    // render thread, after a frame's drawing: one band more of the picture in hand
    void upload(QQuickWindow *window) {
        if (!m_work) return;
        QMutexLocker r(&m_rendering);
        if (window != m_window) return;
        QImage image; int ticket, handed;
        { QMutexLocker l(&m_mutex); image = m_image; ticket = m_handedFor; handed = m_handed; }
        QOpenGLFunctions *gl = QOpenGLContext::currentContext()->functions();
        if (handed != m_uploading) {                        // another hand-over than the one being sent
            if (m_id) { gl->glDeleteTextures(1, &m_id); m_id = 0; }
            m_uploading = handed; m_row = 0;
            if (image.isNull()) static_cast<BandedProvider *>(textureProvider())->show(blank(window));
        }
        if (image.isNull()) { done(handed); return; }
        if (!m_id) {
            gl->glGenTextures(1, &m_id);
            gl->glBindTexture(GL_TEXTURE_2D, m_id);
            gl->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            gl->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            gl->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            gl->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            gl->glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, image.width(), image.height(), 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        } else gl->glBindTexture(GL_TEXTURE_2D, m_id);
        const int rows = qMin(int(Band), image.height() - m_row);
        gl->glPixelStorei(GL_UNPACK_ALIGNMENT, 4);          // RGBX rows are four bytes a pixel, back to back
        gl->glTexSubImage2D(GL_TEXTURE_2D, 0, 0, m_row, image.width(), rows, GL_RGBA, GL_UNSIGNED_BYTE, image.constScanLine(m_row));
        gl->glBindTexture(GL_TEXTURE_2D, 0);
        m_row += rows;
        if (m_row < image.height()) { window->update(); return; }       // a frame more, for the next band
        QSGTexture *whole = window->createTextureFromId(m_id, image.size(), QQuickWindow::TextureOwnsGLTexture);
        whole->setFiltering(QSGTexture::Linear);
        m_id = 0;
        static_cast<BandedProvider *>(textureProvider())->show(whole);
        done(handed);                                       // the GPU has it now
        QMetaObject::invokeMethod(this, [this, ticket] { if (ticket == m_ticket) { m_stage = 4; setStatus(Ready); } }, Qt::QueuedConnection);
    }
    // render thread: nothing more to send, unless something else was handed over meanwhile
    void done(int handed) { QMutexLocker l(&m_mutex); if (m_handed == handed) { m_image = QImage(); m_work = false; } }

    enum { Band = 136 };                                    // rows a frame: an eighth of 1080
    QUrl m_source;
    QSize m_sourceSize;
    int m_status = Null;
    int m_ticket = 0;                                       // which fetch is the one wanted (GUI thread)
    int m_stage = 0; QString m_why;                         // lab (stage())
    QQuickImageResponse *m_response = nullptr;              // the picture on its way
    QMutex m_mutex;
    QImage m_image;                                         // decoded and waiting for the GPU (under m_mutex)
    int m_handedFor = 0, m_handed = 0;                      // its fetch, and which hand-over it is (under m_mutex)
    std::atomic<bool> m_work{false};
    QMutex m_rendering;
    QQuickWindow *m_window = nullptr;                       // written on the GUI thread, under m_rendering
    bool m_left = false;                                    // it has been in a window before: its picture went with that one
    // render thread (the GUI thread only under m_rendering)
    mutable BandedProvider *m_provider = nullptr;
    GLuint m_id = 0;                                        // the texture being filled
    int m_uploading = 0, m_row = 0;
};
