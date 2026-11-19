// Every letter the app is likely to write, in each weight of its face, drawn once at launch above the
// screen where nobody sees them. A letter's first use sends it to the GPU's glyph texture, and the TV
// takes 2 to 7 ms for each batch of new ones: a title or a description that came in with a few letters
// not yet written made its frame late (a hero's text changing, a card's title, a tab's first rows).
// Written here together, they go in four batches while the app is still loading, and stay.
// Other scripts (a title in Japanese) still arrive letter by letter.
// A letter here is a glyph of the face, and the face joins some pairs into one: fi, fl, ffi, ffl (and
// "->"). Those are glyphs of their own, written only where the letters stand together, so they are
// spelled out below: "fi" is in a tenth of the titles and descriptions the services send, and its first
// use in each weight was a glyph sent alone, 4 to 8 ms of the frame a title or a tab came in on.
// (Shape a string with the face to see its glyphs: hb-shape app/Seimio/UI/assets/InstrumentSans-500.ttf "…".
// Only what the face has goes here: a letter it lacks is drawn from another face, loaded for it.)
import QtQuick 2.12

Item {
    readonly property string all: " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"
                                  + "‘’“”–—…·•×éèêëàâäîïôöùûüçñōūáíóúÉ"
                                  + " fi fl ffi ffl -> "
                                  + "ÆæÅåÁÀÂÄÃãØøŒœßÍÌÎÏìÓÒÔÖÕõòÚÙÛÜÝýÿÑÇĆćŃńŚśı¡¿«»‹›„‚°€£¥¢©®™§¶÷"
    y: -200                                   // Qt draws what is off screen too, which is the point here
    Repeater {
        model: [Font.Normal, Font.Medium, Font.DemiBold, Font.Bold]
        Text { text: parent.all; textFormat: Text.PlainText; font.family: Theme.face; font.weight: modelData; font.pixelSize: 20 }
    }
}
