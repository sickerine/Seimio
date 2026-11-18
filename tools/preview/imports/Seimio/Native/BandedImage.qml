// Mac stand-in for the TV plugin's BandedImage: an Image that only a shader reads. (`fallback`, the
// picture the TV shows while the source isn't on disk yet, is taken and not used: a preview's pictures
// are all on disk. `stage()` is the lab's.)
import QtQuick 2.12
Image {
    visible: false; asynchronous: true
    property url fallback
    function stage() { return ["none", "ready", "fetching", "failed"][status] }
}
