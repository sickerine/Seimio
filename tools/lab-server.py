"""The lab server the TV app talks to: serves .lab/www (variant.json switches, and media with byte ranges, as
the player asks for it) and stores every POST (frame pacing, load results) as .lab/reports/<HHMMSS>-<name>.json.
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
    def do_GET(self):
        path, asked = self.translate_path(self.path), self.headers.get("Range", "")
        if not asked.startswith("bytes=") or not os.path.isfile(path): return super().do_GET()
        size = os.path.getsize(path); first, last = asked[6:].split(",")[0].split("-")
        if first: a, b = int(first), min(int(last), size - 1) if last else size - 1
        else: a, b = max(0, size - int(last)), size - 1
        if a > b: self.send_response(416); self.send_header("Content-Range", f"bytes */{size}"); self.end_headers(); return
        self.send_response(206)
        self.send_header("Content-Type", self.guess_type(path)); self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Range", f"bytes {a}-{b}/{size}"); self.send_header("Content-Length", str(b - a + 1)); self.end_headers()
        with open(path, "rb") as f:
            f.seek(a); left = b - a + 1
            try:
                while left > 0:
                    chunk = f.read(min(left, 1 << 16))
                    if not chunk: break
                    self.wfile.write(chunk); left -= len(chunk)
            except (BrokenPipeError, ConnectionResetError): pass
    def end_headers(self): self.send_header("Cache-Control", "no-store"); super().end_headers()
    def log_message(self, *a): pass

http.server.ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
