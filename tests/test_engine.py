"""The memory engine: store lifecycle, extraction and consolidation guards, retrieval and the pipeline."""

import json
import os
import tempfile
import time
import unittest

from helpers import Oracle, mem, transcript

from memengine import MemoryEngine, Store, format_context, retrieve, schema
from memengine.consolidate import execute, neighbors
from memengine.extract import extract
from memengine.llm import ReplayProvider, PendingResponse, ScriptedProvider, Usage
from memengine.store import TransitionError

DAY1, DAY2, DAY3 = "2026-09-01T10:00:00+08:00", "2026-09-10T10:00:00+08:00", "2026-09-20T10:00:00+08:00"


def seg(text, speaker="user"):
    return {"speaker": speaker, "text": text}


# Records copied from the official synthetic fixture (auday-skill tests/make_fixture.py).
OFFICIAL = [
    {"id": "transcript-000", "kind": "transcript", "title": "合成项目讨论",
     "text": "合成记录 0：周五完成发布检查，保留原始转录与来源。", "start": "2026-01-01T09:00:00+08:00",
     "timeZone": "Asia/Shanghai", "status": "saved", "sourceIDs": [], "audioAssetID": "audio-demo", "revision": 1},
    {"id": "memory-1", "kind": "memory", "title": "已确认偏好", "text": "用户希望保留原始转录。",
     "status": "confirmed", "sourceIDs": ["transcript-000"]},
    {"id": "memory-2", "kind": "memory", "title": "候选记忆", "text": "可能偏好周一复盘。",
     "status": "candidate", "sourceIDs": ["transcript-001"]},
]


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.store = Store()

    def add(self, status=schema.SAVED, **kw):
        fields = dict(key="preference.drink", category="preference", content="用户喜欢燕麦拿铁",
                      status=status, attribution="user_stated", certainty="definite", temporal="stable",
                      importance=3, observed_at=DAY1, source_ids=["t1"],
                      evidence=[{"record_id": "t1", "quote": "燕麦拿铁"}])
        fields.update(kw)
        return self.store.add(**fields)

    def test_official_fixture_records_round_trip(self):
        for record in OFFICIAL:
            self.store.put_record(record)
        self.assertEqual(self.store.record("memory-1")["status"], "confirmed")
        self.assertEqual(self.store.record("memory-2")["sourceIDs"], ["transcript-001"])
        row = self.store.db.execute("SELECT kind, date FROM records WHERE id='transcript-000'").fetchone()
        self.assertEqual(tuple(row), ("transcript", "2026-01-01"))

    def test_unknown_kind_rejected(self):
        with self.assertRaises(ValueError):
            self.store.put_record({"id": "x", "kind": "note"})

    def test_user_only_transitions(self):
        memory = self.add(status=schema.CANDIDATE)
        with self.assertRaises(TransitionError):
            self.store.transition(memory.id, schema.CONFIRMED, actor="system", reason="x")
        with self.assertRaises(TransitionError):
            self.store.transition(memory.id, schema.INACTIVE, actor="system", reason="model said so")
        self.store.confirm(memory.id)
        self.store.deactivate(memory.id)
        self.assertEqual(self.store.get(memory.id).status, schema.INACTIVE)
        self.store.reactivate(memory.id)
        self.assertEqual(self.store.get(memory.id).status, schema.SAVED)

    def test_superseded_is_terminal(self):
        memory = self.add()
        self.store.transition(memory.id, schema.SUPERSEDED, actor="system", reason="x")
        with self.assertRaises(TransitionError):
            self.store.reactivate(memory.id)

    def test_edit_keeps_history_and_confirms(self):
        memory = self.add()
        self.store.edit(memory.id, "用户喜欢燕麦拿铁，少糖")
        current = self.store.get(memory.id)
        self.assertEqual((current.version, current.status), (2, schema.CONFIRMED))
        contents = [v["content"] for v in self.store.versions(memory.id)]
        self.assertIn("用户喜欢燕麦拿铁", contents)
        self.assertIn("用户喜欢燕麦拿铁，少糖", contents)

    def test_expire_only_past_plans(self):
        past = self.add(key="plan.dentist", temporal="temporary", valid_until="2026-09-08")
        future = self.add(key="plan.trip", temporal="temporary", valid_until="2026-12-01")
        stable = self.add(key="pet.cat.name")
        expired = self.store.expire("2026-10-01")
        self.assertEqual([m.id for m in expired], [past.id])
        self.assertEqual(self.store.get(past.id).status_reason, "expired")
        self.assertEqual(self.store.get(future.id).status, schema.SAVED)
        self.assertEqual(self.store.get(stable.id).status, schema.SAVED)

    def test_persists_to_disk(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "m.sqlite")
            store = Store(path)
            first = store.add(key="pet.cat.name", category="relationship", content="用户的猫叫年糕",
                              status=schema.SAVED, attribution="user_stated", certainty="definite",
                              temporal="stable", importance=4, observed_at=DAY1, source_ids=["t1"],
                              evidence=[{"record_id": "t1", "quote": "年糕"}])
            store.confirm(first.id)
            store.close()
            reopened = Store(path)
            memory = reopened.get(first.id)
            self.assertEqual((memory.status, memory.source_ids), (schema.CONFIRMED, ["t1"]))
            self.assertEqual(len(reopened.events()), 2)
            self.assertEqual(reopened.similar("猫 年糕", schema.ACTIVE, min_score=0.1)[0].id, first.id)
            reopened.close()


class ExtractionGuardTests(unittest.TestCase):
    def run_extract(self, segments, items, start=DAY1):
        record = transcript("t1", start, segments)
        provider = ScriptedProvider(lambda s, u: {"memories": items})
        return extract(record, provider)

    def test_valid_user_statement_saved(self):
        result = self.run_extract([seg("我家猫叫年糕。")],
                                  [mem("用户的猫叫年糕", "pet.cat.name", "我家猫叫年糕", "t1", importance=4)])
        self.assertEqual(result.accepted[0]["status"], schema.SAVED)
        self.assertEqual(result.accepted[0]["source_ids"], ["t1"])

    def test_hallucinated_quote_dropped(self):
        result = self.run_extract([seg("我家猫叫年糕。")],
                                  [mem("用户养了一只狗", "pet.dog.name", "我家狗叫旺财", "t1")])
        self.assertFalse(result.accepted)
        self.assertIn("verbatim", result.dropped[0][1])

    def test_quote_with_speaker_label_and_punctuation_accepted(self):
        result = self.run_extract([seg("我家猫叫年糕。")],
                                  [mem("用户的猫叫年糕", "pet.cat.name", "[USER] 我家猫叫年糕。", "t1")])
        self.assertEqual(len(result.accepted), 1)

    def test_other_speaker_quote_downgraded_to_candidate(self):
        result = self.run_extract([seg("我下个月搬去上海。", "S2"), seg("真好！")],
                                  [mem("用户下个月搬去上海", "plan.move", "我下个月搬去上海", "t1")])
        item = result.accepted[0]
        self.assertEqual((item["attribution"], item["status"]), ("inferred", schema.CANDIDATE))

    def test_unknown_speakers_never_saved(self):
        record = {"id": "t1", "kind": "transcript", "start": DAY1, "text": "我喜欢靠窗的座位"}
        provider = ScriptedProvider(lambda s, u: {"memories": [
            mem("用户喜欢靠窗的座位", "preference.seat", "我喜欢靠窗的座位", "t1")]})
        result = extract(record, provider)
        self.assertEqual(result.accepted[0]["status"], schema.CANDIDATE)

    def test_tentative_and_trivia(self):
        result = self.run_extract([seg("我可能会学日语。今天下雨了。")], [
            mem("用户可能会学日语", "goal.language", "我可能会学日语", "t1", certainty="tentative"),
            mem("今天下雨", "other.weather", "今天下雨了", "t1", importance=1)])
        self.assertEqual([i["status"] for i in result.accepted], [schema.CANDIDATE])
        self.assertEqual(result.dropped[0][1], "below importance threshold")

    def test_expired_plan_and_cross_record_evidence_dropped(self):
        result = self.run_extract([seg("我上周去看了牙医。")], [
            mem("用户要看牙医", "plan.dentist", "我上周去看了牙医", "t1", temporal="temporary",
                valid_until="2026-08-25", category="plan"),
            mem("用户要看牙医", "plan.dentist", "我上周去看了牙医", "t9")])
        self.assertEqual([r for _, r in result.dropped],
                         ["plan already expired at recording time", "evidence cites another record"])

    def test_one_bad_item_does_not_sink_the_batch(self):
        # Seen with the local 3B model: a malformed "skipped" entry and a malformed memory.
        result = self.run_extract([seg("我家猫叫年糕。")], [
            mem("用户的猫叫年糕", "pet.cat.name", "我家猫叫年糕", "t1"),
            {"content": "坏条目", "key": "Bad Key"}])
        self.assertEqual(len(result.accepted), 1)
        self.assertTrue(result.dropped[0][1].startswith("invalid item"))
        provider = ScriptedProvider(lambda s, u: {"memories": [], "skipped": ["not an object"]})
        self.assertEqual(extract(transcript("t1", DAY1, [seg("你好")]), provider).accepted, [])

    def test_invalid_json_retried_once(self):
        replies = iter(["not json", json.dumps({"memories": []})])
        usage = Usage()
        result = extract(transcript("t1", DAY1, [seg("你好")]), ScriptedProvider(lambda s, u: next(replies)),
                         usage=usage)
        self.assertEqual((result.accepted, usage.calls), ([], 2))


class ConsolidationGuardTests(unittest.TestCase):
    def setUp(self):
        self.store = Store()
        self.old = self.store.add(key="routine.badminton.schedule", category="routine",
                                  content="用户每周三打羽毛球", status=schema.CONFIRMED,
                                  attribution="user_stated", certainty="definite", temporal="stable",
                                  importance=3, observed_at=DAY1, source_ids=["t1"],
                                  evidence=[{"record_id": "t1", "quote": "每周三打羽毛球"}])

    def item(self, content="用户现在每周五打羽毛球", observed=DAY2, **kw):
        base = mem(content, "routine.badminton.schedule", "每周五", "t2", category="routine")
        base.update(kw)
        base.update(observed_at=observed, source_ids=["t2"])
        base["status"] = (schema.SAVED if base["attribution"] == "user_stated"
                          and base["certainty"] == "definite" else schema.CANDIDATE)
        return base

    def run_op(self, item, op, target=None, merged=None):
        found = neighbors(self.store, item)
        target = target if target is not None else self.old.id
        return execute(self.store, item, {"operation": op, "target_id": target,
                                          "merged_content": merged, "reason": "test"}, found)

    def test_neighbors_found_by_key_across_languages(self):
        item = self.item(content="The user now plays badminton on Fridays")
        self.assertIn(self.old.id, [m.id for m in neighbors(self.store, item)])

    def test_strong_supersede_of_confirmed_creates_saved_successor(self):
        decision = self.run_op(self.item(), "SUPERSEDE")
        old, new = self.store.get(self.old.id), self.store.get(decision.memory_id)
        self.assertEqual((old.status, old.superseded_by), (schema.SUPERSEDED, new.id))
        self.assertEqual((new.status, new.supersedes), (schema.SAVED, old.id))
        self.assertEqual(old.source_ids, ["t1"])  # history untouched

    def test_weak_supersede_becomes_review(self):
        decision = self.run_op(self.item(certainty="tentative"), "SUPERSEDE")
        self.assertEqual((decision.operation, decision.guard), ("REVIEW", "new evidence is inferred or tentative"))
        self.assertEqual(self.store.get(self.old.id).status, schema.CONFIRMED)
        self.assertEqual(self.store.get(decision.memory_id).status, schema.CANDIDATE)
        self.assertEqual(self.store.reviews()[0]["target_id"], self.old.id)

    def test_stale_evidence_cannot_supersede(self):
        decision = self.run_op(self.item(observed="2026-08-01T10:00:00+08:00"), "SUPERSEDE")
        self.assertEqual(decision.operation, "REVIEW")
        self.assertEqual(self.store.get(self.old.id).status, schema.CONFIRMED)

    def test_hallucinated_target_becomes_review(self):
        decision = self.run_op(self.item(), "SUPERSEDE", target="mem_99999")
        self.assertEqual(decision.operation, "REVIEW")
        self.assertEqual(self.store.get(self.old.id).status, schema.CONFIRMED)

    def test_noop_adds_source_without_new_memory(self):
        decision = self.run_op(self.item(content="用户每周三打羽毛球"), "NOOP")
        self.assertEqual(decision.memory_id, self.old.id)
        self.assertEqual(self.store.get(self.old.id).source_ids, ["t1", "t2"])
        self.assertEqual(len(self.store.all()), 1)

    def test_noop_promotes_candidate_when_user_repeats(self):
        self.store.transition(self.old.id, schema.SUPERSEDED, actor="system", reason="reset")
        cand = self.store.add(key="preference.review_day", category="preference", content="用户可能偏好周一复盘",
                              status=schema.CANDIDATE, attribution="inferred", certainty="tentative",
                              temporal="stable", importance=3, observed_at=DAY1, source_ids=["transcript-001"],
                              evidence=[{"record_id": "transcript-001", "quote": "周一复盘"}])
        item = mem("用户偏好周一复盘", "preference.review_day", "周一复盘", "t2")
        item.update(observed_at=DAY2, source_ids=["t2"], status=schema.SAVED)
        execute(self.store, item, {"operation": "NOOP", "target_id": cand.id, "reason": "same"},
                neighbors(self.store, item))
        self.assertEqual(self.store.get(cand.id).status, schema.SAVED)

    def test_merge_promotes_candidate_when_user_states_it(self):
        # Regression found by the blind eval (scenario 18): the model chose MERGE, not NOOP.
        cand = self.store.add(key="preference.review_day", category="preference", content="可能偏好周一复盘。",
                              status=schema.CANDIDATE, attribution="inferred", certainty="tentative",
                              temporal="stable", importance=3, observed_at=DAY1, source_ids=["transcript-001"],
                              evidence=[{"record_id": "transcript-001", "quote": "周一复盘"}])
        item = mem("用户习惯每周一早上做周复盘", "preference.review_day", "每周一早上做一次周复盘", "t2")
        item.update(observed_at=DAY2, source_ids=["t2"], status=schema.SAVED)
        execute(self.store, item, {"operation": "MERGE", "target_id": cand.id,
                                   "merged_content": "用户习惯每周一早上做周复盘", "reason": "x"},
                neighbors(self.store, item))
        memory = self.store.get(cand.id)
        self.assertEqual((memory.status, memory.attribution), (schema.SAVED, "user_stated"))
        self.assertEqual(memory.source_ids, ["transcript-001", "t2"])

    def test_merge_versions_and_keeps_sources(self):
        decision = self.run_op(self.item(content="用户每周三晚上在学校体育馆打羽毛球"), "MERGE",
                               merged="用户每周三晚上在学校体育馆打羽毛球")
        memory = self.store.get(decision.memory_id)
        self.assertEqual((memory.version, memory.source_ids), (2, ["t1", "t2"]))
        self.assertEqual(self.store.versions(memory.id)[0]["content"], "用户每周三打羽毛球")

    def test_rejected_fact_not_resurrected(self):
        self.store.reject(self.old.id)
        decision = self.run_op(self.item(content="用户每周三打羽毛球"), "ADD", target=None)
        self.assertEqual(decision.operation, "NOOP")
        self.assertEqual(len(self.store.all()), 1)
        self.assertEqual(self.store.get(self.old.id).status, schema.REJECTED)
        self.assertEqual(self.store.events()[-1]["op"], "SUPPRESS")

    def test_inactive_never_reactivated_or_edited(self):
        self.store.deactivate(self.old.id)
        noop = self.run_op(self.item(content="用户每周三打羽毛球"), "NOOP")
        self.assertEqual(self.store.get(noop.memory_id).status, schema.INACTIVE)
        merge = self.run_op(self.item(), "MERGE", merged="x")
        self.assertEqual(merge.operation, "ADD")
        self.assertEqual(self.store.get(self.old.id).status, schema.INACTIVE)

    def test_no_neighbours_adds_without_llm_call(self):
        provider = ScriptedProvider(lambda s, u: self.fail("LLM should not be called"))
        from memengine.consolidate import consolidate
        item = mem("用户的猫叫年糕", "pet.cat.name", "年糕", "t2", category="relationship")
        item.update(observed_at=DAY2, source_ids=["t2"], status=schema.SAVED)
        self.assertEqual(consolidate(self.store, item, provider).operation, "ADD")


class RetrievalTests(unittest.TestCase):
    def setUp(self):
        self.store = Store()
        base = dict(category="preference", attribution="user_stated", certainty="definite",
                    temporal="stable", importance=3, observed_at=DAY1, source_ids=["t1"], evidence=[])
        self.saved = self.store.add(key="preference.seat", content="用户喜欢靠过道的座位", status=schema.SAVED, **base)
        self.old = self.store.add(key="preference.seat", content="用户喜欢靠窗的座位", status=schema.SUPERSEDED, **base)
        self.cand = self.store.add(key="preference.seat.train", content="用户坐火车可能喜欢靠窗座位",
                                   status=schema.CANDIDATE, **base)
        self.off = self.store.add(key="preference.seat.cinema", content="用户看电影喜欢坐后排座位",
                                  status=schema.SAVED, **base)
        self.store.deactivate(self.off.id)
        self.plan = self.store.add(key="plan.flight", content="用户9月5日飞东京，需要订座位",
                                   status=schema.SAVED, **{**base, "temporal": "temporary", "valid_until": "2026-09-05"})

    def test_lifecycle_filtering(self):
        ids = [i.memory_id for i in retrieve(self.store, "用户喜欢什么座位？", today="2026-10-01")]
        self.assertIn(self.saved.id, ids)
        for hidden in (self.old.id, self.cand.id, self.off.id, self.plan.id):
            self.assertNotIn(hidden, ids)

    def test_candidates_only_on_request_and_labelled(self):
        items = retrieve(self.store, "火车座位", include_candidates=True, today="2026-10-01")
        self.assertIn(self.cand.id, [i.memory_id for i in items])
        self.assertIn("(unverified)", format_context(items))

    def test_budget_and_citations(self):
        items = retrieve(self.store, "座位", budget_tokens=25, today="2026-09-01")
        self.assertEqual(len(items), 1)
        self.assertIn("sources: t1", format_context(items))


class PipelineTests(unittest.TestCase):
    def test_idempotent_and_revision_aware(self):
        r1 = transcript("t1", DAY1, [seg("我家猫叫年糕。")])
        oracle = Oracle({"t1": [mem("用户的猫叫年糕", "pet.cat.name", "我家猫叫年糕", "t1", "relationship")]})
        engine = MemoryEngine(Store(), oracle.provider)
        engine.ingest(r1)
        self.assertTrue(engine.ingest(r1).skipped_existing)
        engine.ingest({**r1, "revision": 2})
        memories = engine.store.all()
        self.assertEqual(len(memories), 1)
        self.assertEqual(memories[0].evidence[0]["record_id"], "t1")

    def test_only_transcripts_feed_extraction(self):
        oracle = Oracle({})
        engine = MemoryEngine(Store(), oracle.provider)
        engine.ingest({"id": "summary-1", "kind": "summary", "text": "用户似乎很喜欢跑步",
                       "status": "complete", "sourceIDs": ["t1"]})
        self.assertEqual(oracle.provider.calls, [])

    def test_steady_state_over_many_sessions(self):
        """100 sessions repeating 5 stable facts plus one changing fact every 10 sessions:
        the store must stay small, keep every source, and keep exactly one current value."""
        facts = [("pet.cat.name", "用户的猫叫年糕"), ("preference.drink", "用户喜欢燕麦拿铁"),
                 ("preference.editor", "用户主力编辑器是 Zed"), ("relationship.sister", "用户的妹妹在读医学院"),
                 ("routine.badminton.schedule", "用户每周五打羽毛球")]
        extractions, records = {}, []
        for n in range(100):
            rid = f"t{n:03d}"
            key, content = facts[n % 5]
            quote = content.removeprefix("用户")
            gym = f"用户在第{n // 10}号健身房锻炼"
            text = f"{quote}。{gym.removeprefix('用户')}。"
            records.append(transcript(rid, f"2026-09-{1 + n // 4:02d}T{8 + n % 4:02d}:00:00+08:00", [seg(text)]))
            extractions[rid] = [mem(content, key, quote, rid),
                                mem(gym, "routine.gym.location", gym.removeprefix("用户"), rid, "routine")]
        engine = MemoryEngine(Store(), Oracle(extractions).provider)
        started = time.perf_counter()
        engine.ingest_all(records)
        elapsed = time.perf_counter() - started
        active = engine.store.all(schema.ACTIVE)
        self.assertEqual(len(active), 6)
        gyms = [m for m in active if m.key == "routine.gym.location"]
        self.assertEqual([m.content for m in gyms], ["用户在第9号健身房锻炼"])
        self.assertEqual(len(engine.store.all([schema.SUPERSEDED])), 9)
        cat = next(m for m in active if m.key == "pet.cat.name")
        self.assertEqual(len(cat.source_ids), 20)
        self.assertLess(elapsed, 30)


class ReplayTests(unittest.TestCase):
    def test_pending_prompts_are_recorded(self):
        with tempfile.TemporaryDirectory() as tmp:
            pending = {}
            provider = ReplayProvider(os.path.join(tmp, "c.json"), pending)
            with self.assertRaises(PendingResponse):
                extract(transcript("t1", DAY1, [seg("hi")]), provider)
            (key, prompt), = pending.items()
            self.assertIn("RECORD_ID: t1", prompt["user"])
            with open(os.path.join(tmp, "c.json"), "w") as handle:
                json.dump({key: '{"memories": []}'}, handle)
            result = extract(transcript("t1", DAY1, [seg("hi")]), ReplayProvider(os.path.join(tmp, "c.json")))
            self.assertEqual(result.accepted, [])

class UnstutterTests(unittest.TestCase):
    def test_a_word_decoded_with_a_piece_twice_is_repaired(self):
        from app import transcribe
        words = {"transcription", "letter", "coffee"}.__contains__
        self.assertEqual(transcribe.unstutter("这个这个transranscription。", words), "这个这个transcription。")
        self.assertEqual(transcribe.unstutter("Transscription", words), "Transcription")
        self.assertEqual(transcribe.unstutter("a letter about Niangao", words), "a letter about Niangao")


if __name__ == "__main__":
    unittest.main()
