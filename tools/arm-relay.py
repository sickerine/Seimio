# Asks arm.haglund.dev for the Mac's Qt, which can't make a TLS connection to it (this Python can't either,
# so through curl). Run beside a Mac run with SEIMIO_VIA="arm.haglund.dev=http://127.0.0.1:<port>"
# (native/src/net.h). usage: python3 -I tools/arm-relay.py <port>
import sys, subprocess, http.server
class Relay(http.server.BaseHTTPRequestHandler):
    def go(self, body=None):
        cmd = ["curl", "-s", "-m", "30", "-A", "seimio/0.1", "-X", self.command, "-w", "\n%{http_code}", "https://arm.haglund.dev" + self.path]
        if body is not None: cmd += ["-H", "Content-Type: application/json", "--data-binary", "@-"]
        out = subprocess.run(cmd, input=body, capture_output=True).stdout
        data, _, code = out.rpartition(b"\n")
        self.send_response(int(code or 502)); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self): self.go()
    def do_POST(self): self.go(self.rfile.read(int(self.headers.get("Content-Length", 0))))
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Relay).serve_forever()
