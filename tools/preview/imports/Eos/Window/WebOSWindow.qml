// Mac stand-in for LG's WebOSWindow, so lab screens render in Qt on the Mac for screenshots. The
// screen is laid out on a 1920x1080 canvas shown at half size (Mac displays are smaller than that);
// shot.qml grabs the canvas itself, at full resolution.
import QtQuick 2.12
import QtQuick.Window 2.12
Window {
    id: w
    enum KeyMask { KeyMaskExit = 1, KeyMaskBack = 2, KeyMaskHome = 4, KeyMaskOk = 8, KeyMaskLeft = 16, KeyMaskRight = 32, KeyMaskUp = 64, KeyMaskDown = 128, KeyMaskInfo = 256, KeyMaskDefault = 1073741816 }
    property string appId
    property int keyMask
    property alias canvas: canvas
    default property alias content: canvas.data
    width: 960; height: 540
    flags: Qt.FramelessWindowHint
    Item { id: canvas; width: 1920; height: 1080; scale: 0.5; transformOrigin: Item.TopLeft }
}
