// Entry point for qml-runner. Importing "native" loads the Seimio.Native plugin, which registers its
// types and adds this folder to the import path (so `import Seimio.UI 1.0` works) before App is
// created. qml-runner exits if the root isn't a window, so this one is hidden. A load error is posted
// to the lab server instead of failing silently.
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
        x.send(JSON.stringify({ ok: !!app }));
    }
}
