"""Connect to your workflow: the replica answers the official Auday Skill the way an Auday iPhone does.

The Skill finds `_auday-link._tcp` over Bonjour, connects with TLS 1.2 authenticated only by the
16-character communication password (TLS-PSK), sends one length-prefixed JSON request and reads
one reply. The protocol is written up in docs/SKILL_SYNC_PROTOCOL.md.

Python 3.12 has no TLS-PSK server, so a small Swift helper (app/workflow_link) does what the phone's
Network framework does: advertise, terminate TLS-PSK, and pipe each connection to this module over
a private Unix socket. Everything below TLS lives here: framing, read-only snapshots with
leases, chunked large records, the audio catalogue and on-demand audio.

  python -m app.workflow_server --data data      # serve the link without the web app
"""

import argparse
import base64
import hashlib
import json
import os
import secrets
import shutil
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import wave
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from app import auday_export  # noqa: E402

PROTOCOL = "auday-workflow-link-v2"
SERVICE_TYPE = "_auday-link._tcp"
MAXIMUM = 2 * 1024 * 1024          # one frame, either direction
PAGE = 100                         # rows per list/assets page; the Skill rejects more
CHUNK = 262144                     # the Skill's record and audio chunk length
INLINE_LIMIT = 256 * 1024          # larger records are sent as a recordTransfer and fetched in chunks
PAGE_BUDGET = 1536 * 1024          # keeps a page well inside one frame
RETAINED = 4                       # snapshots kept for transfers in progress
LEASE_SECONDS = 600                # an unused lease expires after this
ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
ACCESS = {"text": "text-only-read-only", "text-and-audio": "text-and-audio-read-only"}
CAPABILITIES = {"chunkedRecords": True, "onDemandAudio": True, "onDemandSnapshot": True,
                "retainedSnapshots": True, "snapshotLeases": True}
SNAPSHOT_OPS = ("list", "assets", "read", "recordChunk", "prepareAudio", "audio")
UUID_NAMESPACE = uuid.UUID("5b0a7a43-3f7e-4a8e-9a55-1c0c5a7d2e10")
HELPER = ROOT / "app" / "workflow_link"


class ProtocolError(Exception):
    """An error code the Skill understands, e.g. snapshot_changed or audio_access_denied."""


# ---------- communication password ----------
def normalize_password(password):
    """The Skill accepts only a generated-looking secret: 16 symbols of its Base32 alphabet,
    case, spaces and hyphens ignored, at least 4 distinct symbols."""
    text = "".join(c for c in str(password).upper() if not c.isspace() and c != "-")
    if len(text) != 16 or any(c not in ALPHABET for c in text) or len(set(text)) < 4:
        raise ValueError("use_generated_16_character_communication_password")
    return text


def generate_password():
    while True:
        text = "".join(secrets.choice(ALPHABET) for _ in range(16))
        if len(set(text)) >= 4:
            return text


def format_password(password):
    text = normalize_password(password)
    return "-".join(text[i:i + 4] for i in range(0, 16, 4))


# ---------- framing: 4-byte big-endian length, then UTF-8 JSON ----------
def encode_frame(value):
    data = json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode()
    if not 0 < len(data) <= MAXIMUM:
        raise ProtocolError("response_too_large")
    return struct.pack(">I", len(data)) + data


def _exact(stream, size):
    data = bytearray()
    while len(data) < size:
        chunk = stream.recv(min(65536, size - len(data)))
        if not chunk:
            if data:
                raise ProtocolError("truncated_frame")
            return None
        data.extend(chunk)
    return bytes(data)


def read_frame(stream):
    """One request object, or None at a clean end of stream."""
    header = _exact(stream, 4)
    if header is None:
        return None
    size = struct.unpack(">I", header)[0]
    if not 0 < size <= MAXIMUM:
        raise ProtocolError("invalid_frame_size")
    body = _exact(stream, size)
    if body is None:
        raise ProtocolError("truncated_frame")
    try:
        value = json.loads(body)
    except (ValueError, UnicodeError, RecursionError):
        raise ProtocolError("invalid_request") from None
    if not isinstance(value, dict):
        raise ProtocolError("invalid_request")
    return value


# ---------- what a snapshot contains ----------
def _canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def _utc_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _aware(start):
    value = datetime.fromisoformat(start.replace("Z", "+00:00"))
    return value if value.tzinfo else value.astimezone()


def _uuid(*parts):
    return str(uuid.uuid5(UUID_NAMESPACE, "/".join(str(p) for p in parts))).upper()


class AppLibrary:
    """Reads the replica: records through the Auday-shaped export, audio from its asset table."""

    def __init__(self, app):
        self.app = app

    def records(self):
        return auday_export.library(self.app)

    def audio(self):
        """[(catalogue row, local file)] for every asset whose audio is still kept."""
        out = []
        for (body,) in self.app.db.execute("SELECT body FROM assets"):
            asset = json.loads(body)
            path = self.app.data / "audio" / asset["path"] if asset.get("path") else None
            if not path or not path.is_file() or not asset.get("start"):
                continue
            info = path.stat()
            session = asset.get("session") or asset["id"]
            start = _aware(asset["start"])
            row = {"id": auday_export.audio_asset_id(asset["id"]),
                   "contentRevision": hashlib.sha256(f"{asset['id']}/{info.st_size}/{info.st_mtime_ns}".encode()).hexdigest(),
                   "duration": round(float(asset.get("duration") or 0), 3),
                   "fragmentID": _uuid("fragment", asset.get("fragment") or asset["id"]),
                   "regionID": _uuid("region", session, start.strftime("%Y-%m-%dT%H")),
                   "sessionID": _uuid("session", session),
                   "start": start.isoformat(timespec="milliseconds"),
                   "timeZone": self.app.time_zone(),
                   "preparation": "on-demand"}
            out.append((row, path))
        return out

    def device_id(self):
        db = self.app.db
        row = db.execute("SELECT value FROM metadata WHERE key='workflow_device_id'").fetchone()
        if row:
            return json.loads(row[0])
        value = str(uuid.uuid4()).upper()
        with db:
            db.execute("INSERT OR IGNORE INTO metadata VALUES('workflow_device_id', ?)", (json.dumps(value),))
        return json.loads(db.execute("SELECT value FROM metadata WHERE key='workflow_device_id'").fetchone()[0])


class Snapshot:
    def __init__(self, device, access, records, audio):
        self.access = access
        self.captured_at = _utc_now()
        audio = audio if access == ACCESS["text-and-audio"] else []
        self.assets = sorted((row for row, _ in audio), key=lambda r: r["id"])
        self.files = {row["id"]: path for row, path in audio}
        kept = set(self.files)
        self.records = []
        for record in sorted(records, key=lambda r: (r.get("start") or "", r["id"])):
            record = dict(record)
            record.pop("audioAssetID", None)
            ids = [i for i in record.pop("audioAssetIDs", []) if i in kept]
            if ids:
                record["audioAssetIDs"] = ids
            self.records.append(record)
        self.by_id = {r["id"]: r for r in self.records}
        self.asset_by_id = {r["id"]: r for r in self.assets}
        self.blobs = {}
        self.id = hashlib.sha256(_canonical({"protocol": PROTOCOL, "device": device, "access": access,
                                             "records": self.records, "assets": self.assets})).hexdigest()

    def blob(self, record_id):
        if record_id not in self.blobs:
            self.blobs[record_id] = _canonical(self.by_id[record_id])
        return self.blobs[record_id]


# ---------- the request handler ----------
class WorkflowService:
    """Answers every op the Skill sends. Thread-safe; one instance per running link."""

    def __init__(self, library, access="text", cache_dir=None, clock=time.monotonic, wait=5.0):
        if access not in ACCESS:
            raise ValueError("access must be 'text' or 'text-and-audio'")
        self.library = library
        self.access = ACCESS[access]
        self.device = library.device_id()
        self.cache = Path(cache_dir or tempfile.mkdtemp(prefix="auday-link-audio-"))
        self.clock = clock
        self.wait = wait
        self.lock = threading.RLock()
        self.retained = []                 # Snapshot, oldest first; the last one is the latest
        self.leases = {}                   # token -> {"snapshot": id | None, "used": t}
        self.state = "idle"                # idle | preparing | ready | failed
        self.job = None
        self.failure = None
        self.prepared = {}                 # contentRevision -> {"path", "mime", "sha256", "size"}

    def set_access(self, access):
        with self.lock:
            self.access = ACCESS[access]

    # ----- entry point -----
    def handle(self, request):
        try:
            op = request.get("op")
            method = getattr(self, "op_" + op, None) if isinstance(op, str) else None
            if method is None:
                raise ProtocolError("unsupported_operation")
            reply = method(request)
            return {"ok": True, "sourceDeviceID": self.device, **reply}
        except ProtocolError as error:
            return {"ok": False, "error": str(error), "sourceDeviceID": self.device}
        except Exception as error:     # never a traceback, a path or record text on the wire
            sys.stderr.write(f"workflow link: {op!r} failed: {type(error).__name__}\n")
            return {"ok": False, "error": "request_failed", "sourceDeviceID": self.device}

    # ----- snapshots and leases -----
    def _expire(self):
        now = self.clock()
        for token in [t for t, lease in self.leases.items() if now - lease["used"] > LEASE_SECONDS]:
            del self.leases[token]

    def _snapshot(self, snapshot_id):
        return next((s for s in self.retained if s.id == snapshot_id), None)

    def _retain(self, snapshot):
        existing = self._snapshot(snapshot.id)
        if existing:                      # unchanged content keeps its identity and cached blobs
            self.retained.remove(existing)
            self.retained.append(existing)
            return existing
        pinned = {lease["snapshot"] for lease in self.leases.values()}
        while len(self.retained) >= RETAINED:
            evictable = [s for s in self.retained if s.id not in pinned]
            if not evictable:
                raise ProtocolError("snapshot_busy")
            self.retained.remove(evictable[0])
        self.retained.append(snapshot)
        return snapshot

    def _build(self):
        try:
            snapshot = Snapshot(self.device, self.access, self.library.records(),
                                self.library.audio() if self.access == ACCESS["text-and-audio"] else [])
            with self.lock:
                snapshot = self._retain(snapshot)
                for lease in self.leases.values():
                    if lease.get("pending"):
                        lease.update(snapshot=snapshot.id, pending=False)
                self.state, self.failure = "ready", None
        except Exception as error:
            with self.lock:
                self.state = "failed"
                self.failure = error.args[0] if isinstance(error, ProtocolError) else "preparation_failed"
                for token in [t for t, lease in self.leases.items() if lease.get("pending")]:
                    del self.leases[token]
                if not isinstance(error, ProtocolError):
                    sys.stderr.write(f"workflow link: snapshot preparation failed: {type(error).__name__}\n")

    def _lease(self, token):
        self._expire()
        lease = self.leases.get(token) if isinstance(token, str) else None
        if lease is None:
            raise ProtocolError("snapshot_changed")
        lease["used"] = self.clock()
        return lease

    def _status(self, lease_token=None):
        with self.lock:
            self._expire()
            snapshot, state = (self.retained[-1] if self.retained else None), self.state
            lease = self.leases.get(lease_token) if lease_token else None
            if lease is not None:
                lease["used"] = self.clock()
                if lease.get("pending"):
                    snapshot, state = None, "preparing"
                else:
                    snapshot, state = self._snapshot(lease["snapshot"]), "ready"
            elif state == "preparing" and snapshot is not None:
                state = "ready"           # the previous snapshot is still complete and readable
            reply = {"schemaVersion": 1, "protocol": PROTOCOL, "access": self.access,
                     "capabilities": dict(CAPABILITIES), "snapshotState": state,
                     "snapshot": None, "recordCount": None, "assetCount": None, "snapshotCurrent": False}
            if state == "failed" and self.failure:
                reply["preparationError"] = self.failure
            if snapshot is not None and state == "ready":
                reply.update(snapshot=snapshot.id, recordCount=len(snapshot.records),
                             assetCount=len(snapshot.assets), snapshotCapturedAt=snapshot.captured_at,
                             access=snapshot.access)
        if snapshot is not None and state == "ready":
            reply["snapshotCurrent"] = self._current_id() == snapshot.id
        return reply

    def _current_id(self):
        try:
            return Snapshot(self.device, self.access, self.library.records(),
                            self.library.audio() if self.access == ACCESS["text-and-audio"] else []).id
        except Exception:
            return None

    def _checked(self, request):
        """The retained snapshot a read names, with its lease (if any) still valid."""
        with self.lock:
            snapshot = self._snapshot(request.get("snapshot"))
            if snapshot is None:
                raise ProtocolError("snapshot_not_ready" if not self.retained else "snapshot_changed")
            if "lease" in request:
                if self._lease(request["lease"]).get("snapshot") != snapshot.id:
                    raise ProtocolError("snapshot_changed")
            return snapshot

    # ----- ops -----
    def op_status(self, request):
        return self._status(request.get("lease"))

    def op_prepareSnapshot(self, request):
        token = None
        with self.lock:
            if self.job is None or not self.job.is_alive():
                self.state = "preparing"
                self.job = threading.Thread(target=self._build, name="workflow-snapshot", daemon=True)
                self.job.start()
            job = self.job
            if request.get("useSnapshotLease") is True:
                token = str(uuid.uuid4())
                self.leases[token] = {"snapshot": None, "pending": True, "used": self.clock()}
        job.join(self.wait)
        if token is not None:
            with self.lock:
                if token not in self.leases:          # preparation failed and dropped it
                    return self._status()
            return {**self._status(token), "lease": token}
        return self._status()

    def op_acquireSnapshot(self, request):
        with self.lock:
            snapshot = self._snapshot(request.get("snapshot"))
            if snapshot is None:
                raise ProtocolError("snapshot_not_ready" if not self.retained else "snapshot_changed")
            token = str(uuid.uuid4())
            self.leases[token] = {"snapshot": snapshot.id, "used": self.clock()}
            return {"snapshot": snapshot.id, "lease": token}

    def op_releaseSnapshot(self, request):
        with self.lock:
            self.leases.pop(request.get("lease"), None)
        return {}

    def op_list(self, request):
        snapshot = self._checked(request)
        offset = request.get("offset", 0)
        if type(offset) is not int or not 0 <= offset <= len(snapshot.records):
            raise ProtocolError("invalid_offset")
        chunks = request.get("allowRecordChunks") is True
        rows, budget = [], PAGE_BUDGET
        for record in snapshot.records[offset:offset + PAGE]:
            blob = snapshot.blob(record["id"])
            if len(blob) > INLINE_LIMIT:
                if not chunks:
                    raise ProtocolError("record_too_large_enable_chunked_records")
                row = {"id": record["id"], "kind": record["kind"], "start": record.get("start"),
                       "recordTransfer": {"encoding": "json-utf8", "size": len(blob),
                                          "sha256": hashlib.sha256(blob).hexdigest()}}
                cost = 512
            else:
                row, cost = record, len(blob) + 2
            if rows and cost > budget:
                break
            rows.append(row)
            budget -= cost
        end = offset + len(rows)
        return {"snapshot": snapshot.id, "records": rows, "offset": offset,
                "nextOffset": end if end < len(snapshot.records) else None}

    def op_recordChunk(self, request):
        snapshot = self._checked(request)
        if request.get("id") not in snapshot.by_id:
            raise ProtocolError("record_not_found")
        blob = snapshot.blob(request["id"])
        offset, length = request.get("offset"), request.get("length")
        if (type(offset) is not int or type(length) is not int or not 0 <= offset < len(blob)
                or not 0 < length <= CHUNK):
            raise ProtocolError("invalid_range")
        data = blob[offset:offset + length]
        return {"snapshot": snapshot.id, "id": request["id"], "offset": offset, "size": len(blob),
                "sha256": hashlib.sha256(blob).hexdigest(), "data": base64.b64encode(data).decode(),
                "chunkSHA256": hashlib.sha256(data).hexdigest()}

    def op_read(self, request):
        snapshot = self._checked(request)
        if request.get("id") not in snapshot.by_id:
            raise ProtocolError("record_not_found")
        return {"snapshot": snapshot.id, "record": snapshot.by_id[request["id"]]}

    def op_assets(self, request):
        snapshot = self._checked(request)
        offset = request.get("offset", 0)
        if type(offset) is not int or not 0 <= offset <= len(snapshot.assets):
            raise ProtocolError("invalid_offset")
        rows = snapshot.assets[offset:offset + PAGE]
        end = offset + len(rows)
        return {"snapshot": snapshot.id, "assets": rows, "offset": offset,
                "nextOffset": end if end < len(snapshot.assets) else None}

    def _audio_asset(self, request):
        snapshot = self._checked(request)
        if snapshot.access != ACCESS["text-and-audio"] or self.access != ACCESS["text-and-audio"]:
            raise ProtocolError("audio_access_denied")
        asset = snapshot.asset_by_id.get(request.get("id"))
        if asset is None:
            raise ProtocolError("asset_not_found")
        return snapshot, asset

    def op_prepareAudio(self, request):
        snapshot, asset = self._audio_asset(request)
        prepared = self.prepared.get(asset["contentRevision"])
        if prepared is None or not Path(prepared["path"]).is_file():
            prepared = self._transcode(snapshot.files[asset["id"]], asset["contentRevision"])
            with self.lock:
                self.prepared[asset["contentRevision"]] = prepared
        duration = asset["duration"] if asset["duration"] > 0 else _wav_seconds(snapshot.files[asset["id"]])
        ready = {**asset, "mime": prepared["mime"], "sha256": prepared["sha256"], "size": prepared["size"],
                 "timeline": [{"fileStart": 0, "fileEnd": max(duration, 0.001), "recordedStart": asset["start"]}]}
        return {"snapshot": snapshot.id, "asset": ready}

    def _transcode(self, source, revision):
        """Like the phone: AAC in a CAF container. Without afconvert, the replica's WAV as it is."""
        self.cache.mkdir(parents=True, exist_ok=True)
        target, mime = self.cache / f"{revision}.caf", "audio/x-caf"
        if not target.is_file():
            if shutil.which("afconvert"):
                partial = self.cache / f"{revision}.partial.caf"
                subprocess.run(["afconvert", "-f", "caff", "-d", "aac", "-b", "32000", "-c", "1",
                                str(source), str(partial)], check=True, capture_output=True, timeout=120)
                partial.replace(target)
            else:
                target, mime = self.cache / f"{revision}.wav", "audio/wav"
                shutil.copyfile(source, target)
        data = target.read_bytes()
        return {"path": str(target), "mime": mime, "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}

    def op_audio(self, request):
        snapshot, asset = self._audio_asset(request)
        prepared = self.prepared.get(asset["contentRevision"])
        if prepared is None or not Path(prepared["path"]).is_file():
            raise ProtocolError("audio_not_prepared")
        offset, length = request.get("offset"), request.get("length")
        if (type(offset) is not int or type(length) is not int or not 0 <= offset < prepared["size"]
                or not 0 < length <= CHUNK):
            raise ProtocolError("invalid_range")
        with open(prepared["path"], "rb") as handle:
            handle.seek(offset)
            data = handle.read(length)
        return {"snapshot": snapshot.id, "id": asset["id"], "offset": offset, "size": prepared["size"],
                "sha256": prepared["sha256"], "mime": prepared["mime"],
                "data": base64.b64encode(data).decode(), "chunkSHA256": hashlib.sha256(data).hexdigest()}


def _wav_seconds(path):
    try:
        with wave.open(str(path), "rb") as handle:
            return handle.getnframes() / handle.getframerate()
    except (wave.Error, OSError, ZeroDivisionError):
        return 0.0


# ---------- serving ----------
def serve_connection(service, connection):
    """Requests in, replies out, until the peer closes. A broken frame ends the connection."""
    while True:
        try:
            request = read_frame(connection)
        except ProtocolError as error:
            connection.sendall(encode_frame({"ok": False, "error": str(error), "sourceDeviceID": service.device}))
            return
        if request is None:
            return
        reply = service.handle(request)
        try:
            frame = encode_frame(reply)
        except ProtocolError as error:
            frame = encode_frame({"ok": False, "error": str(error), "sourceDeviceID": service.device})
        connection.sendall(frame)


class _UnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def build_helper(package=HELPER, product="auday-replica-link", extra_sources=()):
    """Compile a Swift helper once (Xcode Command Line Tools); rebuilt when its source changes."""
    if sys.platform != "darwin":
        raise RuntimeError("The Swift helpers need macOS.")
    if not shutil.which("swift"):
        raise RuntimeError("swift_missing: install Xcode Command Line Tools")
    args = ["swift", "build", "-c", "release", "--package-path", str(package)]
    binary = Path(subprocess.run(args + ["--show-bin-path"], check=True, capture_output=True, text=True)
                  .stdout.strip()) / product
    sources = [package / "Package.swift", *package.glob("Sources/**/*.swift"), *extra_sources]
    if not binary.exists() or max(p.stat().st_mtime for p in sources) > binary.stat().st_mtime:
        subprocess.run(args, check=True, capture_output=True)
    return binary


def default_name():
    host = socket.gethostname().removesuffix(".local")
    return f"Auday Replica ({host})"


class WorkflowLink:
    """One running link: the Unix-socket request server plus the advertising Swift helper."""

    def __init__(self, library, password, access="text", name=None, port=0, cache_dir=None):
        self.password = normalize_password(password)
        self.name = (name or default_name()).encode()[:63].decode(errors="ignore")
        self.port = port
        self.service = WorkflowService(library, access, cache_dir=cache_dir)
        self.folder = Path(tempfile.mkdtemp(prefix="auday-link-"))
        os.chmod(self.folder, 0o700)
        self.socket_path = self.folder / "link.sock"
        self.server = None
        self.helper = None
        self.events = []

    def start(self, timeout=180):
        service = self.service

        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                self.request.settimeout(130)
                try:
                    serve_connection(service, self.request)
                except OSError:
                    pass

        self.server = _UnixServer(str(self.socket_path), Handler)
        os.chmod(self.socket_path, 0o600)
        threading.Thread(target=self.server.serve_forever, name="workflow-link", daemon=True).start()
        binary = build_helper()
        self.helper = subprocess.Popen([str(binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.DEVNULL, text=True)
        self.helper.stdin.write(json.dumps({"password": self.password, "name": self.name,
                                            "socket": str(self.socket_path), "port": self.port}) + "\n")
        self.helper.stdin.flush()
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            line = self.helper.stdout.readline()
            if not line:
                self.stop()
                raise RuntimeError("link_helper_exited")
            event = json.loads(line)
            self.events.append(event)
            if event.get("event") == "failed":
                self.stop()
                raise RuntimeError(event.get("error", "link_failed"))
            if event.get("event") == "ready":
                self.port = event["port"]
                threading.Thread(target=self._drain, daemon=True).start()
                return self
        self.stop()
        raise RuntimeError("link_start_timed_out")

    def _drain(self):
        for line in self.helper.stdout:
            try:
                self.events.append(json.loads(line))
            except ValueError:
                pass

    def advertised(self):
        return any(e.get("event") == "advertised" for e in self.events)

    def stop(self):
        if self.helper is not None:
            try:
                self.helper.stdin.close()
                self.helper.wait(timeout=5)
            except (OSError, subprocess.TimeoutExpired):
                self.helper.kill()
            self.helper = None
        if self.server is not None:
            self.server.shutdown()
            self.server.server_close()
            self.server = None
        shutil.rmtree(self.folder, ignore_errors=True)


class WorkflowController:
    """Follows the replica's settings: Connect to your workflow on or off, access scope, password, name."""

    def __init__(self, app):
        self.app = app
        self.lock = threading.Lock()
        self.link = None
        self.config = None
        self.error = None
        self.starting = False

    def settings(self):
        s = self.app.settings()
        return {"enabled": bool(s.get("workflow_enabled")), "access": s.get("workflow_access") or "text",
                "password": s.get("workflow_password") or "", "name": s.get("workflow_name") or ""}

    def apply(self):
        """Start, restart or stop the link to match the settings. Starting runs in the background:
        the first start compiles the Swift helper."""
        threading.Thread(target=self._apply, name="workflow-apply", daemon=True).start()

    def _apply(self):
        with self.lock:
            wanted = self.settings()
            if wanted == self.config and (self.link or not wanted["enabled"]):
                return
            if self.link and wanted["enabled"] and {**wanted, "access": None} == {**self.config, "access": None}:
                self.link.service.set_access(wanted["access"])     # a scope change keeps the listener
                self.config = wanted
                return
            if self.link:
                self.link.stop()
                self.link = None
            self.config, self.error = wanted, None
            if not wanted["enabled"]:
                return
            try:
                self.starting = True
                self.link = WorkflowLink(AppLibrary(self.app), wanted["password"], wanted["access"],
                                         wanted["name"] or None, cache_dir=self.app.data / "cache" / "workflow-audio").start()
            except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as error:
                self.error = str(error).split(":")[0] if isinstance(error, ValueError) else str(error)
                self.link = None
            finally:
                self.starting = False

    def status(self):
        s = self.settings()
        link = self.link
        return {"enabled": s["enabled"], "access": s["access"], "name": (link.name if link else s["name"] or default_name()),
                "password": format_password(s["password"]) if s["password"] else "",
                "state": "starting" if self.starting else "on" if link else "error" if self.error else "off",
                "advertised": bool(link and link.advertised()), "port": link.port if link else None,
                "error": self.error}

    def stop(self):
        with self.lock:
            if self.link:
                self.link.stop()
                self.link = None


def update(app, controller, body):
    """POST /api/workflow: {enabled, access, name, password | regenerate}. Returns the new status."""
    changes = {}
    if "enabled" in body:
        changes["workflow_enabled"] = bool(body["enabled"])
    if "access" in body:
        if body["access"] not in ACCESS:
            raise ValueError("access must be 'text' or 'text-and-audio'")
        changes["workflow_access"] = body["access"]
    if "name" in body:
        changes["workflow_name"] = str(body["name"]).strip()[:40]
    if body.get("regenerate"):
        changes["workflow_password"] = generate_password()
    elif body.get("password"):
        changes["workflow_password"] = normalize_password(body["password"])
    current = app.settings()
    if (changes.get("workflow_enabled") or current.get("workflow_enabled")) and not (
            changes.get("workflow_password") or current.get("workflow_password")):
        changes["workflow_password"] = generate_password()     # like the phone: a password exists once access is on
    app.update_settings(changes)
    controller.apply()
    return controller.status()


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--data", default=str(ROOT / "data"))
    parser.add_argument("--port", type=int, default=0, help="fixed TCP port; 0 picks a free one")
    args = parser.parse_args()
    from app.core import App
    app = App(args.data)
    s = app.settings()
    if not s.get("workflow_password"):
        raise SystemExit("Set a communication password first (Settings › Connect to your workflow).")
    link = WorkflowLink(AppLibrary(app), s["workflow_password"], s.get("workflow_access") or "text",
                        s.get("workflow_name") or None, port=args.port,
                        cache_dir=Path(args.data) / "cache" / "workflow-audio").start()
    print(json.dumps({"service": link.name, "type": SERVICE_TYPE, "port": link.port,
                      "access": link.service.access}), flush=True)
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        pass
    finally:
        link.stop()


if __name__ == "__main__":
    main()
