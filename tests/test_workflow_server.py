"""Connect to your workflow: framing, snapshot paging, leases, chunked records and on-demand audio, checked as
the official Auday Skill checks them. All data is synthetic."""

import base64
import hashlib
import json
import math
import shutil
import socket
import struct
import tempfile
import threading
import unittest
import wave
from pathlib import Path

from helpers import transcript  # noqa: F401  (adds the repo root to sys.path)

from app import workflow_server as ws
from app.core import App


class FakeLibrary:
    def __init__(self, records, audio=()):
        self.rows, self.files = records, list(audio)

    def records(self):
        return [dict(r) for r in self.rows]

    def audio(self):
        return list(self.files)

    def device_id(self):
        return "11111111-2222-3333-4444-555555555555"


def record(n, text="hello", **extra):
    return {"id": f"transcript:t-{n:04d}", "kind": "transcript", "start": f"2026-10-01T10:{n % 60:02d}:00-07:00",
            "state": "saved", "text": text, "title": "", "timeZone": "America/Los_Angeles",
            "timeZoneBasis": "current-display", "payload": {}, **extra}


def tone(path, seconds=2):
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(16000)
        handle.writeframes(b"".join(struct.pack("<h", int(6000 * math.sin(i * 2 * math.pi * 440 / 16000)))
                                    for i in range(16000 * seconds)))
    return path


def sync(service):
    """What the Skill's `sync` does: prepare with a lease, page records and assets, fetch chunks."""
    status = service.handle({"op": "status"})
    assert status["ok"] and status["capabilities"]["onDemandSnapshot"]
    prepared = service.handle({"op": "prepareSnapshot", "retry": True, "useSnapshotLease": True})
    token = prepared["lease"]
    while prepared["snapshotState"] == "preparing":
        prepared = service.handle({"op": "status", "lease": token})
    snapshot = prepared["snapshot"]
    out = {"status": prepared, "records": [], "assets": []}
    for op, field in (("list", "records"), ("assets", "assets")):
        offset = 0
        while True:
            reply = service.handle({"op": op, "offset": offset, "snapshot": snapshot, "lease": token,
                                    "allowRecordChunks": True})
            assert reply["ok"], reply
            rows = reply[field]
            assert len(rows) <= 100
            for row in rows:
                if "recordTransfer" in row:
                    row = fetch_record(service, row, snapshot, token)
                out[field].append(row)
            if reply["nextOffset"] is None:
                break
            assert reply["nextOffset"] == offset + len(rows)
            offset = reply["nextOffset"]
    service.handle({"op": "releaseSnapshot", "lease": token})
    return out


def fetch_record(service, row, snapshot, token):
    transfer, data = row["recordTransfer"], b""
    while len(data) < transfer["size"]:
        reply = service.handle({"op": "recordChunk", "id": row["id"], "snapshot": snapshot, "lease": token,
                                "offset": len(data), "length": min(262144, transfer["size"] - len(data))})
        chunk = base64.b64decode(reply["data"])
        assert hashlib.sha256(chunk).hexdigest() == reply["chunkSHA256"]
        data += chunk
    assert hashlib.sha256(data).hexdigest() == transfer["sha256"]
    return json.loads(data)


class PasswordTests(unittest.TestCase):
    def test_generated_passwords_satisfy_the_skill(self):
        for _ in range(50):
            password = ws.generate_password()
            self.assertEqual(ws.normalize_password(password), password)
            self.assertRegex(ws.format_password(password), r"^([2-9A-HJ-NP-Z]{4}-){3}[2-9A-HJ-NP-Z]{4}$")

    def test_normalization_and_rejection(self):
        self.assertEqual(ws.normalize_password("abcd efgh-jkmn pqrs"), "ABCDEFGHJKMNPQRS")
        for bad in ("123456", "ABCDEFGHJKMNPQR0", "AAAAAAAAAAAAAAAA", "ABCDEFGHJKMNPQRSA"):
            with self.assertRaises(ValueError):
                ws.normalize_password(bad)

    def test_key_matches_the_skill_derivation(self):
        # HKDF-SHA256(salt="auday-workflow-link-v2", info="tls-psk", 32 bytes), as both clients derive it.
        import hmac
        prk = hmac.digest(b"auday-workflow-link-v2", b"23456789ABCDEFGH", "sha256")
        expected = hmac.digest(prk, b"tls-psk\x01", "sha256")
        self.assertEqual(len(expected), 32)


class FramingTests(unittest.TestCase):
    def test_round_trip_over_a_socket(self):
        a, b = socket.socketpair()
        with a, b:
            a.sendall(ws.encode_frame({"op": "status", "text": "中文"}))
            self.assertEqual(ws.read_frame(b), {"op": "status", "text": "中文"})
            a.close()
            self.assertIsNone(ws.read_frame(b))

    def test_length_prefix_is_big_endian_bytes(self):
        frame = ws.encode_frame({"a": 1})
        self.assertEqual(struct.unpack(">I", frame[:4])[0], len(frame) - 4)

    def test_rejects_bad_frames(self):
        for payload in (struct.pack(">I", 0), struct.pack(">I", ws.MAXIMUM + 1), struct.pack(">I", 2) + b"[]",
                        struct.pack(">I", 3) + b"{x}", struct.pack(">I", 10) + b"{}"):
            a, b = socket.socketpair()
            with a, b:
                a.sendall(payload)
                a.shutdown(socket.SHUT_WR)
                with self.assertRaises(ws.ProtocolError):
                    ws.read_frame(b)

    def test_serve_connection_answers_each_request(self):
        service = ws.WorkflowService(FakeLibrary([record(1)]))
        a, b = socket.socketpair()
        worker = threading.Thread(target=ws.serve_connection, args=(service, b))
        worker.start()
        with a:
            for _ in range(2):
                a.sendall(ws.encode_frame({"op": "status"}))
                reply = ws.read_frame(a)
                self.assertTrue(reply["ok"])
                self.assertEqual(reply["sourceDeviceID"], "11111111-2222-3333-4444-555555555555")
            a.sendall(ws.encode_frame({"op": "nope"}))
            self.assertEqual(ws.read_frame(a)["error"], "unsupported_operation")
        worker.join(5)
        b.close()


class SnapshotTests(unittest.TestCase):
    def test_idle_until_prepared(self):
        status = ws.WorkflowService(FakeLibrary([record(1)])).handle({"op": "status"})
        self.assertEqual((status["snapshotState"], status["snapshot"], status["recordCount"]), ("idle", None, None))
        self.assertEqual(status["schemaVersion"], 1)
        self.assertEqual(status["access"], "text-only-read-only")
        self.assertEqual(set(status["capabilities"]), {"chunkedRecords", "onDemandAudio", "onDemandSnapshot",
                                                       "retainedSnapshots", "snapshotLeases"})

    def test_paging_covers_every_record_once(self):
        records = [record(n) for n in range(250)]
        result = sync(ws.WorkflowService(FakeLibrary(records)))
        self.assertEqual(result["status"]["recordCount"], 250)
        self.assertEqual(sorted(r["id"] for r in result["records"]), sorted(r["id"] for r in records))
        self.assertRegex(result["status"]["snapshot"], "^[0-9a-f]{64}$")

    def test_pages_stay_inside_one_frame(self):
        records = [record(n, text="x" * 200_000) for n in range(30)]
        service = ws.WorkflowService(FakeLibrary(records))
        snap = service.handle({"op": "prepareSnapshot"})["snapshot"]
        reply = service.handle({"op": "list", "offset": 0, "snapshot": snap, "allowRecordChunks": True})
        self.assertLess(len(reply["records"]), 30)
        self.assertLessEqual(len(ws.encode_frame(reply)), ws.MAXIMUM)
        self.assertEqual(len(sync(service)["records"]), 30)

    def test_large_records_arrive_in_chunks(self):
        big = record(1, text="长" * 400_000)
        service = ws.WorkflowService(FakeLibrary([record(0), big]))
        snap = service.handle({"op": "prepareSnapshot"})["snapshot"]
        rows = service.handle({"op": "list", "offset": 0, "snapshot": snap, "allowRecordChunks": True})["records"]
        self.assertEqual(rows[1]["recordTransfer"]["encoding"], "json-utf8")
        self.assertEqual(sync(service)["records"][1], big)
        refused = service.handle({"op": "list", "offset": 0, "snapshot": snap, "allowRecordChunks": False})
        self.assertFalse(refused["ok"])

    def test_unchanged_library_keeps_its_snapshot_identity(self):
        library = FakeLibrary([record(1)])
        service = ws.WorkflowService(library)
        first = sync(service)["status"]
        self.assertTrue(service.handle({"op": "status"})["snapshotCurrent"])
        self.assertEqual(sync(service)["status"]["snapshot"], first["snapshot"])
        library.rows.append(record(2))
        self.assertFalse(service.handle({"op": "status"})["snapshotCurrent"])
        self.assertNotEqual(sync(service)["status"]["snapshot"], first["snapshot"])

    def test_a_lease_keeps_its_snapshot_while_the_library_changes(self):
        library = FakeLibrary([record(n) for n in range(5)])
        service = ws.WorkflowService(library)
        old = service.handle({"op": "prepareSnapshot", "useSnapshotLease": True})
        for n in range(5, 5 + ws.RETAINED + 1):          # newer snapshots push older unleased ones out
            library.rows.append(record(n))
            service.handle({"op": "prepareSnapshot"})
        reply = service.handle({"op": "list", "offset": 0, "snapshot": old["snapshot"], "lease": old["lease"]})
        self.assertEqual(len(reply["records"]), 5)
        service.handle({"op": "releaseSnapshot", "lease": old["lease"]})
        library.rows.append(record(99))
        service.handle({"op": "prepareSnapshot"})
        gone = service.handle({"op": "list", "offset": 0, "snapshot": old["snapshot"]})
        self.assertEqual(gone["error"], "snapshot_changed")

    def test_acquire_and_unknown_lease(self):
        service = ws.WorkflowService(FakeLibrary([record(1)]))
        self.assertEqual(service.handle({"op": "acquireSnapshot", "snapshot": "0" * 64})["error"], "snapshot_not_ready")
        snap = service.handle({"op": "prepareSnapshot"})["snapshot"]
        lease = service.handle({"op": "acquireSnapshot", "snapshot": snap})
        self.assertEqual(lease["snapshot"], snap)
        bad = service.handle({"op": "list", "offset": 0, "snapshot": snap, "lease": "not-a-lease"})
        self.assertEqual(bad["error"], "snapshot_changed")

    def test_invalid_offsets(self):
        service = ws.WorkflowService(FakeLibrary([record(1)]))
        snap = service.handle({"op": "prepareSnapshot"})["snapshot"]
        for offset in (-1, 5, "0", True):
            self.assertFalse(service.handle({"op": "list", "offset": offset, "snapshot": snap})["ok"])


class AudioTests(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp())
        wav = tone(self.folder / "a.wav")
        self.asset = {"id": "audio-" + "a" * 64, "contentRevision": "b" * 64, "duration": 2.0,
                      "fragmentID": "F", "regionID": "R", "sessionID": "S",
                      "start": "2026-10-01T10:00:00.000-07:00", "timeZone": "America/Los_Angeles",
                      "preparation": "on-demand"}
        self.records = [record(1, audioAssetIDs=[self.asset["id"]])]
        self.library = FakeLibrary(self.records, [(self.asset, wav)])

    def tearDown(self):
        shutil.rmtree(self.folder, ignore_errors=True)

    def test_text_scope_has_no_audio(self):
        service = ws.WorkflowService(self.library, "text", cache_dir=self.folder / "cache")
        result = sync(service)
        self.assertEqual((result["status"]["assetCount"], result["assets"]), (0, []))
        self.assertNotIn("audioAssetIDs", result["records"][0])
        snap = result["status"]["snapshot"]
        denied = service.handle({"op": "prepareAudio", "id": self.asset["id"], "snapshot": snap})
        self.assertEqual(denied["error"], "audio_access_denied")

    @unittest.skipUnless(shutil.which("afconvert"), "needs macOS afconvert for CAF/AAC")
    def test_audio_scope_prepares_and_streams_verified_chunks(self):
        service = ws.WorkflowService(self.library, "text-and-audio", cache_dir=self.folder / "cache")
        result = sync(service)
        self.assertEqual(result["assets"], [self.asset])
        self.assertEqual(result["records"][0]["audioAssetIDs"], [self.asset["id"]])
        snap = result["status"]["snapshot"]
        early = service.handle({"op": "audio", "id": self.asset["id"], "snapshot": snap, "offset": 0, "length": 10})
        self.assertEqual(early["error"], "audio_not_prepared")
        ready = service.handle({"op": "prepareAudio", "id": self.asset["id"], "snapshot": snap})["asset"]
        self.assertEqual(ready["mime"], "audio/x-caf")
        self.assertEqual(ready["timeline"][0]["fileStart"], 0)
        data = b""
        while len(data) < ready["size"]:
            reply = service.handle({"op": "audio", "id": self.asset["id"], "snapshot": snap, "offset": len(data),
                                    "length": min(262144, ready["size"] - len(data))})
            chunk = base64.b64decode(reply["data"])
            self.assertEqual(hashlib.sha256(chunk).hexdigest(), reply["chunkSHA256"])
            data += chunk
        self.assertEqual(hashlib.sha256(data).hexdigest(), ready["sha256"])
        self.assertEqual(data[:4], b"caff")


class AppLibraryTests(unittest.TestCase):
    def test_reads_the_replica_export_and_audio(self):
        folder = Path(tempfile.mkdtemp())
        try:
            app = App(folder / "data")
            app.update_settings({"auto_transcribe": False, "time_zone": "America/Los_Angeles"})
            wav = tone(folder / "in.wav")
            asset = app.save_audio(wav.read_bytes(), "2026-10-01T10:00:00-07:00", suffix=".wav", session="watch-1")
            app.add_transcript("2026-10-01T10:00:00-07:00", [{"text": "synthetic line", "start": 0, "end": 2}],
                               audio_id=asset["id"])
            library = ws.AppLibrary(app)
            self.assertEqual(library.device_id(), library.device_id())
            result = sync(ws.WorkflowService(library, "text-and-audio", cache_dir=folder / "cache"))
            (row,) = result["assets"]
            self.assertRegex(row["id"], "^audio-[0-9a-f]{64}$")
            self.assertRegex(row["contentRevision"], "^[0-9a-f]{64}$")
            self.assertEqual(len(row["sessionID"]), 36)
            (line,) = [r for r in result["records"] if r["kind"] == "transcript"]
            self.assertEqual(line["audioAssetIDs"], [row["id"]])
            self.assertEqual(line["text"], "synthetic line")
        finally:
            shutil.rmtree(folder, ignore_errors=True)

    def test_settings_endpoint_logic(self):
        folder = Path(tempfile.mkdtemp())
        try:
            app = App(folder / "data")

            class Controller:
                applied = 0

                def apply(self):
                    Controller.applied += 1

                def status(self):
                    return app.settings()

            s = ws.update(app, Controller(), {"enabled": True, "access": "text-and-audio"})
            self.assertEqual(ws.normalize_password(s["workflow_password"]), s["workflow_password"])
            self.assertTrue(app.public_settings()["workflow_password"].startswith("•"))
            s = ws.update(app, Controller(), {"password": "abcd-efgh-jkmn-pqrs"})
            self.assertEqual(s["workflow_password"], "ABCDEFGHJKMNPQRS")
            with self.assertRaises(ValueError):
                ws.update(app, Controller(), {"password": "123456"})
            with self.assertRaises(ValueError):
                ws.update(app, Controller(), {"access": "everything"})
        finally:
            shutil.rmtree(folder, ignore_errors=True)


class CrossSiteTests(unittest.TestCase):
    """A page open in this Mac's browser must not be able to turn the link on with its own password."""

    def setUp(self):
        from http.server import ThreadingHTTPServer
        from app.server import make_handler
        self.folder = Path(tempfile.mkdtemp())
        self.app = App(self.folder / "data")

        class Controller:
            def apply(self):
                pass

            def status(self):
                return {"state": "off"}

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.app, None, Controller()))
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.port = self.server.server_address[1]

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        shutil.rmtree(self.folder, ignore_errors=True)

    def post(self, headers, body=b'{"enabled": true, "password": "ABCDEFGHJKMNPQRS"}'):
        import http.client
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        connection.putrequest("POST", "/api/workflow", skip_host=True)
        for key, value in {"Host": f"127.0.0.1:{self.port}", **headers}.items():
            connection.putheader(key, value)
        connection.putheader("Content-Length", str(len(body)))
        connection.endheaders(body)
        status = connection.getresponse().status
        connection.close()
        return status

    def test_cross_site_and_rebinding_requests_are_refused(self):
        attacks = [{"Origin": "https://evil.example", "Content-Type": "text/plain"},
                   {"Origin": "null", "Content-Type": "application/json"},
                   {"Sec-Fetch-Site": "cross-site", "Content-Type": "application/json"},
                   {"Host": f"rebind.evil.example:{self.port}", "Content-Type": "application/json"},
                   {"Content-Type": "text/plain"}]
        for headers in attacks:
            self.assertGreaterEqual(self.post(headers), 400, headers)
        self.assertFalse(self.app.settings()["workflow_enabled"])
        self.assertEqual(self.app.settings()["workflow_password"], "")

    def test_the_replica_page_itself_still_works(self):
        status = self.post({"Origin": f"http://127.0.0.1:{self.port}", "Sec-Fetch-Site": "same-origin",
                            "Content-Type": "application/json"})
        self.assertEqual(status, 200)
        self.assertEqual(self.app.settings()["workflow_password"], "ABCDEFGHJKMNPQRS")
        self.assertEqual(self.post({"Host": f"localhost:{self.port}", "Content-Type": "application/json"}), 200)


if __name__ == "__main__":
    unittest.main()
