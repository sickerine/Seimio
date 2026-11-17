// A title's logo, or its name in large type when it has none. A new logo is preloaded and swapped in
// only once it has loaded (`ready` turns true), so the name never flashes in before the logo.
import QtQuick 2.12

Item {
    id: art
    property string logo
    property string name
    property int nameSize: 72
    property bool centered: false      // centre the logo or name in the box instead of starting at its left
    // true once whatever should show (the logo, or the name when there is no logo) is on screen
    readonly property bool ready: shownLogo === logo && (logo === "" || preload.status !== Image.Loading)
    property string shownLogo: ""
    property bool hasLogo: false
    width: 640; height: 180

    // a cached logo can be Ready at once without a status change, so check right after setting it too
    function load() { preload.source = logo; apply() }
    function apply() { if (preload.status !== Image.Loading) { hasLogo = preload.status === Image.Ready && logo !== ""; shownLogo = logo } }
    onLogoChanged: load()
    Component.onCompleted: load()
    Image {
        id: preload
        visible: false; asynchronous: true; sourceSize.width: 780
        onStatusChanged: art.apply()
    }
    Image {
        anchors.fill: parent
        fillMode: Image.PreserveAspectFit; horizontalAlignment: art.centered ? Image.AlignHCenter : Image.AlignLeft; verticalAlignment: Image.AlignBottom
        asynchronous: true; sourceSize.width: 780
        source: art.hasLogo ? art.shownLogo : ""
        visible: art.hasLogo
    }
    Text {
        visible: !art.hasLogo
        anchors.bottom: parent.bottom; width: art.centered ? parent.width : parent.width * 1.3
        horizontalAlignment: art.centered ? Text.AlignHCenter : Text.AlignLeft
        wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight
        text: art.name; color: Theme.ink
        font.family: Theme.face; font.pixelSize: art.nameSize; font.weight: Font.Bold; lineHeight: 0.95
    }
}
