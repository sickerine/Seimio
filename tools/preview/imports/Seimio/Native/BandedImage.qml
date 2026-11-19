// Mac stand-in for the TV plugin's BandedImage: an Image that only a shader reads. `address` is the
// picture's; a listed one is asked of the picture loader as the TV's asks it, as a backdrop ("f": scaled
// to fit inside the size, never up), and any other is Qt's own to load, which scales it the same way.
// (`stage()` is the lab's.)
import QtQuick 2.12
Image {
    id: banded
    visible: false; asynchronous: true
    property string address
    source: {
        var art = "image://art/", slash = address.indexOf("/", art.length);
        return address.indexOf(art) === 0 && slash > 0 ? art + address.slice(art.length, slash) + "f" + address.slice(slash) : address;
    }
    function stage() { return ["none", "ready", "fetching", "failed"][status] }
}
