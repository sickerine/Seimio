// Android's stand-in for LG's WebOSWindow: the app's window, full screen, with the screen laid out on the
// LG's 1920x1080 canvas scaled to fit whatever the TV draws apps at.
import QtQuick 2.12
import QtQuick.Window 2.12
Window {
    enum KeyMask { KeyMaskExit = 1, KeyMaskBack = 2, KeyMaskHome = 4, KeyMaskOk = 8, KeyMaskLeft = 16, KeyMaskRight = 32, KeyMaskUp = 64, KeyMaskDown = 128, KeyMaskInfo = 256, KeyMaskDefault = 1073741816 }
    property string appId
    property int keyMask
    property alias canvas: canvas
    default property alias content: canvas.data
    visibility: Window.FullScreen
    color: "black"
    Item { id: canvas; width: 1920; height: 1080; scale: Math.min(parent.width / 1920, parent.height / 1080); transformOrigin: Item.TopLeft }
}
