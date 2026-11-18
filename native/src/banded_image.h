#pragma once
// BandedImage: a picture for a shader to read, as Image { visible: false; asynchronous: true } is, whose
// pixels go to the GPU a band a frame. Sent whole, a 1920 x 1080 picture took the TV 15 to 20 ms in the
// frame that first drew it, so every backdrop's crossfade began on a late frame (with backdrops decoded at
// a quarter of the size, a Home tour's late frames fell from 11-14 to 6).
//
// The picture is fetched through the QML engine's network manager (its disk cache), decoded on a thread
// down to fit `sourceSize`, never up, as Image does, and uploaded after each frame's drawing into a texture
// nothing reads yet: the TV's driver stalls 10-15 ms when a texture the last frame read is written to.
// `status` (Image's values) turns Ready when all of it is there, and only then does a shader get it.
#include <QQuickItem>
#include <QQuickWindow>
#include <QSGTextureProvider>
#include <QSGTexture>
#include <QImageReader>
#include <QBuffer>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QQmlEngine>
#include <QOpenGLContext>
#include <QOpenGLFunctions>
#include <QMutex>
#include <QThread>
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
    Q_PROPERTY(QUrl source READ source WRITE setSource NOTIFY sourceChanged)
    Q_PROPERTY(QSize sourceSize MEMBER m_sourceSize)
    Q_PROPERTY(int status READ status NOTIFY statusChanged)         // Image's: 0 Null, 1 Ready, 2 Loading, 3 Error
public:
    enum Status { Null, Ready, Loading, Error };
    QUrl source() const { return m_source; }
    int status() const { return m_status; }
    void setSource(const QUrl &url) {
        if (url == m_source) return;
        m_source = url; emit sourceChanged();
        const int ticket = ++m_ticket;
        if (m_reply) { m_reply->disconnect(this); m_reply->abort(); m_reply->deleteLater(); m_reply = nullptr; }
        hand(QImage(), ticket);                              // the picture it had goes
        setImplicitSize(0, 0);
        if (url.isEmpty()) { setStatus(Null); return; }
        setStatus(Loading);
        QNetworkRequest request(url);
        request.setAttribute(QNetworkRequest::FollowRedirectsAttribute, true);
        m_reply = qmlEngine(this)->networkAccessManager()->get(request);
        connect(m_reply, &QNetworkReply::finished, this, [this, ticket, reply = m_reply] {
            reply->deleteLater();
            if (ticket != m_ticket) return;
            m_reply = nullptr;
            if (reply->error()) { setStatus(Error); return; }
            auto decoded = std::make_shared<QImage>();
            QThread *worker = QThread::create([decoded, data = reply->readAll(), fit = m_sourceSize] {
                QBuffer buffer; buffer.setData(data); buffer.open(QIODevice::ReadOnly);
                QImageReader reader(&buffer);
                const QSize full = reader.size();
                if (full.isValid() && fit.isValid() && (full.width() > fit.width() || full.height() > fit.height())) reader.setScaledSize(full.scaled(fit, Qt::KeepAspectRatio));
                *decoded = reader.read().convertToFormat(QImage::Format_RGBX8888);       // as the GPU takes it, so nothing is converted on the render thread
            });
            connect(worker, &QThread::finished, this, [this, ticket, decoded] {
                if (ticket != m_ticket) return;
                if (decoded->isNull()) { setStatus(Error); return; }
                setImplicitSize(decoded->width(), decoded->height());
                hand(*decoded, ticket);
            });
            connect(worker, &QThread::finished, worker, &QObject::deleteLater);
            worker->start();
        });
    }
    bool isTextureProvider() const override { return true; }
    // render thread. A shader always has something to read: until a picture is in, one black pixel
    QSGTextureProvider *textureProvider() const override {
        if (!m_provider) {
            m_provider = new BandedProvider;
            QImage none(1, 1, QImage::Format_RGBX8888); none.fill(Qt::black);
            m_provider->shown = window()->createTextureFromImage(none);
        }
        return m_provider;
    }
signals:
    void sourceChanged();
    void statusChanged();
protected:
    void itemChange(ItemChange change, const ItemChangeData &data) override {
        if (change == ItemSceneChange && data.window)
            connect(data.window, &QQuickWindow::afterRendering, this, &BandedImage::upload, Qt::ConnectionType(Qt::DirectConnection | Qt::UniqueConnection));
        QQuickItem::itemChange(change, data);
    }
    void releaseResources() override {
        struct Gone : QRunnable { BandedProvider *provider; void run() override { delete provider; } };
        if (!m_provider || !window()) return;
        auto *gone = new Gone; gone->provider = m_provider; m_provider = nullptr;
        window()->scheduleRenderJob(gone, QQuickWindow::BeforeSynchronizingStage);
    }
private:
    void setStatus(int s) { if (s != m_status) { m_status = s; emit statusChanged(); } }
    // GUI thread: the picture for the render thread to take (none: its texture goes)
    void hand(const QImage &image, int ticket) {
        { QMutexLocker l(&m_mutex); m_image = image; m_handed = ticket; }
        m_work = true;
        if (window()) window()->update();
    }
    // render thread, after a frame's drawing: one band more of the picture in hand
    void upload() {
        if (!m_work) return;
        QImage image; int ticket;
        { QMutexLocker l(&m_mutex); image = m_image; ticket = m_handed; }
        QOpenGLFunctions *gl = QOpenGLContext::currentContext()->functions();
        if (ticket != m_uploading) {                        // another picture than the one being sent, or none
            if (m_id) { gl->glDeleteTextures(1, &m_id); m_id = 0; }
            m_uploading = ticket; m_row = 0;
            if (image.isNull()) {
                QImage none(1, 1, QImage::Format_RGBX8888); none.fill(Qt::black);
                static_cast<BandedProvider *>(textureProvider())->show(window()->createTextureFromImage(none));
            }
        }
        if (image.isNull()) { done(ticket); return; }
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
        gl->glTexSubImage2D(GL_TEXTURE_2D, 0, 0, m_row, image.width(), rows, GL_RGBA, GL_UNSIGNED_BYTE, image.constScanLine(m_row));
        gl->glBindTexture(GL_TEXTURE_2D, 0);
        m_row += rows;
        if (m_row < image.height()) { window()->update(); return; }       // a frame more, for the next band
        QSGTexture *whole = window()->createTextureFromId(m_id, image.size(), QQuickWindow::TextureOwnsGLTexture);
        whole->setFiltering(QSGTexture::Linear);
        m_id = 0;
        static_cast<BandedProvider *>(textureProvider())->show(whole);
        done(ticket);                                       // the GPU has it now
        QMetaObject::invokeMethod(this, [this, ticket] { if (ticket == m_ticket) setStatus(Ready); }, Qt::QueuedConnection);
    }

    // nothing more to send, unless another picture was handed over meanwhile
    void done(int ticket) { QMutexLocker l(&m_mutex); if (m_handed == ticket) { m_image = QImage(); m_work = false; } }

    enum { Band = 136 };                                    // rows a frame: an eighth of 1080
    QUrl m_source;
    QSize m_sourceSize;
    int m_status = Null;
    int m_ticket = 0;                                       // which picture is wanted (GUI thread)
    QNetworkReply *m_reply = nullptr;
    QMutex m_mutex;
    QImage m_image;                                         // decoded and waiting for the GPU (under m_mutex)
    int m_handed = 0;                                       // its ticket (under m_mutex)
    std::atomic<bool> m_work{false};
    // render thread
    mutable BandedProvider *m_provider = nullptr;
    GLuint m_id = 0;                                        // the texture being filled
    int m_uploading = 0, m_row = 0;
};
