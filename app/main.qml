// Entry point for qml-runner. Importing "native" loads the Seimio.Native plugin, which registers its
// types and adds this folder to the import path (so `import Seimio.UI 1.0` works) before App is
// created.
// The root is the app's own window. qml-runner acts on the root it loaded: launched again while the
// app runs (picked in the launcher with the app among the recent ones), it is the root it brings back.
// The root used to be a hidden window that made the app's as a second one, to post a load error to the
// lab; qml-runner took a root that never showed for an app on its way out ("Got relaunch on closing"),
// and the app stayed minimized until it was closed from the recent list.
import QtQuick 2.12
import "native"
import "qml"

App {
    Component.onCompleted: { var x = new XMLHttpRequest(); x.open("POST", "http://192.168.1.47:8091/loadreport"); x.send(JSON.stringify({ ok: true })) }
}
