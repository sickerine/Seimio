// Signing in, as Stremio's own TV apps do it: a code to approve on a phone, by scanning the QR or typing
// it at the address shown. `link` is Account's ({ state, code, address, qr }); it asks for a code when it
// comes up and stops when it goes.
import QtQuick 2.12
import Seimio.UI 1.0

Item {
    id: page
    property bool active: false
    property var account
    readonly property var link: account ? account.link : ({})
    onActiveChanged: if (account) { if (active) account.signIn(); else account.cancelSignIn() }
    opacity: active ? 1 : 0      // holds: the code and QR stay as they were while it fades (Fade below)
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: Theme.slow } }

    Column {
        x: Theme.margin; anchors.verticalCenter: parent.verticalCenter
        spacing: 0
        Text { text: "Sign in to Stremio"; color: Theme.ink; font.family: Theme.face; font.pixelSize: 68; font.weight: Font.DemiBold }
        Item { width: 1; height: 28 }
        Text {
            width: 820; wrapMode: Text.WordWrap; lineHeight: 1.25
            text: "Scan the code with your phone, or open " + (page.link.address || "link.stremio.com") + " and enter it there."
            color: Theme.inkSoft; font.family: Theme.face; font.pixelSize: 30
        }
        Item { width: 1; height: 64 }
        // the code, a tile a character; the tiles are there from the start, so nothing shifts when it arrives
        Row {
            spacing: 20
            Repeater {
                model: 4
                Rectangle {
                    width: 132; height: 156; radius: 28; color: Theme.fill; border.width: 1; border.color: Theme.hairline
                    Fade {
                        anchors.centerIn: parent
                        value: (page.link.code || "").charAt(index)
                        Text { text: parent.current || ""; color: Theme.ink; font.family: Theme.face; font.pixelSize: 96; font.weight: Font.DemiBold }
                    }
                }
            }
        }
        Item { width: 1; height: 44 }
        Item {
            width: 820; height: 40
            Fade {
                value: page.link.state === "failed" ? "Couldn't reach Stremio. Trying again." : page.link.state === "waiting" ? "Waiting for you to approve it" : page.link.state === "asking" ? "Getting a code" : ""
                Text { text: parent.current || ""; color: Theme.inkDim; font.family: Theme.face; font.pixelSize: 26; font.weight: Font.Medium }
            }
        }
    }
    // the QR on white, as a phone's camera wants it
    Rectangle {
        x: parent.width - Theme.margin - width; anchors.verticalCenter: parent.verticalCenter
        width: 520; height: 520; radius: 44; color: "white"
        Fade {
            anchors.centerIn: parent
            value: page.link.qr || ""
            Image {
                width: 440; height: 440; source: parent.current || ""; smooth: false; fillMode: Image.PreserveAspectFit
                opacity: status === Image.Ready ? 1 : 0      // holds: only ever fades in, once decoded
                Behavior on opacity { NumberAnimation { duration: Theme.base } }
            }
        }
    }
}
