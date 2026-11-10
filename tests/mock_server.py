#!/usr/bin/env python3
"""自检用的双栈 HTTP 服务器：同一端口分别监听 127.0.0.1 与 ::1。

/which 会明确返回 IPV4 或 IPV6，用来证明扫描器真的通过 IPv6 建立了连接，
而不是把 IPv6 地址回退到 IPv4。
"""
import argparse
import http.server
import socket
import socketserver
import sys
import threading
import time


class V4Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    address_family = socket.AF_INET
    allow_reuse_address = True
    daemon_threads = True


class V6Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    address_family = socket.AF_INET6
    allow_reuse_address = True
    daemon_threads = True

    def server_bind(self):
        try:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        except OSError:
            pass
        super().server_bind()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _write_log(self, line):
        with self.server.log_lock:
            with open(self.server.log_file, "a", encoding="utf-8") as f:
                f.write(line + "\n")

    def _respond(self, code, body):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def do_GET(self):
        self._handle()

    def do_HEAD(self):
        self._handle()

    def _handle(self):
        path = self.path.split("?", 1)[0]
        tag = self.server.tag
        self._write_log("%s %s %s" % (tag, self.path, self.client_address[0]))
        if path == "/which":
            self._respond(200, tag)
        elif path == "/ok":
            self._respond(200, "PONG")
        elif path == "/needle":
            self._respond(200, "hello NEEDLE world")
        elif path == "/echo":
            self._respond(200, self.path)
        elif path == "/slow":
            time.sleep(3)
            self._respond(200, "late")
        elif path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/ok")
            self.send_header("Content-Length", "0")
            self.end_headers()
        else:
            self._respond(404, "not found")

    def log_message(self, fmt, *args):
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port-file", required=True)
    ap.add_argument("--log-file", required=True)
    args = ap.parse_args()

    v4 = V4Server(("127.0.0.1", 0), Handler)
    port = v4.server_address[1]
    try:
        v6 = V6Server(("::1", port), Handler)
    except OSError as exc:
        print("IPv6 bind failed: %s" % exc, file=sys.stderr)
        v4.server_close()
        sys.exit(2)

    lock = threading.Lock()
    for srv, tag in ((v4, "IPV4"), (v6, "IPV6")):
        srv.tag = tag
        srv.log_lock = lock
        srv.log_file = args.log_file

    open(args.log_file, "w", encoding="utf-8").close()
    with open(args.port_file, "w", encoding="utf-8") as f:
        f.write(str(port) + "\n")

    t = threading.Thread(target=v6.serve_forever, daemon=True)
    t.start()
    try:
        v4.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        v6.shutdown()
        v4.server_close()
        v6.server_close()


if __name__ == "__main__":
    main()
