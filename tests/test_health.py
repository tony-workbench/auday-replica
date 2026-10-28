"""Body context from an Apple Health export, with the rules read off Auday's captured requests."""

import io
import json
import re
import tempfile
import unittest
import zipfile

from helpers import transcript  # noqa: F401  (adds the repo root to sys.path)

from app import health
from app.core import App
from memengine.llm import ScriptedProvider

HR = "HKQuantityTypeIdentifierHeartRate"


def record(kind, start, end=None, value=0):
    return (f'<Record type="{kind}" sourceName="Watch" unit="x" startDate="2026-10-26 {start} -0700" '
            f'endDate="2026-10-26 {end or start} -0700" value="{value}"/>')


def export(rows):
    xml = '<?xml version="1.0"?><HealthData>' + "".join(rows) + "</HealthData>"
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr("apple_health_export/export.xml", xml)
    return buffer.getvalue()


ROWS = [record("HKQuantityTypeIdentifierRestingHeartRate", "00:00:00", "23:00:00", 50),
        # a walk: 800 steps over 10 min, high effort; heart rate 90 then 80 (both > 62.5) while walking
        record("HKQuantityTypeIdentifierStepCount", "09:00:00", "09:10:00", 800),
        record("HKQuantityTypeIdentifierPhysicalEffort", "09:00:00", "09:10:00", 4.0),
        record(HR, "09:02:00", value=90), record(HR, "09:03:00", value=80), record(HR, "09:12:00", value=55),
        # a short, slow step record is not walking
        record("HKQuantityTypeIdentifierStepCount", "09:20:00", "09:30:00", 200),
        # sitting: 61 counts (> 60), 60 does not; samples < 10 min apart form one episode
        record("HKQuantityTypeIdentifierPhysicalEffort", "13:30:00", "14:30:00", 1.4),
        record(HR, "13:35:00", value=61), record(HR, "13:41:00", value=63), record(HR, "13:42:00", value=62),
        record(HR, "13:48:00", value=60),
        record("HKQuantityTypeIdentifierHeartRateVariabilitySDNN", "13:40:00", value=40)]


class RuleTests(unittest.TestCase):
    def setUp(self):
        self.samples = health.read_export(export(ROWS))
        self.intervals = health.body_context(self.samples)

    def kinds(self, kind):
        return [(i["evidenceStart"][11:19], i["evidenceEnd"][11:19]) for i in self.intervals if i["kind"] == kind]

    def test_walking_from_long_step_records_only(self):
        self.assertEqual(self.kinds("walking"), [("09:00:00", "09:10:00")])

    def test_elevated_heart_rate_runs_and_tails(self):
        # The 09:02–09:08 run during the 09:00–09:10 walk is part of the walk (replica rule).
        self.assertEqual(self.kinds("heartRateElevated"), [("13:35:00", "13:40:00"), ("13:41:00", "13:47:00")])

    def test_stress_once_a_sitting_episode_lasts(self):
        stress = [i for i in self.intervals if i["kind"] == "stressElevated"]
        self.assertEqual([(s["evidenceStart"][11:19], s["observedStart"][11:19]) for s in stress],
                         [("13:41:00", "13:35:00")])                  # not the first interval of the episode
        self.assertTrue(all(s["confidence"] == "low" and s["isEstimate"] for s in stress))

    def test_statistics_and_signals(self):
        from datetime import datetime
        start = datetime.fromisoformat("2026-10-26T13:30:00-07:00")
        stats = health.statistics(self.samples, start, start.replace(minute=45))
        self.assertEqual([(s["metric"], s["sampleCount"]) for s in stats], [("heartRate", 3), ("hrvSDNN", 1)])
        self.assertEqual(stats[0]["maximum"], 63)
        labels = [s["label"] for s in health.signals(self.intervals)]
        self.assertEqual(labels[:2], ["Walk", "Elevated heart rate"])
        self.assertIn("High stress", labels)


def day_record(kind, day, start, end=None, value=0):
    return (f'<Record type="{kind}" sourceName="Watch" unit="x" startDate="2026-10-{day} {start} -0700" '
            f'endDate="2026-10-{day} {end or start} -0700" value="{value}"/>')


class FaqRuleTests(unittest.TestCase):
    """Rules from Auday's FAQ: personal baseline, sleep and workouts are not stress, Feeling good."""

    def sitting_run(self, day, bpm):
        rows = [day_record("HKQuantityTypeIdentifierPhysicalEffort", day, "13:30:00", "14:30:00", 1.4)]
        rows += [day_record(HR, day, t, value=bpm) for t in ("13:35:00", "13:41:00", "13:42:00")]
        return rows

    def stress(self, rows):
        samples = health.read_export(export(rows))
        return [i for i in health.body_context(samples) if i["kind"] == "stressElevated" and "10-26" in i["start"]]

    def history(self, days, bpm=70):
        return [day_record(HR, d, f"10:{m:02d}:00", value=bpm) for d in days for m in range(12)]

    def test_without_baseline_low_confidence_estimate(self):
        rest = [day_record("HKQuantityTypeIdentifierRestingHeartRate", "26", "00:00:00", "23:00:00", 50)]
        stress = self.stress(rest + self.history(["25"]) + self.sitting_run("26", 63))   # one earlier day only
        self.assertEqual([s["confidence"] for s in stress], ["low"])

    def test_personal_baseline_raises_the_bar(self):
        rest = [day_record("HKQuantityTypeIdentifierRestingHeartRate", "26", "00:00:00", "23:00:00", 50)]
        calm = self.history(["23", "24", "25"], bpm=70)                        # baseline 70 -> stress above 80.5
        self.assertEqual(self.stress(rest + calm + self.sitting_run("26", 63)), [])
        self.assertEqual([s["confidence"] for s in self.stress(rest + calm + self.sitting_run("26", 90))], ["medium"])

    def test_sleep_is_never_stress(self):
        rest = [day_record("HKQuantityTypeIdentifierRestingHeartRate", "26", "00:00:00", "23:00:00", 50)]
        sleep = ['<Record type="HKCategoryTypeIdentifierSleepAnalysis" sourceName="Watch" '
                 'startDate="2026-10-26 13:00:00 -0700" endDate="2026-10-26 14:00:00 -0700" '
                 'value="HKCategoryValueSleepAnalysisAsleepCore"/>']
        rows = rest + sleep + [day_record(HR, "26", t, value=63) for t in ("13:35:00", "13:41:00", "13:42:00")]
        self.assertEqual(self.stress(rows), [])

    def test_feeling_good_label_and_signal(self):
        self.assertEqual(health.LABELS["stressLow"], "Feeling good")
        item = {"kind": "stressLow", "start": "a", "end": "b"}
        self.assertEqual(health.signals([item])[0]["label"], "Feeling good")


class AppHealthTests(unittest.TestCase):
    def test_hour_request_carries_body_context_and_chips(self):
        def scripted(system, user):
            if "You select Highlights" in system:
                return {"highlights": [{"title": "Class", "reason": "r", "startSourceID": "T001",
                                        "endSourceID": "T002"}]}
            if "detailed interpretation" in system:
                return {"interpretation": "i", "attentionPoints": []}
            return {"shortNote": "n", "summary": "s", "attentionPoints": [], "memoryPoints": [],
                    "informationDensity": 10}
        with tempfile.TemporaryDirectory() as tmp:
            provider = ScriptedProvider(scripted)
            app = App(tmp, provider=provider)
            app.update_settings({"pipeline": "auday"})
            self.assertEqual(app.import_health(export(ROWS))["heartRateSamples"], 7)
            app.add_transcript("2026-10-26T13:40:00-07:00", [{"start": 0, "end": 5, "text": "lecture", "speaker": "unknown"},
                                                              {"start": 60, "end": 65, "text": "more", "speaker": "unknown"}])
            app.process_hour("2026-10-26", 13)
            selection = provider.calls[0][1]
            context = json.loads(re.search(r"<recorded_context_data>\n(.*?)\n</recorded_context_data>", selection, re.S).group(1))
            self.assertIn("stressElevated", [b["label"]["kind"] for b in context["bodyContext"]])
            self.assertEqual(context["healthStatistics"][0]["metric"], "heartRate")
            self.assertIn('"label": "High stress"', selection)
            chips = [c["label"] for c in app.records("highlight", "2026-10-26", 13)[0]["signals"]]
            self.assertEqual(chips, ["Elevated heart rate", "High stress"])

            app.update_settings({"body_data": False})
            self.assertIsNone(app.body_for(*[__import__("datetime").datetime.fromisoformat(t) for t in
                                             ("2026-10-26T13:00:00-07:00", "2026-10-26T14:00:00-07:00")]))


if __name__ == "__main__":
    unittest.main()


class HealthKitSyncTests(unittest.TestCase):
    """The iPhone companion reads HealthKit itself (as Auday does) instead of an exported zip."""

    @staticmethod
    def as_sync(samples):
        return {kind: [[a.isoformat(), b.isoformat(), v] for a, b, v in rows] for kind, rows in samples.items() if rows}

    def test_sync_in_pieces_matches_the_export(self):
        samples = self.as_sync(health.read_export(export(ROWS)))
        first = {k: rows[: len(rows) // 2] for k, rows in samples.items()}
        rest = {k: rows[len(rows) // 2:] for k, rows in samples.items()}
        with tempfile.TemporaryDirectory() as a, tempfile.TemporaryDirectory() as b:
            synced, imported = App(a), App(b)
            synced.sync_health(first)
            synced.sync_health(rest)
            again = synced.sync_health(rest)                 # a resent batch changes nothing
            imported.import_health(export(ROWS))
            self.assertEqual(again["heartRateSamples"], 7)
            self.assertEqual(synced._health()[0], imported._health()[0])
            self.assertIn("stressElevated", [i["kind"] for i in synced._health()[0]])

    def test_zip_history_and_sync_combine(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = App(tmp)
            app.import_health(export(ROWS[:6]))
            result = app.sync_health({"hr": [["2026-10-26T13:35:00-07:00", "2026-10-26T13:35:00-07:00", 61]]})
            self.assertEqual((result["heartRateSamples"], result["added"]), (4, 1))

    def test_rejects_unknown_kinds_and_naive_times(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = App(tmp)
            with self.assertRaises(ValueError):
                app.sync_health({"bloodSugar": []})
            with self.assertRaises(ValueError):
                app.sync_health({"hr": [["2026-10-26T13:35:00", "2026-10-26T13:35:00", 61]]})

    def test_http_endpoint(self):
        import threading
        import urllib.request
        from http.server import ThreadingHTTPServer
        from app.server import make_handler
        with tempfile.TemporaryDirectory() as tmp:
            app = App(tmp)
            server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(app))
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                body = json.dumps({"samples": self.as_sync(health.read_export(export(ROWS)))}).encode()
                req = urllib.request.Request(f"http://127.0.0.1:{server.server_address[1]}/api/health/samples", body,
                                             {"Content-Type": "application/json"})
                with urllib.request.urlopen(req) as response:
                    self.assertEqual(json.load(response)["heartRateSamples"], 7)
            finally:
                server.shutdown()
                server.server_close()


class WalkingIsNotStressTests(unittest.TestCase):
    def test_raised_heart_rate_after_a_walk_is_not_stress(self):
        from datetime import datetime, timedelta, timezone
        from app import health
        t0 = datetime(2026, 1, 5, 9, 0, tzinfo=timezone.utc)
        def samples(hr_from):
            steps = [(t0 + timedelta(minutes=m), t0 + timedelta(minutes=m + 1), 100.0) for m in range(10)]   # a 10-minute walk
            hr = [(t0 + timedelta(minutes=hr_from + m), t0 + timedelta(minutes=hr_from + m), 110.0) for m in range(0, 8, 2)]
            return {"hr": hr, "hrv": [], "steps": steps, "effort": [], "rest": [(t0 - timedelta(hours=8), t0, 60.0)],
                    "sleep": [], "workout": []}
        kinds = lambda s: {i["kind"] for i in health.body_context(s)}
        after = health.body_context(samples(12))                   # 2 min after the walk: part of the walk
        self.assertEqual({i["kind"] for i in after}, {"walking"})
        self.assertEqual(after[0]["end"], (t0 + timedelta(minutes=23)).isoformat())   # stretched over it
        self.assertIn("stressElevated", kinds(samples(40)))        # half an hour later, sitting
