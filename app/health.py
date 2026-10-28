"""Body context from an Apple Health export, derived the way Auday's requests show it.

Rules reverse-engineered by lining up Auday's captured bodyContext intervals with the same day's
Health export (docs/AUDAY_OBSERVATIONS.md):

- walking: StepCount records of at least a minute at walking cadence, merged when < 5 min apart.
- motion context of a heart-rate sample: "active" inside walking or with high PhysicalEffort,
  "sedentary" with low effort, otherwise "unknown".
- heartRateElevated: samples above 1.2 x resting heart rate when sedentary (1.25 x otherwise),
  joined while less than 5 min apart; evidence ends 5 min after the last one, or at the next
  normal sample.
- stressElevated: elevated intervals within 10 min of each other form an episode; once the episode
  has lasted a minute, each non-active elevated interval also counts as stress, from its first
  sample past that minute. stressLow: a sedentary run below resting heart rate, from its second
  sample.
- healthStatistics: heart rate (and HRV when present) per recorded range: mean, min, max, count.

From Auday's FAQ (not checkable on one day of data, so kept conservative): a personal baseline from
up to 14 preceding days, usable once at least 2 earlier days have enough readings (heart rate and
HRV separately); sleep, workouts and the recovery after them are never stress; without a baseline
only a low-confidence estimate from repeated heart-rate readings is given (the rules above, which
is what the captured day shows). Lower strain is displayed as "Feeling good".

All intervals are low-confidence estimates, as on the phone. Nothing here leaves the machine.
"""

import io
import zipfile
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta

TYPES = {"HKQuantityTypeIdentifierHeartRate": "hr", "HKQuantityTypeIdentifierHeartRateVariabilitySDNN": "hrv",
         "HKQuantityTypeIdentifierStepCount": "steps", "HKQuantityTypeIdentifierPhysicalEffort": "effort",
         "HKQuantityTypeIdentifierRestingHeartRate": "rest"}
GAP = timedelta(minutes=5)
EPISODE_GAP = timedelta(minutes=10)
STRESS_AFTER = timedelta(minutes=1)
TAIL = timedelta(minutes=5)
WALK_CADENCE = 40          # steps per minute
WALK_MIN = 60              # seconds
ACTIVE_EFFORT, SEDENTARY_EFFORT = 3.0, 2.0
LABELS = {"heartRateElevated": "Heart rate elevated", "walking": "Walking", "stressElevated": "High stress",
          "stressLow": "Feeling good"}
SIGNALS = {"heartRateElevated": "Elevated heart rate", "walking": "Walk", "stressElevated": "High stress",
           "stressLow": "Feeling good"}
BASELINE_DAYS, BASELINE_MIN_DAYS, BASELINE_MIN_READINGS = 14, 2, 10
RECOVERY = timedelta(minutes=30)        # after a workout ends
# Replica rule, stricter than Auday: a raised heart rate from 2 minutes before a walk (step records
# can start late) to 10 minutes after it is the walk itself: no High stress, no separate Elevated
# heart rate; the walk is stretched to cover it. On a day out Auday marks most of a walk as High
# stress.
WALK_BEFORE, WALK_AFTER = timedelta(minutes=2), timedelta(minutes=10)
STRESS_HR, STRESS_HRV = 1.15, 0.85      # vs the personal baseline, when one exists
FRESH_HRV = timedelta(hours=2)


def _time(value):
    return datetime.strptime(value, "%Y-%m-%d %H:%M:%S %z")


def read_export(source):
    """export.zip / export.xml path or bytes -> samples {kind: [(start, end, value)]}."""
    if isinstance(source, (bytes, bytearray)):
        handle = io.BytesIO(source)
    else:
        handle = open(source, "rb")
    with handle:
        if zipfile.is_zipfile(handle):
            handle.seek(0)
            archive = zipfile.ZipFile(handle)
            name = next(n for n in archive.namelist() if n.endswith("/export.xml") or n == "export.xml")
            stream = archive.open(name)
        else:
            handle.seek(0)
            stream = io.BytesIO(handle.read())
        out = {kind: [] for kind in (*TYPES.values(), "sleep", "workout")}
        for _, element in ET.iterparse(stream, events=("end",)):
            if element.tag == "Record":
                kind = TYPES.get(element.get("type"))
                if kind:
                    out[kind].append((_time(element.get("startDate")), _time(element.get("endDate")),
                                      float(element.get("value"))))
                elif element.get("type") == "HKCategoryTypeIdentifierSleepAnalysis" and \
                        "Asleep" in (element.get("value") or ""):
                    out["sleep"].append((_time(element.get("startDate")), _time(element.get("endDate")), 1.0))
                element.clear()
            elif element.tag == "Workout":
                out["workout"].append((_time(element.get("startDate")), _time(element.get("endDate")), 1.0))
                element.clear()
    for rows in out.values():
        rows.sort()
    return out


def _resting(samples, at):
    """The resting heart rate Health reports for that day (the latest record starting before `at`)."""
    best = None
    for start, _, value in samples["rest"]:
        if start <= at:
            best = value
    return best or 60.0


def walking(samples):
    spans = []
    for start, end, steps in samples["steps"]:
        seconds = (end - start).total_seconds()
        if seconds >= WALK_MIN and steps / (seconds / 60) >= WALK_CADENCE:
            if spans and start - spans[-1][1] < GAP:
                spans[-1][1] = max(spans[-1][1], end)
            else:
                spans.append([start, end])
    return [tuple(s) for s in spans]


def motion(samples, walks, at):
    if any(a <= at <= b for a, b, _ in samples.get("sleep", ())):
        return "asleep"
    if any(a <= at <= b + RECOVERY for a, b, _ in samples.get("workout", ())):
        return "recovering"
    if any(a <= at <= b for a, b in walks):
        return "active"
    for start, end, effort in samples["effort"]:
        if start <= at <= end:
            return "active" if effort >= ACTIVE_EFFORT else "sedentary" if effort <= SEDENTARY_EFFORT else "unknown"
    return "unknown"


def baseline(samples, kind, at, walks=()):
    """Median of calm readings over the BASELINE_DAYS before `at`'s day, or None until at least
    BASELINE_MIN_DAYS earlier days have BASELINE_MIN_READINGS each."""
    day = at.replace(hour=0, minute=0, second=0, microsecond=0)
    values, per_day = [], {}
    for start, _, value in samples[kind]:
        if day - timedelta(days=BASELINE_DAYS) <= start < day and \
                (kind != "hr" or motion(samples, walks, start) in ("sedentary", "unknown")):
            values.append(value)
            per_day[start.date()] = per_day.get(start.date(), 0) + 1
    if sum(1 for n in per_day.values() if n >= BASELINE_MIN_READINGS) < BASELINE_MIN_DAYS:
        return None
    values.sort()
    return values[len(values) // 2]


def _hrv_low(samples, at, hrv_base):
    """True/False when a fresh HRV reading exists (below the baseline or not), None otherwise."""
    recent = [v for s, _, v in samples["hrv"] if at - FRESH_HRV <= s <= at]
    if hrv_base is None or not recent:
        return None
    return recent[-1] < hrv_base * STRESS_HRV


def _interval(kind, run, next_time, observed_from=None):
    first, last = run[0][0], run[-1][0]
    end = min(last + TAIL, next_time) if next_time else last + TAIL
    item = {"kind": kind, "label": LABELS[kind], "confidence": "low", "isEstimate": True, "scope": "interval",
            "start": first.isoformat(), "end": end.isoformat(), "evidenceStart": first.isoformat(),
            "evidenceEnd": end.isoformat(), "observedStart": (observed_from or first).isoformat(),
            "observedEnd": last.isoformat()}
    if kind == "heartRateElevated":
        item["motionContext"] = run[0][2]
    return item


def body_context(samples):
    """All derived intervals for the export, sorted by start."""
    walks = walking(samples)
    out = [{"kind": "walking", "label": LABELS["walking"], "confidence": "low", "isEstimate": True,
            "scope": "interval", "start": a.isoformat(), "end": b.isoformat(), "evidenceStart": a.isoformat(),
            "evidenceEnd": b.isoformat(), "observedStart": a.isoformat(), "observedEnd": b.isoformat()}
           for a, b in walks]
    rows = []
    for start, _, bpm in samples["hr"]:
        rest = _resting(samples, start)
        context = motion(samples, walks, start)
        limit = rest * (1.2 if context == "sedentary" else 1.25)
        state = "high" if bpm > limit else "low" if context == "sedentary" and bpm < rest else "normal"
        rows.append((start, bpm, context, state))
    episode_start, episode_last = None, None
    for state, kind in (("high", "heartRateElevated"), ("low", "stressLow")):
        run = []
        for row in rows + [None]:
            if row and row[3] == state and (not run or row[0] - run[-1][0] < GAP):
                run.append(row)
                continue
            if run:
                next_time = row[0] if row else None
                if kind == "heartRateElevated":
                    elevated = _interval(kind, run, next_time)
                    out.append(elevated)
                    if episode_last is None or run[0][0] - episode_last > EPISODE_GAP:
                        episode_start = run[0][0]
                    episode_last = run[-1][0]
                    late = [r for r in run if r[0] - episode_start >= STRESS_AFTER]
                    if late and run[0][2] in ("sedentary", "unknown") and \
                            not _near_walk(walks, late[0][0], elevated_end(elevated)):   # never active, asleep, recovering or walking
                        stress = _interval("stressElevated", late, next_time, episode_start)
                        stress["end"] = stress["evidenceEnd"] = elevated["evidenceEnd"]
                        confidence = _stress_confidence(samples, walks, late)
                        if confidence:
                            stress["confidence"] = confidence
                            out.append(stress)
                elif len(run) >= 2:
                    out.append(_interval(kind, run[1:], next_time, run[0][0]))
            run = [row] if row and row[3] == state else []
    return sorted(_fold_into_walks(out, walks), key=lambda i: (i["start"], i["kind"]))


def _fold_into_walks(out, walks):
    """Replica rule: a raised heart rate just before, during or after a walk is part of the walk.
    Such a run gets no label of its own and the walk is stretched to cover it (measured from the
    walk's own steps, so stretches do not chain); overlapping walks become one; High stress inside
    a walk is dropped."""
    fold = lambda item, a, b: a - WALK_BEFORE < datetime.fromisoformat(item["end"]) and \
        datetime.fromisoformat(item["start"]) < b + WALK_AFTER
    keys = (("start", min), ("evidenceStart", min), ("observedStart", min),
            ("end", max), ("evidenceEnd", max), ("observedEnd", max))
    walk_items = [dict(i) for i in out if i["kind"] == "walking"]
    for w, (a, b) in zip(walk_items, walks):
        for item in out:
            if item["kind"] == "heartRateElevated" and fold(item, a, b):
                for key, pick in keys:
                    w[key] = pick(w[key], item[key], key=datetime.fromisoformat)
    merged = []
    for w in sorted(walk_items, key=lambda i: i["start"]):
        if merged and w["start"] <= merged[-1]["end"]:
            for key, pick in keys:
                merged[-1][key] = pick(merged[-1][key], w[key], key=datetime.fromisoformat)
        else:
            merged.append(w)
    inside = lambda item: any(w["start"] < item["end"] and item["start"] < w["end"] for w in merged)
    folded = lambda item: any(fold(item, a, b) for a, b in walks)
    return merged + [i for i in out if i["kind"] != "walking"
                     and not (i["kind"] == "heartRateElevated" and folded(i))
                     and not (i["kind"] == "stressElevated" and inside(i))]


def elevated_end(item):
    return datetime.fromisoformat(item["evidenceEnd"])


def _near_walk(walks, start, end):
    """True when [start, end] overlaps a walk, from WALK_BEFORE before it to WALK_AFTER after it."""
    return any(a - WALK_BEFORE < end and start < b + WALK_AFTER for a, b in walks)


def _stress_confidence(samples, walks, run):
    """'low' without a personal baseline (the captured behaviour); with one, 'medium' when heart rate
    is clearly above it and fresh HRV (if any) is below its baseline, else no stress label."""
    at = run[0][0]
    hr_base = baseline(samples, "hr", at, walks)
    if hr_base is None:
        return "low"
    if max(r[1] for r in run) <= hr_base * STRESS_HR:
        return None
    hrv = _hrv_low(samples, at, baseline(samples, "hrv", at))
    return None if hrv is False else "medium"


def statistics(samples, start, end):
    """healthStatistics for one recorded range."""
    out = []
    for kind, metric, unit in (("hr", "heartRate", "bpm"), ("hrv", "hrvSDNN", "ms")):
        values = [(s, v) for s, _, v in samples[kind] if start <= s < end]
        if values:
            nums = [v for _, v in values]
            out.append({"average": sum(nums) / len(nums), "end": end.isoformat(), "maximum": max(nums),
                        "metric": metric, "minimum": min(nums), "observedEnd": values[-1][0].isoformat(),
                        "observedStart": values[0][0].isoformat(), "sampleCount": len(nums),
                        "start": start.isoformat(), "unit": unit})
    return out


def within(intervals, start, end):
    """Intervals overlapping [start, end), clipped to it like Auday does at hour and fragment edges."""
    out = []
    for item in intervals:
        a, b = datetime.fromisoformat(item["start"]), datetime.fromisoformat(item["end"])
        if a < end and b > start:
            out.append({**item, "start": max(a, start).isoformat(), "end": min(b, end).isoformat()})
    return out


def signals(intervals, session="R001"):
    """Highlight signals Auday builds from body context (kind bodyState)."""
    to_state = {"heartRateElevated": "heartRateElevated", "walking": "walking", "stressElevated": "stressElevated",
                "stressLow": "stressLow"}
    return [{"end": i["end"], "id": f"B{n:03d}", "kind": "bodyState", "label": SIGNALS[i["kind"]],
             "sessionID": session, "sourceIDs": [], "start": i["start"], "toState": to_state[i["kind"]]}
            for n, i in enumerate((i for i in intervals if i["kind"] in SIGNALS), 1)]
