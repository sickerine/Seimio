"""The lab server the TV app talks to: serves .lab/www (variant.json switches) and stores every POST
(frame pacing, load results) as .lab/reports/<HHMMSS>-<name>.json.
usage: python3 -I tools/lab-server.py [port]   (from anywhere; paths are relative to the repo)"""
import http.server, os, sys, time
repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
www, reports = os.path.join(repo, ".lab", "www"), os.path.join(repo, ".lab", "reports")
os.makedirs(www, exist_ok=True); os.makedirs(reports, exist_ok=True)
port = int(sys.argv[1]) if len(sys.argv) > 1 else 8091

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k): super().__init__(*a, directory=www, **k)
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", 0)))
        name = os.path.basename(self.path.strip("/")) or "report"
        with open(os.path.join(reports, f"{time.strftime('%H%M%S')}-{name}.json"), "wb") as f: f.write(body)
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def end_headers(self): self.send_header("Cache-Control", "no-store"); super().end_headers()
    def log_message(self, *a): pass

http.server.ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
