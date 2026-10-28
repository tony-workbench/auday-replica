"""What the watch app's iPhone companion sends: CAF/AAC fragments with a session ID, retried
until acknowledged, and marks. Audio is synthesized."""

import json
import math
import shutil
import struct
import subprocess
import tempfile
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request
import wave
from http.server import ThreadingHTTPServer
from pathlib import Path

from helpers import transcript  # noqa: F401  (adds the repo root to sys.path)

from app.core import App
from app.server import make_handler


def tone_caf(folder, seconds=3):
    """A watch-like fragment: AAC, mono, 48 kHz, ~32 kbps, in a CAF container."""
    wav, caf = Path(folder) / "tone.wav", Path(folder) / "tone.caf"
    with wave.open(str(wav), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(48000)
        handle.writeframes(b"".join(struct.pack("<h", int(8000 * math.sin(i * 2 * math.pi * 440 / 48000)))
                                    for i in range(48000 * seconds)))
    subprocess.run(["afconvert", "-f", "caff", "-d", "aac", "-b", "32000", "-c", "1", str(wav), str(caf)],
                   check=True, capture_output=True)
    return caf.read_bytes()


def tone_adts(folder, seconds=3, cut=0):
    """The current watch fragment: AAC in ADTS (.aac). `cut` drops that many bytes from the end,
    as when the app is killed mid-write; ADTS stays readable up to the last whole frame."""
    tone_caf(folder, seconds)
    aac = Path(folder) / "tone.aac"
    subprocess.run(["afconvert", "-f", "adts", "-d", "aac", "-b", "32000", "-c", "1", str(Path(folder) / "tone.wav"), str(aac)],
                   check=True, capture_output=True)
    data = aac.read_bytes()
    return data[:len(data) - cut] if cut else data


def without_packet_table(caf):
    """The same CAF as a recorder leaves it when it is never closed: the AAC data is there but the
    packet table (pakt chunk) is missing, which nothing can decode."""
    out, at = bytearray(caf[:8]), 8
    while at < len(caf):
        kind, size = caf[at:at + 4], struct.unpack(">q", caf[at + 4:at + 12])[0]
        end = len(caf) if size < 0 else at + 12 + size
        if kind != b"pakt":
            out += caf[at:end]
        at = end
    return bytes(out)


@unittest.skipUnless(shutil.which("afconvert"), "needs macOS afconvert to make a CAF/AAC fragment")
class WatchUploadTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.app = App(self.tmp.name, transcriber=lambda *a, **k: ("zh", [{"start": 0, "end": 2, "text": "测试"}]))
        self.caf = tone_caf(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def serve(self, token=None):
        server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.app, token))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f"http://127.0.0.1:{server.server_address[1]}/api/"

    def upload(self, base, start, session, fragment):
        query = urllib.parse.urlencode({"start": start, "ext": "caf", "session": session, "fragment": fragment})
        req = urllib.request.Request(base + "audio?" + query, self.caf, {"Content-Type": "audio/x-caf"})
        with urllib.request.urlopen(req) as response:
            return json.load(response)

    def test_caf_fragment_is_converted_and_keeps_session(self):
        asset = self.upload(self.serve(), "2026-10-26T11:09:33-07:00", "S-1", "frag-1")
        self.assertAlmostEqual(asset["duration"], 3, delta=0.2)
        self.assertEqual((asset["session"], asset["fragment"]), ("S-1", "frag-1"))
        self.assertTrue((Path(self.tmp.name) / "audio" / asset["path"]).exists())

    def test_retried_fragment_is_stored_once(self):
        base = self.serve()
        first = self.upload(base, "2026-10-26T11:09:33-07:00", "S-1", "frag-1")
        again = self.upload(base, "2026-10-26T11:09:33-07:00", "S-1", "frag-1")
        self.assertEqual(again["id"], first["id"])
        self.assertTrue(again["duplicate"])
        self.assertEqual(self.app.db.execute("SELECT COUNT(*) FROM assets").fetchone()[0], 1)

    def test_watch_session_ids_decide_recording_sessions(self):
        # Back-to-back fragments: contiguity alone would call this one session, but the watch
        # started a new session (a phone call) for the third.
        for n, (start, session) in enumerate([("2026-10-26T15:00:00-07:00", "A"), ("2026-10-26T15:00:03-07:00", "A"),
                                              ("2026-10-26T15:00:06-07:00", "B")]):
            asset = self.app.save_audio(self.caf, start, suffix=".caf", session=session, fragment=f"f{n}")
            self.app.add_transcript(start, [{"speaker": "user", "text": f"片段{n}", "start": 0, "end": 2}],
                                    audio_id=asset["id"])
        transcripts = self.app.records("transcript", "2026-10-26", 15)
        snippets = self.app._hour_inputs("2026-10-26", 15, transcripts, self.app.settings())[0]
        self.assertEqual([s["sessionID"] for s in snippets], ["R001", "R001", "R002"])

    def test_other_machines_need_the_token(self):
        base = self.serve(token="s3cret")
        handler = make_handler(self.app, "s3cret")
        fake = handler.__new__(handler)
        fake.client_address = ("192.168.1.20", 50000)
        fake.headers = {"Authorization": "Bearer wrong"}
        self.assertFalse(fake.allowed())
        fake.headers = {"Authorization": "Bearer s3cret"}
        self.assertTrue(fake.allowed())
        fake.client_address = ("::ffff:127.0.0.1", 50000)
        fake.headers = {}
        self.assertTrue(fake.allowed())
        # From this Mac the API stays open without a token.
        self.assertEqual(self.upload(base, "2026-10-26T11:09:33-07:00", "S-1", "frag-9")["session"], "S-1")

    def test_mark_from_the_watch(self):
        req = urllib.request.Request(self.serve() + "marks", json.dumps({"start": "2026-10-26T11:20:00-07:00"}).encode(),
                                     {"Content-Type": "application/json"})
        with urllib.request.urlopen(req) as response:
            self.assertEqual(json.load(response)["start"], "2026-10-26T11:20:00-07:00")
        self.assertEqual(len(self.app.marks("2026-10-26", 11)), 1)

    def test_retried_mark_is_stored_once(self):
        base = self.serve()
        for _ in range(2):
            req = urllib.request.Request(base + "marks", json.dumps({"start": "2026-10-26T11:20:00-07:00"}).encode(),
                                         {"Content-Type": "application/json"})
            urllib.request.urlopen(req).close()
        self.assertEqual(len(self.app.marks("2026-10-26", 11)), 1)


    def test_unreadable_fragment_is_refused_with_422(self):
        base = self.serve()
        self.caf = without_packet_table(self.caf)
        with self.assertRaises(urllib.error.HTTPError) as raised:
            self.upload(base, "2026-10-27T16:27:46+08:00", "s1", "f-broken")
        self.assertEqual(raised.exception.code, 422)
        self.assertIn("unreadable audio", json.load(raised.exception)["error"])
        self.assertEqual(list((Path(self.tmp.name) / "audio").glob("*.wav")), [])

    def test_adts_fragment_is_converted_even_when_cut_off(self):
        base = self.serve()
        for cut, fragment in ((0, "f-aac"), (777, "f-aac-cut")):
            data = tone_adts(self.tmp.name, cut=cut)
            query = urllib.parse.urlencode({"start": "2026-10-27T19:00:00+08:00", "ext": "aac", "session": "s1", "fragment": fragment})
            req = urllib.request.Request(base + "audio?" + query, data, {"Content-Type": "audio/aac"})
            with urllib.request.urlopen(req) as response:
                asset = json.load(response)
            self.assertGreater(asset["duration"], 2.5 if not cut else 1.5)


if __name__ == "__main__":
    unittest.main()
