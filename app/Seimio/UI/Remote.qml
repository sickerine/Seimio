// What the LG remote's keys mean.
pragma Singleton
import QtQuick 2.12

QtObject {
    // LG's remote sends its own code for Back (0x1200003); Escape and Back cover keyboards and the Mac
    function isBack(k) { return k === Qt.Key_Escape || k === Qt.Key_Back || k === 0x1200003 }
    function isOk(k) { return k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Select }
}
