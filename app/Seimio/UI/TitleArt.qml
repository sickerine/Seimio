// A title's logo, or its name in large type when it has none (or it fails to load). A new title is
// committed whole, through a Swap (Swap.qml): the logo is loaded first, and the name and logo on screen
// change together once it has, so a name never shows while its logo is on the way. Between two titles
// nothing fades (what holds a TitleArt fades the whole of itself); a title appearing where there was
// none fades in, since a page's entrance may finish before its logo has loaded. `ready` is true once
// what should show is on screen.
import QtQuick 2.12

Item {
    id: art
    property string logo
    property string name
    property int nameSize: 72
    property bool centered: false      // centre the logo or name in the box instead of starting at its left
    readonly property bool ready: !swap.busy
    readonly property string shownLogo: swap.shown ? swap.shown.logo : ""
    readonly property string shownName: swap.shown ? swap.shown.name : ""
    property bool hasLogo: false       // the title on show has a logo, and it loaded
    width: 640; height: 180
    function labState() { return { ready: ready, logo: shownLogo, has: hasLogo, name: shownName, picture: picture.status, painted: Math.round(picture.paintedWidth) + "x" + Math.round(picture.paintedHeight), opacity: content.opacity, preload: preload.status } }      // lab

    Swap {
        id: swap
        want: art.logo || art.name ? { logo: art.logo, name: art.name } : null
        same: function (a, b) { return a.logo === b.logo && a.name === b.name }
        // its logo is in, or it has none, or it can't be had
        ready: preload.source.toString() === "" || preload.status !== Image.Loading
        outMs: 0; inMs: 0; appearMs: 260
        // (at the switch the preload is this title's, and settled: that says whether it has a logo to show)
        onSwitched: art.hasLogo = shown.logo !== "" && preload.status === Image.Ready
    }
    Image {
        id: preload
        // The size and the fit of the picture below, or it preloads nothing: Qt keeps a picture by its
        // address, size and fit. With the default fit here the picture was fetched a second time once
        // this one was in, and the logo came in after the title around it had (a second or more late
        // from a slow host), without a fade.
        visible: false; asynchronous: true; sourceSize.width: 780; fillMode: Image.PreserveAspectFit
        source: art.logo
    }
    Item {
        id: content
        anchors.fill: parent
        opacity: swap.level
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
