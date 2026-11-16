"""Serves files with HTTP Range support (media players seek with byte ranges). usage: rangeserver.py <dir> <port>"""
import http.server, os, re, sys, shutil
root, port = sys.argv[1], int(sys.argv[2])
class H(http.server.BaseHTTPRequestHandler):
    def do_HEAD(s): s.serve(False)
    def do_GET(s): s.serve(True)
    def serve(s, body):
        p = os.path.join(root, os.path.basename(s.path.split('?')[0]))
        if not os.path.isfile(p): s.send_error(404); return
        size = os.path.getsize(p); start, end = 0, size - 1
        m = re.match(r'bytes=(\d*)-(\d*)', s.headers.get('Range', ''))
        if m:
            if m.group(1): start = int(m.group(1)); end = int(m.group(2)) if m.group(2) else size - 1
            else: start = size - int(m.group(2))
            s.send_response(206); s.send_header('Content-Range', f'bytes {start}-{end}/{size}')
        else: s.send_response(200)
        s.send_header('Accept-Ranges', 'bytes'); s.send_header('Content-Length', str(end - start + 1))
        s.send_header('Content-Type', 'video/x-matroska'); s.end_headers()
        if not body: return
        with open(p, 'rb') as f:
            f.seek(start); left = end - start + 1
            try:
                while left > 0:
                    chunk = f.read(min(1 << 20, left))
                    if not chunk: break
                    s.wfile.write(chunk); left -= len(chunk)
            except (BrokenPipeError, ConnectionResetError): pass
    def log_message(s, *a): pass
http.server.ThreadingHTTPServer(('0.0.0.0', port), H).serve_forever()
