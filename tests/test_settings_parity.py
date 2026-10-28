"""Settings that mirror Auday's settings pages: cloud transcription, Daily Reflection switch,
original-audio retention, Check Connection."""

import tempfile
import unittest
from datetime import datetime, timedelta, timezone

from helpers import transcript  # noqa: F401  (adds the repo root to sys.path)

from app import remote_asr
from app.core import App
from memengine.llm import ScriptedProvider

TZ = timezone(timedelta(hours=-7))


class RemoteASRTests(unittest.TestCase):
    def test_openai_verbose_json(self):
        lang, out = remote_asr.parse_openai({"language": "chinese", "segments": [
            {"start": 0.0, "end": 2.5, "text": " 我养了一只猫。"}, {"start": 3, "end": 4, "text": "  "}]})
        self.assertEqual((lang, out), ("chinese", [{"start": 0.0, "end": 2.5, "text": "我养了一只猫。"}]))

    def test_deepgram_long_utterance_splits_between_words(self):
        words = [{"start": i * 2.0, "end": i * 2.0 + 1.5, "word": "w", "punctuated_word": f"w{i}"} for i in range(12)]
        data = {"results": {"channels": [{"detected_language": "en"}], "utterances": [
            {"start": 0, "end": 23.5, "transcript": "…", "words": words},
            {"start": 30, "end": 32, "transcript": "Short one.", "words": []}]}}
        lang, out = remote_asr.parse_deepgram(data)
        self.assertEqual(lang, "en")
        self.assertTrue(all(o["end"] - o["start"] <= 15 for o in out))
        self.assertEqual(out[0]["text"].split()[0], "w0")
        self.assertEqual(out[-1]["text"], "Short one.")

    def test_multipart_carries_fields_and_file(self):
        body, content_type = remote_asr.multipart({"model": "whisper-1"}, "file", "a.wav", b"RIFF")
        boundary = content_type.split("boundary=")[1]
        self.assertIn(b'name="model"\r\n\r\nwhisper-1', body)
        self.assertIn(b'filename="a.wav"', body)
        self.assertTrue(body.endswith(f"--{boundary}--\r\n".encode()))


class AppSettingsTests(unittest.TestCase):
    def test_secret_asr_key_is_masked(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = App(tmp)
            app.update_settings({"asr_api_key": "dg-secret-1234"})
            self.assertTrue(app.public_settings()["asr_api_key"].endswith("1234"))
            self.assertNotIn("secret", app.public_settings()["asr_api_key"])
            app.update_settings({"asr_api_key": app.public_settings()["asr_api_key"]})   # masked echo
            self.assertEqual(app.settings()["asr_api_key"], "dg-secret-1234")

    def test_languages_limited_to_local_efficient_set(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = App(tmp)
            app.update_settings({"language": "yue", "primary_language": "Japanese"})
            app.update_settings({"language": "fr", "primary_language": "French"})
            self.assertEqual((app.settings()["language"], app.settings()["primary_language"]), ("yue", "Japanese"))

    def test_daily_reflection_switch(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = App(tmp, provider=ScriptedProvider(lambda s, u: {}))
            app.update_settings({"pipeline": "auday", "reflection_time": "16:07", "auto_daily": False})
            app.put_record({"id": "summary-x", "kind": "summary", "title": "t", "text": "s",
                            "start": "2026-10-26T14:00:00-07:00", "pipeline": "auday", "revision": 1})
            self.assertFalse(app.daily_due(datetime(2026, 10, 26, 16, 30, tzinfo=TZ)))
            app.update_settings({"auto_daily": True})
            self.assertTrue(app.daily_due(datetime(2026, 10, 26, 16, 30, tzinfo=TZ)))

    def test_audio_retention_deletes_old_transcribed_audio_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = App(tmp)
            (app.data / "audio").mkdir(exist_ok=True)
            for name, start, state in (("old", "2026-10-01T10:00:00-07:00", "transcribed"),
                                       ("new", "2026-10-25T10:00:00-07:00", "transcribed"),
                                       ("pending", "2026-10-01T11:00:00-07:00", "saved")):
                (app.data / "audio" / f"{name}.wav").write_bytes(b"x")
                app.put_asset({"id": name, "start": start, "path": f"{name}.wav", "state": state})
            now = datetime(2026, 10, 26, 12, 0, tzinfo=TZ)
            self.assertEqual(app.prune_audio(now), [])                     # default: keep forever
            app.update_settings({"audio_retention_days": "7"})
            self.assertEqual(app.prune_audio(now), ["old"])
            self.assertIsNone(app.audio_path("old"))
            self.assertTrue(app.asset("old")["audioDeleted"])
            self.assertTrue((app.data / "audio" / "pending.wav").exists())

    def test_hour_audio_joins_the_hours_pieces(self):
        import wave
        with tempfile.TemporaryDirectory() as tmp:
            app = App(tmp)
            (app.data / "audio").mkdir(exist_ok=True)
            for n, start in enumerate(("2026-10-26T14:00:00-07:00", "2026-10-26T14:00:30-07:00")):
                path = app.data / "audio" / f"a{n}.wav"
                with wave.open(str(path), "wb") as w:
                    w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
                    w.writeframes(b"\x00\x00" * 16000 * (n + 1))
                app.put_asset({"id": f"a{n}", "start": start, "path": path.name, "state": "transcribed"})
                app.add_transcript(start, [{"start": 0, "end": 1, "text": "x", "speaker": "unknown"}], audio_id=f"a{n}")
            joined = app.hour_audio("2026-10-26", 14)
            with wave.open(str(joined), "rb") as w:
                self.assertEqual(w.getnframes(), 16000 * 3)
            self.assertEqual(app.hour_audio("2026-10-26", 14), joined)        # cached
            self.assertIsNone(app.hour_audio("2026-10-26", 15))

    def test_archive_manual_transcription_and_batch_export(self):
        import io, zipfile
        with tempfile.TemporaryDirectory() as tmp:
            app = App(tmp)
            (app.data / "audio").mkdir(exist_ok=True)
            for n in range(3):
                (app.data / "audio" / f"p{n}.wav").write_bytes(b"x" * 100)
                app.put_asset({"id": f"p{n}", "start": f"2026-10-26T15:{n * 10:02d}:00-07:00", "path": f"p{n}.wav",
                               "state": "saved", "duration": 400})
            self.assertEqual(app.archive()["pendingAudio"], 3)
            self.assertEqual(app.transcribe_next(), {"queued": 2, "seconds": 800})   # each tap queues about 15 minutes of audio at most
            app.add_transcript("2026-10-26T14:10:00-07:00", [{"start": 0, "end": 2, "text": "hi", "speaker": "unknown"}])
            app.put_record({"id": "summary-2026-10-26T14", "kind": "summary", "title": "t", "text": "s",
                            "start": "2026-10-26T14:00:00-07:00", "pipeline": "auday", "revision": 1})
            names = zipfile.ZipFile(io.BytesIO(app.batch_export("2026-10-26", "2026-10-26"))).namelist()
            self.assertEqual(names, ["Auday_2026-10-26_1400-1500_Notes.md"])

    def test_quiet_stretches_are_dropped_but_keep_their_time(self):
        import numpy as np
        import wave
        from app import transcribe
        rng = np.random.default_rng(0)
        sound = lambda sec: (rng.standard_normal(int(sec * 16000)) * 0.1).astype(np.float32)
        audio = np.concatenate([sound(2), np.zeros(10 * 16000, np.float32), sound(2), np.zeros(6 * 16000, np.float32)])
        with tempfile.TemporaryDirectory() as tmp:
            path = f"{tmp}/a.wav"
            with wave.open(path, "wb") as w:
                w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
                w.writeframes((audio * 32767).astype(np.int16).tobytes())
            protected = transcribe.quiet_spans(transcribe.read_wav(path), protect=[(3, 13)])
            self.assertEqual(len(protected), 1)                          # the mark keeps the first gap
            timeline = transcribe.compact(path)
            self.assertEqual(len(timeline), 3)                           # sound, sound, the kept edge of the final quiet
            self.assertAlmostEqual(timeline[1]["recordedOffset"], 11.5, places=1)
            self.assertAlmostEqual(transcribe.recorded_time(timeline, timeline[1]["fileStart"] + 1), 12.5, places=1)
            self.assertLess(len(transcribe.read_wav(path)), 8 * 16000)  # ~16 s of quiet not stored

            app = App(tmp + "/data")
            (app.data / "audio").mkdir(parents=True, exist_ok=True)
            (app.data / "audio" / "a.wav").write_bytes(open(path, "rb").read())
            app.put_asset({"id": "a", "start": "2026-10-26T14:00:00-07:00", "path": "a.wav", "state": "transcribed",
                           "duration": 20.0, "timeline": timeline})
            app.add_transcript("2026-10-26T14:00:00-07:00", [{"start": 0, "end": 1, "text": "x", "speaker": "u"}],
                               audio_id="a")
            with wave.open(str(app.hour_audio("2026-10-26", 14)), "rb") as w:
                self.assertAlmostEqual(w.getnframes() / 16000, 20.0, places=1)   # plays back at full length

    def test_model_list_per_provider(self):
        from unittest import mock
        from memengine import llm
        replies = {"generativelanguage": {"models": [
                       {"name": "models/gemini-3.8-flash", "supportedGenerationMethods": ["generateContent"]},
                       {"name": "models/text-embedding", "supportedGenerationMethods": ["embedContent"]}]},
                   "anthropic": {"data": [{"id": "claude-haiku-5-5"}]},
                   "127.0.0.1": {"data": [{"id": "b"}, {"id": "a"}]}}
        fake = lambda url, headers, timeout=30: next(v for k, v in replies.items() if k in url)
        with mock.patch.object(llm, "_get", fake):
            self.assertEqual(llm.list_models("gemini", api_key="k"), ["gemini-3.8-flash"])
            self.assertEqual(llm.list_models("anthropic", api_key="k"), ["claude-haiku-5-5"])
            self.assertEqual(llm.list_models("openai", base_url="http://127.0.0.1:8089/v1"), ["a", "b"])
            with tempfile.TemporaryDirectory() as tmp:
                app = App(tmp)
                app.update_settings({"provider": "openai", "base_url": "http://127.0.0.1:8089/v1"})
                self.assertEqual(app.list_models(), {"models": ["a", "b"]})

    def test_check_connection(self):
        with tempfile.TemporaryDirectory() as tmp:
            ok = App(tmp, provider=ScriptedProvider(lambda s, u: "OK"))
            self.assertTrue(ok.check_connection()["ok"])

            def broken(system, user):
                raise RuntimeError("401 unauthorized")
            bad = App(tmp, provider=ScriptedProvider(broken))
            result = bad.check_connection()
            self.assertFalse(result["ok"])
            self.assertIn("401", result["error"])


if __name__ == "__main__":
    unittest.main()
