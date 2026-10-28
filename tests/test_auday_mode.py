"""Auday mode: the observed hourly/daily pipeline, its local rules and lifecycle."""

import json
import re
import tempfile
import unittest
from datetime import datetime, timedelta, timezone

from helpers import transcript  # noqa: F401  (adds the repo root to sys.path)

from app import auday_mode
from app.core import App
from app.speaker import me_field
from memengine import schema
from memengine.llm import ScriptedProvider
from memengine.store import Store

TZ = timezone(timedelta(hours=-7))
HOUR = "2026-10-26T14:00:00-07:00"


def snippets():
    rows = [("14:10:00", "Terminal Bench measures agents on real computers.", None),
            ("14:38:54", "我养了一只猫，叫年糕，已经3岁了。", 1),
            ("14:39:01", "我每周三晚上都会去打羽毛球。", 1),
            ("14:39:16", "明天下午三点我要去取快递。", 1)]
    out = []
    for n, (t, text, me) in enumerate(rows, 1):
        item = {"date": f"2026-10-26T{t}-07:00", "end": f"2026-10-26T{t[:6]}59-07:00", "text": text,
                "snippetID": f"T{n:03d}"}
        if me:
            item["me"] = me
        out.append(item)
    return out


def scope(items):
    return auday_mode.hour_scope(HOUR, "America/Los_Angeles", [[0, 3600]], items)


def scripted(system, user):
    if "You select Highlights" in system:
        return {"highlights": [{"title": "Lecture", "reason": "talk", "startSourceID": "T001", "endSourceID": "T001"},
                               {"title": "Personal background", "reason": "facts", "startSourceID": "T004",
                                "endSourceID": "T002"},
                               {"title": "Invented", "reason": "x", "startSourceID": "T999", "endSourceID": "T001"}]}
    if "detailed interpretation" in system:
        return {"interpretation": "You shared facts.", "attentionPoints": ["pick up package"]}
    if "whole-hour Summary" in system:
        return {"shortNote": "Lecture, then personal facts.", "summary": "…",
                "attentionPoints": ["Package at 15:00"], "informationDensity": 140,
                "memoryPoints": [{"text": "You have a cat named Niangao.", "topic": "Pet", "stable": True},
                                 {"text": "You play badminton on Wednesdays.", "topic": "Badminton", "stable": True}]}
    if "daily overview" in system:
        return {"sentence": "A tool takes shape.", "summary": "Day summary."}
    if "daily Reflection" in system:
        return {"reflection": "Reflect."}
    if "possible lasting memories" in system:
        return {"memories": [
            {"candidateIDs": ["m1"], "text": "You have a cat named Niangao.", "topic": "Pet", "kind": "attribute",
             "ownership": "clear"},
            {"candidateIDs": ["m1"], "text": "duplicate use of m1", "topic": "Pet", "kind": "attribute",
             "ownership": "clear"},
            {"candidateIDs": ["m2"], "text": "You play badminton.", "topic": "Badminton", "kind": "transient",
             "ownership": "clear"}]}
    raise AssertionError(system[:60])


class PromptShapeTests(unittest.TestCase):
    def test_me_field_matches_auday_and_improved_modes(self):
        self.assertEqual(me_field("Me"), 1)
        self.assertEqual(me_field("Me*"), 1)                      # Auday collapses Me* into me:1
        self.assertEqual(me_field("Me*", "improved"), "mixed")
        self.assertIsNone(me_field(None))

    def test_mixed_label_follows_auday_long_snippet_profile(self):
        import numpy as np
        from app.speaker import Voiceprint
        voice = Voiceprint("unused", centroid=np.ones(4))
        voice.score = lambda audio: (0.30, 0.40)                      # below Me, one owner-like window
        long_clip, short_clip = np.zeros(16000 * 10), np.zeros(16000 * 4)
        self.assertEqual(voice.label(long_clip), "Me*")              # Auday: long snippets get Me*
        self.assertIsNone(voice.label(short_clip))                   # never on short ones
        self.assertIsNone(voice.label(long_clip, "improved"))        # improved wants a clearer window
        voice.score = lambda audio: (0.50, 0.55)
        self.assertEqual(voice.label(short_clip), "Me")

    def test_calibration_puts_the_line_between_strangers_and_owner(self):
        from app import speaker
        strangers = [(0.20 + 0.29 * i / 180, 0.25) for i in range(180)]     # up to 0.49, like the lecturer
        owner = [(0.62 + 0.3 * i / 15, 0.7) for i in range(15)]             # same-device owner speech
        t = speaker.calibrate(strangers + owner)
        self.assertTrue(0.49 < t["me"] < 0.62)
        self.assertEqual(speaker.calibrate(owner), {})                      # too few snippets to calibrate
        self.assertLessEqual(speaker.calibrate([(0.9, 0.9)] * 100)["me"], speaker.ME_CAP)

    def test_snippets_numbered_in_time_order_with_owner_labels(self):
        record = {"id": "t1", "start": "2026-10-26T14:38:50-07:00",
                  "segments": [{"start": 10, "end": 12, "text": "later", "owner": "Me*"},
                               {"start": 4, "end": 9, "text": "earlier", "owner": "Me"}]}
        items = auday_mode.snippets_from_transcripts([record])
        self.assertEqual([s["snippetID"] for s in items], ["T001", "T002"])
        self.assertEqual([s["text"] for s in items], ["earlier", "later"])
        self.assertEqual([s["me"] for s in items], [1, 1])
        improved = auday_mode.snippets_from_transcripts([record], "improved")
        self.assertEqual(improved[1]["me"], "mixed")

    def test_hour_request_carries_scope_profile_and_snippets_but_not_owner_text(self):
        provider = ScriptedProvider(scripted)
        items = snippets()
        items[1]["owner"] = "Me"
        auday_mode.select_highlights(provider, scope(items), items,
                                     profile=[{"text": "You live in Springfield.", "topic": "Residence",
                                               "automaticallySaved": True}])
        system, user = provider.calls[0]
        self.assertIn('"me":1', re.sub(r"\s", "", user))
        self.assertIn("automaticallySaved", user)
        self.assertNotIn('"owner"', user)
        self.assertIn("JSON Schema", system)
        self.assertNotIn("primary language is English", system)                 # moved to the message
        self.assertTrue(user.rstrip().endswith("</output_language>"))
        self.assertIn("primary language is English", user.split("<output_language>")[1])

    def test_overheard_rule_only_in_improved_mode(self):
        self.assertNotIn("overheard", auday_mode._system("t", {}, primary="English"))
        self.assertIn("overheard", auday_mode._system("t", {}, primary="English", mode="improved"))

    def test_secondary_language_is_translated_into_the_primary(self):
        system = auday_mode._system("task", {}, primary="English", secondary="Chinese")
        self.assertIn("Write all generated text in English", system)
        self.assertIn("including what the user said in Chinese", system)
        self.assertNotIn("instead of translating", system)


class ContextTests(unittest.TestCase):
    def test_audio_observations_follow_the_captured_rule(self):
        items = snippets()
        tags = [("<|NEUTRAL|>", "<|Speech|>"), ("<|SAD|>", "<|Speech|>"), ("<|EMO_UNKNOWN|>", "<|BGM|>"),
                ("<|NEUTRAL|>", "<|Applause|>")]
        for item, (emotion, event) in zip(items, tags):
            item.update(emotion=emotion, event=event, sessionID="R001")
        obs = auday_mode.audio_observations(items)
        self.assertEqual([o["sourceID"] for o in obs], ["T002", "T003", "T004"])     # plain neutral speech skipped
        self.assertEqual(obs[0], {"certainty": "unverifiedASR", "end": items[1]["end"], "sourceID": "T002",
                                  "start": items[1]["date"], "emotion": "<|SAD|>"})
        self.assertEqual(obs[1]["event"], "<|BGM|>")
        self.assertNotIn("emotion", obs[2])                                          # NEUTRAL is left out

    def test_selection_request_carries_order_signals_and_context(self):
        items = snippets()
        for n, item in enumerate(items):
            item["sessionID"] = "R001" if n < 2 else "R002"
        provider = ScriptedProvider(scripted)
        auday_mode.select_highlights(provider, scope(items), items)
        user = provider.calls[0][1]
        tags = re.findall(r"<([a-z_]+)>", user)
        self.assertEqual(tags[1:], ["hour_scope_data", "confirmed_fact_data", "confirmed_profile_data",
                                    "recorded_data", "source_order_data", "manual_mark_data",
                                    "highlight_signal_data", "recorded_context_data", "final_task",
                                    "output_language"])
        signals = json.loads(user.split("<highlight_signal_data>\n")[1].split("\n</highlight_signal_data>")[0])
        self.assertEqual([s["sourceIDs"] for s in signals], [["T001", "T002"], ["T003", "T004"]])

    def test_session_breaks_on_missing_audio(self):
        records = [{"id": "a", "start": "2026-10-26T15:00:00-07:00", "newSession": True,
                    "segments": [{"start": 1, "end": 3, "text": "x"}]},
                   {"id": "b", "start": "2026-10-26T15:00:30-07:00", "newSession": True,
                    "segments": [{"start": 1, "end": 3, "text": "y"}, {"start": 5, "end": 7, "text": "z"}]}]
        items = auday_mode.snippets_from_transcripts(records)
        self.assertEqual([s["sessionID"] for s in items], ["R001", "R002", "R002"])


class ChipTests(unittest.TestCase):
    def test_chips_match_the_phone(self):
        signals = [{"kind": "semantic", "label": "Conversation"},
                   {"kind": "bodyState", "label": "Elevated heart rate", "toState": "heartRateElevated"},
                   {"kind": "bodyState", "label": "High stress", "toState": "stressElevated"},
                   {"kind": "bodyState", "label": "Elevated heart rate", "toState": "heartRateElevated"}]
        self.assertEqual(auday_mode.signal_chips(signals),
                         [{"label": "Elevated heart rate", "kind": "bodyState", "alert": False},
                          {"label": "High stress", "kind": "bodyState", "alert": True}])


class HourTests(unittest.TestCase):
    def test_hour_pipeline_validates_ids_and_clamps_values(self):
        provider = ScriptedProvider(scripted)
        items = snippets()
        result = auday_mode.process_hour(provider, scope(items), items)
        titles = [h["title"] for h in result["highlights"]]
        self.assertEqual(titles, ["Lecture", "Personal background"])      # unknown ID dropped
        self.assertEqual(result["highlights"][1]["startSourceID"], "T002")  # reversed range fixed
        self.assertEqual([h["mayContinueBeyondScope"] for h in result["highlights"]], [False, True])
        self.assertEqual(len(result["highlights"][1]["snippets"]), 3)
        self.assertEqual(result["highlights"][0]["interpretation"], "You shared facts.")
        self.assertEqual(result["summary"]["informationDensity"], 100)
        self.assertEqual(len(provider.calls), 4)   # select + 2 interpretations + summary

    def test_interpretation_gets_boundary_context(self):
        provider = ScriptedProvider(scripted)
        items = snippets()
        auday_mode.interpret_highlight(provider, {"title": "x", "reason": "y", "startSourceID": "T002",
                                                  "endSourceID": "T002"}, items)
        user = provider.calls[0][1]
        context = json.loads(user.split("<boundary_context_data>\n")[1].split("\n</boundary_context_data>")[0])
        self.assertEqual([s["snippetID"] for s in context["before"]], ["T001"])
        self.assertEqual([s["snippetID"] for s in context["after"]], ["T003", "T004"])


class CandidateTests(unittest.TestCase):
    def evidenced(self, system, user):
        if "whole-hour Summary" in system:
            self.assertIn("snippetIDs", system)
            return {"shortNote": "n", "summary": "s", "attentionPoints": [], "informationDensity": 50,
                    "memoryPoints": [{"text": "You have a cat named Niangao.", "topic": "Pet", "stable": True,
                                      "snippetIDs": ["T002", "T999"]},
                                     {"text": "Uncited claim.", "topic": "X", "stable": False, "snippetIDs": []}]}
        return scripted(system, user)

    def test_auday_candidate_points_at_whole_hour_and_keeps_its_id(self):
        items = snippets()
        summary = auday_mode.hour_summary(ScriptedProvider(scripted), scope(items), items, [])
        point = summary["memoryPoints"][0]
        self.assertEqual(len(point["id"]), 64)
        self.assertTrue(point["isStableCandidate"])
        self.assertEqual(len(point["sources"]), len(items))           # every snippet of the hour

        selected, _ = auday_mode.daily_memory_review(
            ProviderFor(point), [{"hour": HOUR, "summary": "s", "memoryPoints": summary["memoryPoints"]}], "d", [])
        store = Store(":memory:")
        memory = auday_mode.add_review_candidates(store, selected, {}, HOUR)[0]
        self.assertEqual(memory.id, point["id"])                        # Auday: memory ID = candidate ID
        self.assertEqual(memory.evidence, [])

    def test_improved_candidate_cites_only_its_sentences(self):
        items = snippets()
        summary = auday_mode.hour_summary(ScriptedProvider(self.evidenced), scope(items), items, [],
                                          mode="improved")
        self.assertEqual([p["text"] for p in summary["memoryPoints"]], ["You have a cat named Niangao."])
        point = summary["memoryPoints"][0]
        self.assertEqual([s["date"] for s in point["sources"]], [items[1]["date"]])
        selected, _ = auday_mode.daily_memory_review(
            ProviderFor(point), [{"hour": HOUR, "summary": "s", "memoryPoints": summary["memoryPoints"]}], "d", [])
        store = Store(":memory:")
        memory = auday_mode.add_review_candidates(store, selected, {}, HOUR, mode="improved")[0]
        self.assertEqual(memory.evidence[0]["quote"], items[1]["text"])
        self.assertIn("attribute, ownership clear", store.events()[-1]["payload"])     # kept, unlike Auday


def ProviderFor(point):
    return ScriptedProvider(lambda system, user: {"memories": [
        {"candidateIDs": ["m1"], "text": point["text"], "topic": "Pet", "kind": "attribute", "ownership": "clear"}]})


class ExportTests(unittest.TestCase):
    def test_library_matches_phone_shape(self):
        from app import auday_export
        with tempfile.TemporaryDirectory() as tmp:
            app = App(tmp, provider=ScriptedProvider(scripted))
            app.update_settings({"pipeline": "auday", "reflection_time": "16:07"})
            app.add_transcript("2026-10-26T14:38:50-07:00",
                               [{"start": 4, "end": 9, "text": "我养了一只猫，叫年糕。", "speaker": "user", "owner": "Me"},
                                {"start": 11, "end": 14, "text": "明天去取快递。", "speaker": "user", "owner": "Me*"}])
            app.process_hour("2026-10-26", 14)
            app.process_day(datetime(2026, 10, 26, 16, 30, tzinfo=TZ))
            records = auday_export.library(app)
        kinds = {}
        for r in records:
            kinds.setdefault((r["kind"], r["state"]), []).append(r)
            self.assertTrue({"id", "kind", "payload", "start", "state", "text", "timeZone", "title"} <= set(r))
        self.assertEqual(len(kinds[("summary", "saved")]), 1)
        self.assertEqual(len(kinds[("summary", "saved-overview")]), 1)
        speakers = [r["payload"].get("speaker", {}).get("attribution") for r in kinds[("transcript", "saved")]]
        self.assertEqual(speakers, ["owner", "contains-owner"])
        memory = kinds[("memory", "candidate")][0]["payload"]
        point = kinds[("summary", "saved")][0]["payload"]["memoryPoints"][0]
        self.assertEqual(memory["promotedCandidateIDs"], [point["id"]])
        reflection = kinds[("reflection", "complete")][0]["payload"]
        self.assertEqual(reflection["id"], "2026-10-26T07:00:00Z")
        self.assertNotIn("userConfirmedAt", memory)                   # untouched candidate
        self.assertEqual(reflection["reviewWindow"]["schedule"], {"hour": 16, "minute": 7})


class ReviewFieldTests(unittest.TestCase):
    def test_this_is_about_me_and_ignore_fields(self):
        """Matches what Auday records: "This is about me" (confirm) sets state confirmed plus
        userConfirmedAt, firstSavedAt and confirmedSourceFingerprints; Ignore sets state rejected
        plus inactivatedAt."""
        from app import auday_export
        with tempfile.TemporaryDirectory() as tmp:
            app = App(tmp)
            app.put_record({"id": "summary-x", "kind": "summary", "title": "t", "text": "source text",
                            "start": "2026-10-26T14:00:00-07:00", "revision": 1})
            selected = [{"candidateIDs": ["m1"], "text": f"fact {n}", "topic": "T", "kind": "attribute",
                         "ownership": "clear", "hours": ["h"]} for n in (1, 2)]
            kept, ignored = auday_mode.add_review_candidates(app.store, selected, {"h": ["summary-x"]}, HOUR)
            app.memory_action(kept.id, "confirm")
            app.memory_action(ignored.id, "reject")
            records = {r["payload"]["id"]: r for r in auday_export.library(app) if r["kind"] == "memory"}
        a, b = records[kept.id]["payload"], records[ignored.id]["payload"]
        self.assertEqual(a["state"], "confirmed")
        self.assertTrue({"userConfirmedAt", "firstSavedAt"} <= set(a))
        self.assertEqual(list(a["confirmedSourceFingerprints"]), ["summary-x"])
        self.assertEqual((b["state"], "inactivatedAt" in b), ("rejected", True))

    def test_edit_rewrites_in_place_and_confirms(self):
        """Observed: Edit keeps the same record, sets isUserCorrected, and counts as confirmation."""
        from app import auday_export
        with tempfile.TemporaryDirectory() as tmp:
            app = App(tmp)
            memory = auday_mode.add_review_candidates(app.store, [{"candidateIDs": ["m1"], "text": "You use a laptop.",
                "topic": "T", "kind": "attribute", "ownership": "clear", "hours": ["h"]}], {}, HOUR)[0]
            app.memory_action(memory.id, "edit", "You use a different laptop.")
            p = next(r["payload"] for r in auday_export.library(app) if r["kind"] == "memory")
        self.assertEqual((p["id"], p["state"], p["isUserCorrected"], p["supersedes"]),
                         (memory.id, "confirmed", True, []))
        self.assertEqual(p["text"], "You use a different laptop.")
        self.assertIn("userConfirmedAt", p)


class RepromotionTests(unittest.TestCase):
    """Day two (observed 2026-10-27): the review re-selects candidates that were already promoted."""

    def day_two(self, mode):
        from memengine import schema as S
        store = Store(":memory:")
        item = lambda cids, text, kind="attribute": {"candidateIDs": ["m"], "promotedCandidateIDs": cids, "text": text,
                                                      "topic": "T", "kind": kind, "ownership": "clear", "hours": ["h"]}
        day1 = auday_mode.add_review_candidates(store, [item(["c-proj"], "project"), item(["c-home"], "home town"),
                                                        item(["c-wed"], "badminton Wednesday"), item(["c-cat"], "cat 年羔"),
                                                        item(["c-run"], "running")], {}, HOUR, mode)
        store.reject(day1[0].id)
        store.confirm(day1[1].id)
        store.confirm(day1[2].id)
        day2 = auday_mode.add_review_candidates(store, [
            item(["c-proj"], "project"), item(["c-home"], "home town"), item(["c-run"], "running"),
            item(["c-orange", "c-cat"], "orange cat Niangao"), item(["c-fri", "c-wed"], "badminton moved to Friday", "state"),
            item(["c-amer"], "Americano")], {}, HOUR, mode)
        return store, day2, S

    def test_auday_drops_updates_to_confirmed_facts(self):
        store, day2, S = self.day_two("auday")
        self.assertEqual([m.content for m in day2], ["orange cat Niangao", "Americano"])
        self.assertEqual(day2[0].id, "c-orange")
        self.assertEqual(auday_mode.promoted_ids(store, "c-orange"), ["c-orange", "c-cat"])
        self.assertEqual(store.get("c-cat").status, S.CANDIDATE)              # the old candidate stays: a duplicate
        self.assertEqual(store.get("c-wed").content, "badminton Wednesday")    # Friday never reaches Review

    def test_improved_surfaces_the_update_and_retires_the_duplicate(self):
        store, day2, S = self.day_two("improved")
        self.assertEqual([m.content for m in day2], ["orange cat Niangao", "badminton moved to Friday", "Americano"])
        self.assertEqual(day2[1].supersedes, "c-wed")                          # the user decides
        self.assertEqual(store.get("c-cat").status, S.SUPERSEDED)
        self.assertEqual(store.get("c-proj").status, S.REJECTED)                # rejected stays rejected
        reworded = auday_mode.add_review_candidates(store, [{"candidateIDs": ["m"], "promotedCandidateIDs": ["c-new"],
            "text": "project", "topic": "T", "kind": "state", "ownership": "clear", "hours": ["h"]}], {}, HOUR, "improved")
        self.assertEqual(reworded, [])                                           # same fact, new candidate ID


class DayTests(unittest.TestCase):
    def test_day_window_ends_at_reflection_time(self):
        now = datetime(2026, 10, 26, 16, 30, tzinfo=TZ)
        start, end = auday_mode.day_window("16:07", now)
        self.assertEqual((start.isoformat(), end.isoformat()),
                         ("2026-10-25T16:07:00-07:00", "2026-10-26T16:07:00-07:00"))
        start, end = auday_mode.day_window("21:00", now)
        self.assertEqual(end.isoformat(), "2026-10-25T21:00:00-07:00")

    def test_local_filter_keeps_reviewable_clear_items_and_uses_each_candidate_once(self):
        candidates = [{"id": "m1", "hour": "h1"}, {"id": "m2", "hour": "h1"}, {"id": "m3", "hour": "h2"}]
        items = [{"candidateIDs": ["m1"], "text": "a", "topic": "t", "kind": "attribute", "ownership": "clear"},
                 {"candidateIDs": ["m1"], "text": "b", "topic": "t", "kind": "state", "ownership": "clear"},
                 {"candidateIDs": ["m2"], "text": "c", "topic": "t", "kind": "transient", "ownership": "clear"},
                 {"candidateIDs": ["m3"], "text": "d", "topic": "t", "kind": "state", "ownership": "unclear"},
                 {"candidateIDs": ["m9"], "text": "e", "topic": "t", "kind": "state", "ownership": "clear"}]
        kept = auday_mode.local_filter(items, candidates)
        self.assertEqual([k["text"] for k in kept], ["a"])
        self.assertEqual(kept[0]["hours"], ["h1"])

    def test_review_candidates_auto_save_after_five_days(self):
        store = Store(":memory:")
        added = auday_mode.add_review_candidates(
            store, [{"candidateIDs": ["m1"], "text": "You have a cat.", "topic": "Personal life · Pet",
                     "kind": "attribute", "ownership": "clear", "hours": ["h1"]}], {"h1": ["summary-x"]},
            "2026-10-26T16:07:00-07:00")
        memory = added[0]
        self.assertEqual(memory.status, schema.CANDIDATE)
        self.assertEqual(memory.source_ids, ["summary-x"])
        created = datetime.fromisoformat(memory.created_at)
        self.assertEqual(auto := auday_mode.auto_save(store, created + timedelta(days=4)), [])
        saved = auday_mode.auto_save(store, created + timedelta(days=5, minutes=1))
        self.assertEqual([m.status for m in saved], [schema.SAVED])
        profile = auday_mode.profile_from_store(store)
        self.assertEqual(profile, [{"id": memory.id, "text": "You have a cat.", "topic": "personal_life.pet",
                                    "automaticallySaved": True, "userCorrected": False}])
        block = auday_mode._profile_block(profile * 3, limit=2)
        self.assertIn("1 additional saved facts are not supplied", block)
        self.assertIn('"userCorrected": false', block)
        store.confirm(memory.id)
        self.assertFalse(auday_mode.profile_from_store(store)[0]["automaticallySaved"])

    def test_notes_export_layout(self):
        items = snippets()
        items[1]["owner"] = "Me"
        items[2]["owner"] = "Me*"
        text = auday_mode.notes_markdown(
            "Auday Replica · test", {"summary": "S", "attentionPoints": ["A"]},
            [{"title": "H", "reason": "R", "interpretation": "I", "attentionPoints": ["P"], "snippets": items[1:3]}],
            items, "America/Los_Angeles")
        for heading in ("## Summary", "## Things to note", "## Highlights", "## Transcript"):
            self.assertIn(heading, text)
        self.assertIn("### 14:38–14:39 · H", text)
        self.assertIn("[14:38] Me: 我养了一只猫", text)
        self.assertIn("[14:39] Me*: 我每周三", text)


class AppAudayModeTests(unittest.TestCase):
    def test_hour_then_day_then_auto_save(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = App(tmp, provider=ScriptedProvider(scripted))
            app.update_settings({"pipeline": "auday", "reflection_time": "16:07"})
            start = "2026-10-26T14:38:50-07:00"
            app.add_transcript(start, [{"start": 4, "end": 9, "text": "我养了一只猫，叫年糕。", "speaker": "user",
                                        "owner": "Me"},
                                       {"start": 11, "end": 14, "text": "明天去取快递。", "speaker": "user",
                                        "owner": "Me"}])
            result = app.process_hour("2026-10-26", 14)
            self.assertEqual(result["memoryPoints"], 2)
            summary = app.store.record("summary-2026-10-26T14")
            self.assertEqual(summary["pipeline"], "auday")
            self.assertEqual(len(app.records("highlight", "2026-10-26", 14)), 1)   # only snippets T001 and T002 exist

            now = datetime(2026, 10, 26, 16, 30, tzinfo=TZ)
            self.assertTrue(app.daily_due(now))
            day = app.process_day(now)
            self.assertFalse(app.daily_due(now))
            memories = app.store.all()
            self.assertEqual([(m.content, m.status) for m in memories],
                             [("You have a cat named Niangao.", schema.CANDIDATE)])
            reflection = app.store.record("reflection-2026-10-26")
            self.assertEqual(reflection["title"], "A tool takes shape.")
            self.assertEqual(reflection["stats"]["memories"], 1)
            portrait = reflection["portrait"]
            self.assertEqual(len(portrait["hours"]), 25)    # a 16:07 window touches 25 clock hours, as on the phone
            cell = next(h for h in portrait["hours"] if h["hourStart"].startswith("2026-10-26T14"))
            self.assertEqual((cell["hasSummary"], cell["highlightCount"]), (True, 1))
            self.assertIsInstance(portrait["seed"], int)
            self.assertEqual(day["memories"], [memories[0].id])

            notes = app.notes("2026-10-26", 14)
            self.assertIn("[14:38] Me: 我养了一只猫", notes)



class DayMessageTests(unittest.TestCase):
    def test_daily_request_matches_captured_layout(self):
        items = snippets()
        items[1]["emotion"] = "<|SAD|>"
        window = (datetime(2026, 10, 25, 16, 7, tzinfo=TZ), datetime(2026, 10, 26, 16, 7, tzinfo=TZ))
        hours = [{"hour": "2026-10-26T14:00:00-07:00", "shortNote": "n", "summary": "s", "memoryPoints": []}]
        highlights = [{"start": items[1]["date"], "end": items[2]["date"], "title": "T", "interpretation": "I"}]
        late = {**items[0], "date": "2026-10-26T16:00:03-07:00", "end": "2026-10-26T16:00:09-07:00", "snippetID": "X"}
        user = auday_mode._day_message("daily_overview_request", hours, highlights, [], window, [],
                                       snippets=items + [late])
        self.assertEqual(re.findall(r"<([a-z_]+)>", user),
                         ["daily_overview_request", "daily_review_evidence", "recorded_context_data",
                          "review_time_scope"])
        evidence = json.loads(user.split("<daily_review_evidence>\n")[1].split("\n</daily_review_evidence>")[0])
        self.assertEqual(sorted(evidence["highlightIntervals"][0]), ["end", "originals", "start"])
        self.assertEqual([o["text"] for o in evidence["highlightIntervals"][0]["originals"]],
                         [items[1]["text"], items[2]["text"]])
        self.assertEqual([o["date"] for o in evidence["boundaryOriginals"]], ["2026-10-26T16:00:03-07:00"])
        self.assertEqual(evidence["window"]["schedule"], {"hour": 16, "minute": 7})
        self.assertIn("Elapsed hours: 24.0", user)


class SegmentTests(unittest.TestCase):
    def test_tokens_cut_only_before_words(self):
        from app import transcribe
        self.assertTrue(transcribe._word_start(" alto"))
        self.assertTrue(transcribe._word_start("猫"))
        self.assertFalse(transcribe._word_start("tain"))
        self.assertEqual(transcribe._join(["The", " tri", "bal"]), "The tribal")


if __name__ == "__main__":
    unittest.main()
