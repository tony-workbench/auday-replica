"""Record what an app sends to its configured AI endpoint (OpenAI / Anthropic / Gemini shapes).

For observing your OWN app's requests to an endpoint YOU configure (Auday is BYOK).
Captured prompts belong to the app's developer: keep them private, do not publish.

  python scripts/capture_proxy.py --host 0.0.0.0 --port 8790 --out <private-dir>
  # optional: forward to a real provider so the app keeps working
  python scripts/capture_proxy.py ... --upstream https://api.openai.com

Without --upstream every request is answered with 503, so the app saves no fake results.
Authorization / API-key headers are never written to disk, and ?key= is masked in the terminal log.
"""

import argparse
import json
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SECRET_HEADERS = {"authorization", "x-api-key", "x-goog-api-key", "api-key", "cookie"}
SECRET_QUERY = re.compile(r"([?&](?:key|api_key)=)[^&\s\"]*")   # Gemini sends ?key=


def make_handler(out, upstream):
    log = out / "requests.jsonl"
    counter = {"n": 0}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            sys.stderr.write("%s %s\n" % (self.address_string(), SECRET_QUERY.sub(r"\1***", fmt % args)))

        def _record(self, body):
            counter["n"] += 1
            try:
                parsed = json.loads(body) if body else None
            except ValueError:
                parsed = {"_raw": body.decode("utf-8", "replace")}
            entry = {"n": counter["n"], "ts": datetime.now().astimezone().isoformat(),
                     "method": self.command, "path": self.path.split("?")[0],
                     "headers": {k: v for k, v in self.headers.items() if k.lower() not in SECRET_HEADERS},
                     "secret_headers_present": [k for k in self.headers if k.lower() in SECRET_HEADERS],
                     "body": parsed}
            with log.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(entry, ensure_ascii=False) + "\n")
            return entry

        def _handle(self):
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else b""
            entry = self._record(body)
            if self.path.rstrip("/").endswith("/models") and self.command == "GET" and not upstream:
                return self._send(200, {"object": "list", "data": [{"id": "capture", "object": "model"}]})
            if not upstream:
                return self._send(503, {"error": {"message": "capture-only endpoint; request recorded",
                                                   "type": "capture_only", "n": entry["n"]}})
            request = urllib.request.Request(upstream.rstrip("/") + self.path, body or None, method=self.command)
            for key, value in self.headers.items():
                if key.lower() not in ("host", "content-length", "accept-encoding", "connection"):
                    request.add_header(key, value)
            try:
                with urllib.request.urlopen(request, timeout=300) as response:
                    status, data, ctype = response.status, response.read(), response.headers.get("Content-Type")
            except urllib.error.HTTPError as error:
                status, data, ctype = error.code, error.read(), error.headers.get("Content-Type")
            with (out / "responses.jsonl").open("a", encoding="utf-8") as handle:
                handle.write(json.dumps({"n": entry["n"], "status": status,
                                         "body": data.decode("utf-8", "replace")[:200000]}, ensure_ascii=False) + "\n")
            self.send_response(status)
            self.send_header("Content-Type", ctype or "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _send(self, status, value):
            data = json.dumps(value).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        do_GET = do_POST = do_PUT = _handle

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8790)
    parser.add_argument("--out", required=True)
    parser.add_argument("--upstream")
    args = parser.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer((args.host, args.port), make_handler(out, args.upstream))
    print(f"capturing on http://{args.host}:{args.port} -> {out} (upstream: {args.upstream or 'none, answering 503'})", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
