// Renders a lab screen on the Mac and saves a screenshot. The JS runs once the screen has loaded its
// data (after 40% of the wait), then the shot is taken at the end of the wait.
// usage: qml -I imports shot.qml -- <screen.qml> <out.png> '<js run on the window>' [wait ms] [js at ms] ['<initial properties JSON>']
import QtQuick 2.12
Item {
    property var args: Qt.application.arguments.slice(Qt.application.arguments.indexOf("--") + 1)
    property var w
    Component.onCompleted: {
        var c = Qt.createComponent("file://" + args[0]);
        if (c.status === Component.Error) { console.log(c.errorString()); Qt.quit(); return }
        w = c.createObject(null, args[5] ? JSON.parse(args[5]) : {});
        var wait = Number(args[3] || 2500);
        prepare.interval = Number(args[4] || wait * 0.4); settle.interval = wait;
        prepare.start(); settle.start();
    }
    Timer { id: prepare; onTriggered: if (args[2]) new Function("win", args[2])(w) }
    Timer { id: settle; onTriggered: (w.canvas || w.contentItem).grabToImage(function (r) { r.saveToFile(args[1]); console.log("saved " + args[1]); Qt.quit() }) }
}
