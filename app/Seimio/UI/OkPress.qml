// OK for a control: emits `tapped` or `held` (see Remote for how the two are told apart). A control
// declares one and forwards its keys to it with `Keys.forwardTo: [ok]`; other keys pass through.
import QtQuick 2.12

Item {
    id: ok
    signal tapped()
    signal held()
    Keys.onPressed: if (Remote.isOk(event.key)) { event.accepted = true; Remote.okPress(ok, event) }
    Keys.onReleased: if (Remote.isOk(event.key)) { event.accepted = true; Remote.okRelease(event) }
}
