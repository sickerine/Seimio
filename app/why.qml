// Why the app doesn't load on the TV. qml-runner says what is wrong with a QML file only where dev mode
// can't read it, and with main.qml's root being the app itself a file the TV's Qt 5.12 won't take is an
// app that closes as it opens. tools/deploy.sh puts this in main.qml's place when no load report came:
// a hidden window (qml-runner wants a window for a root) that makes App and posts why it can't be made.
// Never the app's own entry: a root that doesn't show is an app qml-runner won't bring back (main.qml).
import QtQuick 2.12
import QtQuick.Window 2.12
import "native"

Window {
    visible: false
    property var app
    Component.onCompleted: {
        var c = Qt.createComponent("qml/App.qml");
        var x = new XMLHttpRequest();
        x.open("POST", "http://192.168.1.47:8091/loadreport");
        if (c.status === Component.Error) { x.send(JSON.stringify({ error: c.errorString() })); return }
        app = c.createObject(null);
        x.send(JSON.stringify({ why: "it loads from why.qml: the fault is in main.qml or shows only with App as the root", ok: !!app }));
    }
}
