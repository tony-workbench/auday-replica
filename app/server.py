"""HTTP server (stdlib only).

  python -m app.server --data data --port 8765
"""

import argparse
import hmac
import ipaddress
import json
import os
import mimetypes
import re
import sys
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from app import auday_export, pair_iphone, transcribe, workflow_server  # noqa: E402
from app.core import App, iso, now_local  # noqa: E402

STATIC = Path(__file__).resolve().parent / "static"


def make_handler(app, token=None, workflow=None):
    """`token`: when set, API calls from other machines (the iPhone companion on the LAN) must send
    it as `Authorization: Bearer <token>`. Calls from this Mac never need it."""

    class Handler(BaseHTTPRequestHandler):
        server_version = "AudayReplica/0.1"

        def log_message(self, fmt, *args):
            if "/api/status" not in (args[0] if args else ""):
                sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

        # ---------- helpers ----------
        def send_json(self, value, status=200):
            body = json.dumps(value, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def body(self):
            length = int(self.headers.get("Content-Length") or 0)
            return self.rfile.read(length) if length else b""

        def json_body(self):
            raw = self.body()
            return json.loads(raw) if raw else {}

        def send_file(self, path, mime=None, cache=None):
            size = path.stat().st_size
            mime = mime or mimetypes.guess_type(path.name)[0] or "application/octet-stream"
            start, end = 0, size - 1
            ranged = re.match(r"bytes=(\d*)-(\d*)", self.headers.get("Range") or "")
            if ranged and (ranged.group(1) or ranged.group(2)):
                if ranged.group(1):
                    start = int(ranged.group(1))
                    end = int(ranged.group(2)) if ranged.group(2) else end
                else:
                    start = size - int(ranged.group(2))
                self.send_response(206)
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            else:
                self.send_response(200)
            self.send_header("Content-Type", mime)
            self.send_header("Accept-Ranges", "bytes")
            if cache:
                self.send_header("Cache-Control", cache)
            self.send_header("Content-Length", str(end - start + 1))
            self.end_headers()
            with path.open("rb") as handle:
                handle.seek(start)
                self.wfile.write(handle.read(end - start + 1))

        # ---------- routing ----------
        def do_GET(self):
            self.route("GET")

        def do_POST(self):
            self.route("POST")

        def do_PUT(self):
            self.route("PUT")

        def allowed(self):
            if ipaddress.ip_address(self.client_address[0].removeprefix("::ffff:")).is_loopback:
                return True
            sent = (self.headers.get("Authorization") or "").removeprefix("Bearer ").strip()
            return bool(token) and hmac.compare_digest(sent.encode(), token.encode())

        def same_site(self):
            """Stop other web pages open in this Mac's browser from driving the API: a cross-site
            request carries a foreign Origin (CSRF), a DNS-rebinding page a foreign Host."""
            host = self.headers.get("Host") or ""
            name = host.split("]")[0] + "]" if host.startswith("[") else host.rsplit(":", 1)[0]
            name = name.lower()
            if ipaddress.ip_address(self.client_address[0].removeprefix("::ffff:")).is_loopback and not (
                    name in ("127.0.0.1", "localhost", "[::1]") or name.endswith(".localhost")):
                return False
            origin = self.headers.get("Origin")
            if origin is not None and origin != f"http://{host}":
                return False
            return self.headers.get("Sec-Fetch-Site", "same-origin") in ("same-origin", "none")

        def route(self, method):
            url = urlparse(self.path)
            query = {k: v[0] for k, v in parse_qs(url.query).items()}
            try:
                if not url.path.startswith("/api/"):
                    return self.static(url.path)
                if not self.same_site():
                    return self.send_json({"error": "Cross-site request refused."}, 403)
                if not self.allowed():
                    return self.send_json({"error": "Missing or wrong access token."}, 401)
                time.tzset()            # follow the Mac's time zone if it changed (travel)
                result = self.api(method, url.path[5:], query)
                if result is not None:
                    self.send_json(result)
            except (KeyError, ValueError) as error:
                self.send_json({"error": str(error)}, 400)
            except transcribe.Undecodable as error:
                self.send_json({"error": f"unreadable audio: {error}"}, 422)
            except Exception as error:
                traceback.print_exc()
                self.send_json({"error": f"{type(error).__name__}: {error}"}, 500)

        def static(self, path):
            target = (STATIC / (path.lstrip("/") or "index.html")).resolve()
            if not str(target).startswith(str(STATIC)) or not target.is_file():
                target = STATIC / "index.html"
            self.send_file(target, cache="no-cache")    # the page updates with the code

        def api(self, method, path, query):
            parts = path.strip("/").split("/")
            head = parts[0]
            if head == "status":
                return app.status()
            if head == "settings":
                return app.update_settings(self.json_body()) if method == "PUT" else app.public_settings()
            if head == "dates":
                today = now_local().date().isoformat()
                return {"today": today, "dates": app.dates()}
            if head == "day":
                return app.day(query.get("date") or now_local().date().isoformat())
            if head == "record":
                record = app.store.record(parts[1])
                if record is None:
                    raise KeyError(f"No record {parts[1]}")
                return record
            if head == "archive" and method == "GET":
                return app.archive()
            if head == "transcribe" and method == "POST":   # Auday: Start transcription (about 15 min)
                return app.transcribe_next()
            if head == "batch-export" and method == "GET":
                data = app.batch_export(query["from"], query["to"])
                self.send_response(200)
                self.send_header("Content-Type", "application/zip")
                self.send_header("Content-Disposition", f'attachment; filename="Auday_{query["from"]}_{query["to"]}.zip"')
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return None
            if head == "hour-audio" and method == "GET":
                path = app.hour_audio(query["date"], int(query["hour"]))
                if path is None:
                    raise KeyError("No audio for this hour")
                self.send_file(path, "audio/wav")
                return None
            if head == "audio" and method == "GET":
                path = app.audio_path(parts[1])
                if path is None or not path.exists():
                    raise KeyError(f"No audio {parts[1]}")
                self.send_file(path, "audio/wav")
                return None
            if head == "audio" and method == "POST":
                start = query.get("start") or iso(now_local())
                suffix = "." + (query.get("ext") or "webm").strip(".")
                asset = app.save_audio(self.body(), start, suffix=suffix, speaker=query.get("speaker"),
                                       language=query.get("language"), session=query.get("session"),
                                       fragment=query.get("fragment"))
                return asset
            if head == "transcripts" and method == "POST":
                data = self.json_body()
                start = data.get("start") or iso(now_local())
                segments = data.get("segments") or [{"speaker": data.get("speaker", "user"),
                                                     "text": data["text"], "start": 0}]
                return app.add_transcript(start, segments, title=data.get("title"))
            if head == "marks" and method == "POST":
                data = self.json_body()
                return app.add_mark(data.get("start") or iso(now_local()), data.get("note", ""))
            if head == "hour" and method == "POST":
                data = self.json_body()
                app.touch_hour(data["date"], int(data["hour"]))
                app.enqueue("hour", date=data["date"], hour=int(data["hour"]))
                return {"queued": True}
            if head == "reflection" and method == "POST":
                app.enqueue("reflection", date=self.json_body()["date"])
                return {"queued": True}
            if head == "chat":
                if method == "POST":
                    data = self.json_body()
                    return app.ask(data["question"], data.get("history", []), data.get("conversation"))
                if len(parts) == 2 and parts[1] == "conversations":
                    return {"conversations": app.conversations()}
                return app.chat_history(conversation=query.get("conversation"))
            if head == "search":
                from app import search
                kinds = query.get("kind")
                return search.search(app.db, app.store.embedder, query.get("q", ""),
                                     mode=query.get("mode", "hybrid"),
                                     kinds=kinds.split(",") if kinds else None, date=query.get("date"),
                                     dates=query["dates"].split(",") if query.get("dates") else None,
                                     date_from=query.get("from"), date_to=query.get("to"),
                                     limit=int(query.get("limit", 20)))
            if head == "memories":
                if len(parts) == 1:
                    wanted = query.get("status")
                    return {"memories": app.memories(wanted.split(",") if wanted else None),
                            "reviews": app.store.reviews()}
                memory_id = parts[1]
                if len(parts) == 3 and parts[2] == "history":
                    return {"versions": app.store.versions(memory_id),
                            "events": [e for e in app.store.events()
                                       if memory_id in (e["memory_id"], e["target_id"])]}
                if method == "POST" and len(parts) == 3:
                    return app.memory_action(memory_id, parts[2], self.json_body().get("content"))
            if head == "export":
                return app.export_library()
            if head == "workflow":               # Connect to your workflow: this Mac only, as it returns the password
                if workflow is None or not ipaddress.ip_address(self.client_address[0].removeprefix("::ffff:")).is_loopback:
                    raise KeyError("Unknown endpoint")
                if method == "POST" and not (self.headers.get("Content-Type") or "").startswith("application/json"):
                    raise ValueError("Content-Type must be application/json")
                return workflow_server.update(app, workflow, self.json_body()) if method == "POST" else workflow.status()
            if head == "auday-library":           # the shape the Auday Skill syncs from the phone
                return {"records": auday_export.library(app)}
            if head == "voiceprint" and method == "POST" and parts[1:2] == ["relabel"]:
                return app.relabel_voices()
            if head == "voiceprint" and method == "POST":
                suffix = "." + (query.get("ext") or "webm").strip(".")
                return app.enroll_voice(self.body(), suffix)
            if head == "places" and method == "POST":    # watch positions named by the iPhone companion
                data = self.json_body()
                return app.add_places(data["places"], data.get("session"))
            if head == "health" and len(parts) == 2 and parts[1] == "samples" and method == "POST":
                return app.sync_health(self.json_body()["samples"])   # HealthKit, from the iPhone companion
            if head == "health" and method == "POST":    # Apple Health export.zip, kept on this machine
                return app.import_health(self.body())
            if head == "models" and method == "GET":
                return app.list_models()
            if head == "check" and method == "POST":     # Auday: Check Connection & Save
                return app.check_connection()
            if head == "daily" and method == "POST":
                app.enqueue("daily")
                return {"queued": True}
            if head == "notes":
                text = app.notes(query["date"], int(query["hour"]))
                data = text.encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/markdown; charset=utf-8")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return None
            raise KeyError(f"Unknown endpoint {method} /api/{path}")

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", default=str(ROOT / "data"))
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--token", default=os.environ.get("AUDAY_TOKEN"),
                        help="required from other machines, e.g. the iPhone companion (--host 0.0.0.0); "
                             "made and kept in <data>/lan-token when not given")
    args = parser.parse_args()
    lan = args.host not in ("127.0.0.1", "localhost", "::1")
    token = args.token or (pair_iphone.load_token(args.data) if lan else None)
    app = App(args.data)
    app.start_workers()
    workflow = workflow_server.WorkflowController(app)
    workflow.apply()
    server = ThreadingHTTPServer((args.host, args.port), make_handler(app, token, workflow))
    print(f"Auday Replica on http://{args.host}:{args.port}  (data: {args.data})", flush=True)
    if lan:
        print("To connect the iPhone, run in another terminal: .venv/bin/python -m app.pair_iphone", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
