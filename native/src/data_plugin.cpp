// The Seimio.Data plugin: Catalog and CalendarModel (catalog.h), Streams (streams.h), Tracks (tracks.h), SkipTimes (skip.h). Plain Qt, so the same source builds for
// the TV (native/build.sh) and for the Mac previews (tools/preview/build-data.sh).
#include <QtQml>
#include "catalog.h"
#include "streams.h"
#include "tracks.h"
#include "skip.h"

class SeimioDataPlugin : public QQmlExtensionPlugin {
    Q_OBJECT
    Q_PLUGIN_METADATA(IID QQmlExtensionInterface_iid)
public:
    // on the TV this loads through the app's "native" folder import, so the URI is fixed here
    void registerTypes(const char *) override {
        qmlRegisterType<Catalog>("Seimio.Data", 1, 0, "Catalog");
        qmlRegisterType<Streams>("Seimio.Data", 1, 0, "Streams");
        qmlRegisterType<Tracks>("Seimio.Data", 1, 0, "Tracks");
        qmlRegisterType<SkipTimes>("Seimio.Data", 1, 0, "SkipTimes");
        qmlRegisterUncreatableType<CalendarModel>("Seimio.Data", 1, 0, "CalendarModel", "comes from Catalog.calendar");
    }
};

#include "data_plugin.moc"
