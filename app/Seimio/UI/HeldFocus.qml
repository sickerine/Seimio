// Whether a control draws its focused look: while it has the remote, and while a menu that took the
// remote from it is open over it (Remote.menuOver, which the app sets before it opens one). A held card
// that went back to its resting size under its menu left the frost's cutout, cut for the lifted card,
// standing wider than the card. `of` is the control; `shown` is the answer.
import QtQuick 2.12

QtObject {
    id: held
    property Item of
    property bool kept: false
    readonly property bool shown: !!of && (of.activeFocus || kept)
    property Connections lost: Connections { target: held.of; onActiveFocusChanged: held.kept = !held.of.activeFocus && Remote.menuOver }
    property Connections closed: Connections { target: Remote; onMenuOverChanged: if (!Remote.menuOver) held.kept = false }
}
