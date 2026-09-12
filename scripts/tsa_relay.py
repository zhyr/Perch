#!/usr/bin/env python3
"""本地 RFC3161 中转：codesign -> 本机 HTTP -> 上游 TSA（可指定真实 IP + Host 头，绕过代理域名规则）

用法:
  python3 tsa_relay.py <本地端口> <上游URL> [Host头] [--proxy] [--ua VALUE]
"""
import sys
import http.server
import urllib.request
import urllib.error

PORT = int(sys.argv[1])
UPSTREAM = sys.argv[2]
HOST_HEADER = sys.argv[3] if len(sys.argv) > 3 and not sys.argv[3].startswith("--") else None
USE_PROXY = "--proxy" in sys.argv
UA = "codesign/1.0"


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n)
        headers = {
            "Content-Type": "application/timestamp-query",
            "Accept": "*/*",
            "User-Agent": UA,
        }
        if HOST_HEADER:
            headers["Host"] = HOST_HEADER
        req = urllib.request.Request(UPSTREAM, data=body, headers=headers)
        handlers = []
        if USE_PROXY:
            handlers.append(
                urllib.request.ProxyHandler(
                    {"http": "http://127.0.0.1:1082", "https": "http://127.0.0.1:1082"}
                )
            )
        else:
            handlers.append(urllib.request.ProxyHandler({}))
        opener = urllib.request.build_opener(*handlers)
        try:
            resp = opener.open(req, timeout=30)
            data = resp.read()
            print(f"[relay] POST {len(body)}B -> {resp.status} {len(data)}B", flush=True)
            self.send_response(200)
            self.send_header("Content-Type", "application/timestamp-reply")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except urllib.error.HTTPError as e:
            print(f"[relay] upstream HTTP {e.code}", flush=True)
            self.send_response(502)
            self.send_header("Content-Length", "0")
            self.end_headers()
        except Exception as e:  # noqa: BLE001
            print(f"[relay] upstream error {e}", flush=True)
            self.send_response(502)
            self.send_header("Content-Length", "0")
            self.end_headers()

    def log_message(self, *args):
        pass


print(
    f"[relay] 127.0.0.1:{PORT} -> {UPSTREAM} host={HOST_HEADER} proxy={USE_PROXY}",
    flush=True,
)
http.server.HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
