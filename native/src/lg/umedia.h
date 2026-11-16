// Declarations for LG's uMediaServer client and window export, matched to the TV's libraries by
// mangled name (libumedia_api.so.1, libwebos-platform-interface.so.1). No public headers exist for
// LG's build, so only what the player calls is declared. The vtable of uMediaClient has 49 event
// slots after the destructors (read from the TV library); with rawEvents every event arrives as JSON
// through one of them, onUserDefinedChanged.
#pragma once
#include <string>
#include <QString>

class QWindow;
class QRegion;

enum UMSConnectorBusType { UMS_BUS_0 = 0, UMS_BUS_1, UMS_BUS_2, UMS_BUS_APP = 3 };

#define UMS_SLOTS(X) X(0) X(1) X(2) X(3) X(4) X(5) X(6) X(7) X(8) X(9) X(10) X(11) X(12) X(13) X(14) X(15) \
    X(16) X(17) X(18) X(19) X(20) X(21) X(22) X(23) X(24) X(25) X(26) X(27) X(28) X(29) X(30) X(31) X(32) \
    X(33) X(34) X(35) X(36) X(37) X(38) X(39) X(40) X(41) X(42) X(43) X(44) X(45) X(46) X(47) X(48)

namespace uMediaServer {
class uMediaClient {
public:
    uMediaClient(bool rawEvents, UMSConnectorBusType bus);
    virtual ~uMediaClient();
#define UMS_DECL(n) virtual bool slot##n(void *, void *, void *) = 0;
    UMS_SLOTS(UMS_DECL)
#undef UMS_DECL
    bool loadAsync(const std::string &uri, const std::string &type, const std::string &payload);
    bool play();
    bool pause();
    bool seek(long long position);
    bool unload();
    bool selectTrack(std::string &type, int index);
private:
    char m_opaque[4096]; // the real object is smaller; this keeps subclass members clear of it
};
}

class WebOSExported {
public:
    QString getWindowId();
    void setExportedWindow(const QRegion &source, const QRegion &destination);
};

class WebOSForeign {
public:
    enum WebOSExportedType { VideoObject = 0 };
    WebOSExported *export_element(QWindow *window, WebOSExportedType type);
};

class WebOSPlatform {
public:
    static WebOSPlatform *instance();
    WebOSForeign *webOSForeign();
};
