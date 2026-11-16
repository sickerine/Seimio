// Loads Win.qml and reports a load error to the Mac instead of failing silently.
import QtQuick 2.12
import QtQuick.Window 2.12
import "native"
Window {
    visible: false
    property var win
    Component.onCompleted: {
        var c = Qt.createComponent("Win.qml");
        var x = new XMLHttpRequest();
        x.open("POST", "http://192.168.1.47:8091/loadreport");
        if (c.status === Component.Error) { x.send(JSON.stringify({ error: c.errorString() })); return; }
        win = c.createObject(null);
        x.send(JSON.stringify({ ok: !!win }));
    }
}
