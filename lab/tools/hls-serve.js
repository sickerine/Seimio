// Serves a folder of HLS output on the TV (test helper). usage: node hls-serve.js <dir> <port>
var http = require('http'), fs = require('fs'), path = require('path');
var dir = process.argv[2], port = +process.argv[3];
var types = { '.m3u8': 'application/vnd.apple.mpegurl', '.m4s': 'video/iso.segment', '.mp4': 'video/mp4' };
http.createServer(function (req, res) {
    var file = path.join(dir, path.basename(req.url.split('?')[0]));
    fs.readFile(file, function (err, data) {
        if (err) { res.writeHead(404); return res.end(); }
        // a growing playlist reads as live, so players jump to the live edge; pin the start to 0
        if (path.extname(file) === '.m3u8') data = Buffer.from(String(data).replace('#EXTM3U\n', '#EXTM3U\n#EXT-X-START:TIME-OFFSET=0,PRECISE=YES\n'));
        res.writeHead(200, { 'Content-Type': types[path.extname(file)] || 'application/octet-stream', 'Cache-Control': 'no-store' });
        res.end(data);
    });
}).listen(port, '127.0.0.1');
