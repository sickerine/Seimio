// Every letter the app is likely to write, in each weight of its face, drawn once at launch above the
// screen where nobody sees them. A letter's first use sends it to the GPU's glyph texture, and the TV
// takes 2 to 7 ms for each batch of new ones: a title or a description that came in with a few letters
// not yet written made its frame late (a hero's text changing, a card's title, a tab's first rows).
// Written here together, they go in four batches while the app is still loading, and stay.
// Other scripts (a title in Japanese) still arrive letter by letter.
import QtQuick 2.12

Item {
    readonly property string all: " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"
                                  + "‘’“”–—…·•×éèêëàâäîïôöùûüçñōūáíóúÉ"
    y: -200                                   // Qt draws what is off screen too, which is the point here
    Repeater {
        model: [Font.Normal, Font.Medium, Font.DemiBold, Font.Bold]
        Text { text: parent.all; textFormat: Text.PlainText; font.family: Theme.face; font.weight: modelData; font.pixelSize: 20 }
    }
}
