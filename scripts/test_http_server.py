#!/usr/bin/env python3
"""Minimal Smart HTTP server for testing gitz against real git-http-backend.

Optional HTTP Basic Auth: pass AUTH_USER/AUTH_PASS env vars to require
credentials on every request (like a private GitHub repo)."""
import base64, http.server, subprocess, sys, os, urllib.parse

REPO_ROOT = sys.argv[2] if len(sys.argv) > 2 else "/tmp/gitz_http_test/repos"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
AUTH_USER = os.environ.get("AUTH_USER")
AUTH_PASS = os.environ.get("AUTH_PASS")

class GitHTTP(http.server.BaseHTTPRequestHandler):
    def check_auth(self):
        if AUTH_USER is None:
            return True
        expected = "Basic " + base64.b64encode(f"{AUTH_USER}:{AUTH_PASS}".encode()).decode()
        got = self.headers.get("Authorization", "")
        if got == expected:
            return True
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="gitz test"')
        self.send_header("Content-Length", "0")
        self.end_headers()
        sys.stderr.write(f"AUTH FAILED: got={got!r} want={expected!r}\n")
        return False

    def do_GET(self):
        if not self.check_auth():
            return
        self.handle_req("GET")

    def do_POST(self):
        if not self.check_auth():
            return
        self.handle_req("POST")

    def handle_req(self, method):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        query = urllib.parse.parse_qs(parsed.query)
        # /repo.git/info/refs?service=... or /repo.git/git-upload-pack
        if ".git/" not in path:
            self.send_error(404)
            return
        repo_rel = path.split(".git/")[0] + ".git"
        sub = path[len(repo_rel):]
        env = dict(os.environ)
        env.update({
            "GIT_PROJECT_ROOT": REPO_ROOT,
            "GIT_HTTP_EXPORT_ALL": "1",
            "PATH_INFO": repo_rel + sub,
            "REQUEST_METHOD": method,
            "QUERY_STRING": parsed.query,
            "CONTENT_TYPE": self.headers.get("Content-Type", ""),
            "REMOTE_ADDR": "127.0.0.1",
        })
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        proc = subprocess.run(
            ["/usr/lib/git-core/git-http-backend"],
            input=body, env=env, capture_output=True)
        sys.stderr.write(f"BACKEND rc={proc.returncode} err={proc.stderr!r}\n")
        out = proc.stdout
        # Parse CGI headers
        header_end = out.find(b"\r\n\r\n")
        sep_len = 4
        if header_end < 0:
            header_end = out.find(b"\n\n")
            sep_len = 2
        headers_blob = out[:header_end]
        payload = out[header_end + sep_len:]
        status = 200
        headers = []
        for line in headers_blob.decode(errors="replace").splitlines():
            k, _, v = line.partition(":")
            if k.strip().lower() == "status":
                status = int(v.strip().split()[0])
            else:
                headers.append((k.strip(), v.strip()))
        self.send_response(status)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *a):
        pass

if __name__ == "__main__":
    os.makedirs(REPO_ROOT, exist_ok=True)
    http.server.HTTPServer(("127.0.0.1", PORT), GitHTTP).serve_forever()
