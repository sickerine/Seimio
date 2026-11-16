// Small vector icons drawn once into a texture: play, plus, star, check, search, info.
import QtQuick 2.12

Canvas {
    id: icon
    property string name
    property color color: "white"
    width: 28; height: 28
    onColorChanged: requestPaint()
    onNameChanged: requestPaint()
    onPaint: {
        var c = getContext("2d"), w = width, h = height;
        c.reset(); c.fillStyle = color; c.strokeStyle = color; c.lineCap = "round"; c.lineJoin = "round";
        c.lineWidth = w * 0.11;
        c.beginPath();
        if (name === "play") { c.moveTo(w * 0.28, h * 0.18); c.lineTo(w * 0.84, h * 0.5); c.lineTo(w * 0.28, h * 0.82); c.closePath(); c.fill(); }
        else if (name === "plus") { c.moveTo(w * 0.5, h * 0.18); c.lineTo(w * 0.5, h * 0.82); c.moveTo(w * 0.18, h * 0.5); c.lineTo(w * 0.82, h * 0.5); c.stroke(); }
        else if (name === "check") { c.moveTo(w * 0.2, h * 0.52); c.lineTo(w * 0.42, h * 0.74); c.lineTo(w * 0.82, h * 0.28); c.stroke(); }
        else if (name === "search") { c.arc(w * 0.44, h * 0.44, w * 0.24, 0, Math.PI * 2); c.moveTo(w * 0.62, h * 0.62); c.lineTo(w * 0.84, h * 0.84); c.stroke(); }
        else if (name === "info") { c.arc(w * 0.5, h * 0.5, w * 0.36, 0, Math.PI * 2); c.stroke(); c.beginPath(); c.moveTo(w * 0.5, h * 0.46); c.lineTo(w * 0.5, h * 0.68); c.stroke(); c.beginPath(); c.arc(w * 0.5, h * 0.32, w * 0.06, 0, Math.PI * 2); c.fill(); }
        else if (name === "star") {
            for (var i = 0; i < 10; i++) {
                var r = i % 2 ? w * 0.2 : w * 0.46, a = -Math.PI / 2 + i * Math.PI / 5;
                if (i === 0) c.moveTo(w / 2 + r * Math.cos(a), h / 2 + r * Math.sin(a)); else c.lineTo(w / 2 + r * Math.cos(a), h / 2 + r * Math.sin(a));
            }
            c.closePath(); c.fill();
        }
    }
}
