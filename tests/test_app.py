"""The app end to end with a scripted model: hourly processing, reflection, chat, settings and the HTTP API."""

import json
import tempfile
import threading
import unittest
import urllib.parse
import urllib.request
from http.server import ThreadingHTTPServer

from helpers import mem

from app import ai
from app.core import App
from app.server import make_handler
from memengine import prompts
from memengine.llm import ScriptedProvider

START = "2026-09-01T10:15:00+08:00"


def fake_model(system, user):
    if system == ai.HOURLY_SYSTEM:
        rid = user.split("RECORD_ID: ")[1].split()[0]
        return {"summary": {"title": "版本上线安排", "text": "用户答应下周四前完成合并模块。"},
                "highlights": [{"title": "承诺", "record_id": rid, "quote": "我答应下周四之前把合并模块写完",
                                "reason": "commitment", "marked": True},
                               {"title": "编造", "record_id": rid, "quote": "我们下周去日本", "marked": False}]}
    if system == prompts.EXTRACTION_SYSTEM:
        rid = user.split("RECORD_ID: ")[1].split()[0]
        return {"memories": [mem("用户的猫叫年糕", "pet.cat.name", "我家猫叫年糕", rid, "relationship", importance=4)]}
    if system == ai.REFLECTION_SYSTEM:
        return {"title": "专注的一天", "text": "你答应了一个期限。", "quote": "慢慢来",
                "threads": [{"text": "合并模块", "source_ids": ["summary-2026-09-01T10", "summary-bogus"]}]}
    if system == ai.CHAT_SYSTEM:
        return "你答应下周四前完成 [transcript-20260901-101500]，猫叫年糕 [mem_00001]，还有 [transcript-fake]。"
    return {"operation": "ADD", "target_id": None, "reason": "x"}


class AppTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.provider = ScriptedProvider(fake_model)
        self.app = App(self.tmp.name, provider=self.provider,
                       transcriber=lambda *a, **k: ("zh", [{"start": 0, "end": 2, "text": "测试"}]))
        self.app.add_transcript(START, [
            {"speaker": "S2", "text": "这个版本能不能下周四上线？", "start": 0},
            {"speaker": "user", "text": "可以，我答应下周四之前把合并模块写完。我家猫叫年糕。", "start": 3}])

    def tearDown(self):
        self.tmp.cleanup()

    def test_hour_processing_verifies_highlights_and_extracts_memory(self):
        result = self.app.process_hour("2026-09-01", 10)
        self.assertEqual((result["highlights"], result["dropped"]), (1, 1))
        day = self.app.day("2026-09-01")
        hour = day["hours"][0]
        self.assertEqual(hour["summary"]["sourceIDs"], ["transcript-20260901-101500"])
        self.assertEqual(hour["highlights"][0]["sourceIDs"], ["transcript-20260901-101500"])
        self.assertEqual(hour["state"], "done")
        self.assertEqual([m["content"] for m in self.app.memories()], ["用户的猫叫年糕"])
        # Reprocessing regenerates AI results but never re-extracts the same transcript.
        self.app.process_hour("2026-09-01", 10)
        self.assertEqual(len(self.app.memories()), 1)
        self.assertEqual(self.app.store.record("summary-2026-09-01T10")["revision"], 2)

    def test_failed_hourly_output_keeps_transcripts_and_marks_failure(self):
        self.app._provider_override = ScriptedProvider(lambda s, u: "not json")
        self.app.process_hour("2026-09-01", 10)
        hour = self.app.day("2026-09-01")["hours"][0]
        self.assertEqual(hour["state"], "failed")
        self.assertEqual(len(hour["transcripts"]), 1)
        self.assertEqual(self.app.memories(), [])

    def test_reflection_drops_unknown_sources(self):
        self.app.process_hour("2026-09-01", 10)
        record = self.app.make_reflection("2026-09-01")
        self.assertEqual(record["threads"][0]["source_ids"], ["summary-2026-09-01T10"])
        self.assertEqual(record["sourceIDs"], ["summary-2026-09-01T10"])

    def test_chat_keeps_only_real_citations(self):
        self.app.process_hour("2026-09-01", 10)
        reply = self.app.ask("我答应了什么？猫叫什么")
        self.assertNotIn("transcript-fake", reply["answer"])
        self.assertEqual(set(reply["cited"]), {"transcript-20260901-101500", "mem_00001"})
        self.assertEqual([m["role"] for m in self.app.chat_history()], ["user", "assistant"])

    def test_chat_conversations_group_questions(self):
        self.app.process_hour("2026-09-01", 10)
        first = self.app.ask("我答应了什么？")
        self.app.ask("猫叫什么", conversation=first["conversation"])
        other = self.app.ask("今天怎么样")
        self.assertNotEqual(first["conversation"], other["conversation"])
        listing = self.app.conversations()
        self.assertEqual([c["question"] for c in listing], ["今天怎么样", "我答应了什么？"])
        self.assertEqual(listing[1]["messages"], 4)
        thread = self.app.chat_history(conversation=first["conversation"])
        self.assertEqual([m["content"] for m in thread if m["role"] == "user"], ["我答应了什么？", "猫叫什么"])
        # Chats saved before conversations existed are grouped by their day.
        with self.app.db:
            self.app.db.execute("INSERT INTO chats(ts, role, content, cited) VALUES(?,?,?,?)",
                                ("2026-08-01T09:00:00+08:00", "user", "旧问题", "[]"))
        self.assertEqual(self.app.conversations()[-1], {"id": "day-2026-08-01", "question": "旧问题",
                                                        "ts": "2026-08-01T09:00:00+08:00",
                                                        "updated": "2026-08-01T09:00:00+08:00", "messages": 1})

    def test_memories_carry_review_times(self):
        self.app.process_hour("2026-09-01", 10)
        memory = self.app.memories()[0]
        self.assertFalse(memory["edited"])
        self.app.memory_action(memory["id"], "edit", "用户的猫叫年糕，三岁")
        memory = self.app.memories()[0]
        self.assertTrue(memory["edited"])
        self.assertIn("savedAt", memory)
        self.assertIn("userConfirmedAt", memory)
        self.assertNotIn("inactivatedAt", memory)
        self.app.memory_action(memory["id"], "deactivate")
        self.assertIn("inactivatedAt", self.app.memories()[0])
        self.app.memory_action(memory["id"], "reactivate")
        self.assertNotIn("inactivatedAt", self.app.memories()[0])

    def test_day_reports_recorded_time_and_quiet_hours(self):
        self.app.put_asset({"id": "audio-quiet", "start": "2026-09-01T12:00:05+08:00", "duration": 30,
                            "state": "silent"})
        self.app.put_asset({"id": "audio-wait", "start": "2026-09-01T13:00:05+08:00", "duration": 12,
                            "state": "saved"})
        hours = {h["hour"]: h for h in self.app.day("2026-09-01")["hours"]}
        self.assertEqual(hours[10]["recordedSeconds"], 3)       # text only: up to its last segment
        self.assertFalse(hours[10]["quiet"])
        self.assertEqual((hours[12]["recordedSeconds"], hours[12]["quiet"]), (30, True))
        self.assertEqual((hours[13]["pendingAudio"], hours[13]["quiet"]), (1, False))

    def test_search_scope_by_days(self):
        self.app.add_transcript("2026-09-03T09:00:00+08:00", [{"speaker": "user", "text": "年糕今天打疫苗", "start": 0}])
        from app import search
        find = lambda **scope: sorted(r["date"] for r in search.search(
            self.app.db, self.app.store.embedder, "年糕", mode="keyword", **scope))
        self.assertEqual(find(), ["2026-09-01", "2026-09-03"])
        self.assertEqual(find(date_from="2026-09-02", date_to="2026-09-30"), ["2026-09-03"])
        self.assertEqual(find(dates=["2026-09-01", "2026-09-02"]), ["2026-09-01"])

    def test_export_matches_auday_fixture_shape(self):
        self.app.process_hour("2026-09-01", 10)
        library = self.app.export_library()
        self.assertEqual(library["schemaVersion"], 1)
        kinds = {r["kind"] for r in library["records"]}
        self.assertEqual(kinds, {"transcript", "summary", "highlight", "memory"})
        memory = next(r for r in library["records"] if r["kind"] == "memory")
        self.assertEqual(memory["sourceIDs"], ["transcript-20260901-101500"])

    def test_settings_mask_api_key(self):
        self.app.update_settings({"api_key": "sk-secret-1234", "unknown": 1})
        self.assertEqual(self.app.public_settings()["api_key"], "••••••••1234")
        self.app.update_settings({"api_key": "••••••••1234"})
        self.assertEqual(self.app.settings()["api_key"], "sk-secret-1234")
        self.assertNotIn("unknown", self.app.settings())

    def test_http_api_round_trip(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.app))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{server.server_address[1]}/api/"
        try:
            def get(path, body=None):
                data = json.dumps(body).encode() if body is not None else None
                req = urllib.request.Request(base + path, data, {"Content-Type": "application/json"})
                with urllib.request.urlopen(req) as response:
                    return json.load(response)
            self.app.process_hour("2026-09-01", 10)
            self.assertEqual(len(get("day?date=2026-09-01")["hours"]), 1)
            self.assertEqual(get("memories/mem_00001/confirm", {})["status"], "confirmed")
            self.assertEqual(get("search?q=" + urllib.parse.quote("年糕") + "&mode=keyword")[0]["id"], "transcript-20260901-101500")
            self.assertEqual(get("search?q=" + urllib.parse.quote("年糕") + "&mode=keyword&from=2026-09-02"), [])
            asked = get("chat", {"question": "猫叫什么"})
            self.assertEqual(get("chat/conversations")["conversations"][0]["id"], asked["conversation"])
            self.assertEqual(len(get("chat?conversation=" + asked["conversation"])), 2)
            with urllib.request.urlopen(base.replace("/api/", "/")) as response:
                self.assertIn(b"Auday", response.read())
        finally:
            server.shutdown()


if __name__ == "__main__":
    unittest.main()
