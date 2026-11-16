"""Serves the lab files and stores POSTed reports. usage: python3 -I server.py <dir> <port>"""
import http.server, sys, os, time
root, port = sys.argv[1], int(sys.argv[2])
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(s, *a, **k): super().__init__(*a, directory=root, **k)
    def do_POST(s):
        n = int(s.headers.get('content-length', 0)); body = s.rfile.read(n)
        name = os.path.basename(s.path.strip('/')) or 'report'
        with open(os.path.join(root, '..', 'reports', f"{time.strftime('%H%M%S')}-{name}.json"), 'wb') as f: f.write(body)
        s.send_response(200); s.send_header('Access-Control-Allow-Origin', '*'); s.end_headers(); s.wfile.write(b'ok')
    def end_headers(s): s.send_header('Cache-Control', 'no-store'); super().end_headers()
http.server.ThreadingHTTPServer(('0.0.0.0', port), H).serve_forever()
