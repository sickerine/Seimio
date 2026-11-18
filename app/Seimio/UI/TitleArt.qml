// A title's logo, or its name in large type when it has none (or it fails to load). A new title is
// committed whole: the logo is preloaded, and the name and logo on screen change together once it has
// loaded (`ready` turns true), so a name never shows while its logo is on the way. A title appearing
// where there was none fades in (a page's entrance may finish before its logo has loaded).
import QtQuick 2.12

Item {
    id: art
    property string logo
    property string name
    property int nameSize: 72
    property bool centered: false      // centre the logo or name in the box instead of starting at its left
    // true once whatever should show (the logo, or the name when there is no logo) is on screen
    readonly property bool ready: shownLogo === logo && shownName === name && (logo === "" || preload.status !== Image.Loading)
    property string shownLogo: ""
    property string shownName: ""
    property bool hasLogo: false
    width: 640; height: 180
    function labState() { return { ready: ready, logo: shownLogo, has: hasLogo, name: shownName, picture: picture.status, painted: Math.round(picture.paintedWidth) + "x" + Math.round(picture.paintedHeight), opacity: content.opacity, preload: preload.status } }      // lab

    // a cached logo can be Ready at once without a status change, so check right after setting it too
    function load() { preload.source = logo; apply() }
    function apply() {
        if (preload.status === Image.Loading) return;
        if (!shownLogo && !shownName && (logo || name)) appear.restart();
        hasLogo = preload.status === Image.Ready && logo !== ""; shownLogo = logo; shownName = name;
    }
    NumberAnimation { id: appear; target: content; property: "opacity"; from: 0; to: 1; duration: 260; easing.type: Theme.ease }
    onLogoChanged: load()
    onNameChanged: apply()
    Component.onCompleted: load()
    Image {
        id: preload
        // The size and the fit of the picture below, or it preloads nothing: Qt keeps a picture by its
        // address, size and fit. With the default fit here the picture was fetched a second time once
        // this one was in, and the logo came in after the title around it had (a second or more late
        // from a slow host), without a fade.
        visible: false; asynchronous: true; sourceSize.width: 780; fillMode: Image.PreserveAspectFit
        onStatusChanged: art.apply()
    }
    Item {
        id: content
        anchors.fill: parent
        Image {
            id: picture
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
            text: art.shownName; color: Theme.ink
            font.family: Theme.face; font.pixelSize: art.nameSize; font.weight: Font.Bold; lineHeight: 0.95
        }
    }
}
