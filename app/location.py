"""Watch places, turned into Auday's `locationContext`.

From the captured requests (docs/AUDAY_OBSERVATIONS.md): while recording, the watch notes a position
about every 2 minutes; the phone names it with Apple's reverse geocoder ("Place · Street",
`nameSource: appleGeocoder`) or leaves it `unresolved` (~60% of items). Items are cut at the
5-minute clock grid, the hour and the audio-fragment boundaries. Each one carries the samples around
it as evidence (from 2 minutes before its start to 1 minute after its end); a single sample gives
`confidence: low`, more give `medium`; every item is `isApproximate`. A lone sample covers one
minute and is cut only at the hour.

Inferred, not verified: when a name is resolved (we assume the phone names a fragment only when
its samples stay within ~150 m, i.e. the wearer stayed put), and the poor-accuracy rule for `low`.
Coordinates stay on this Mac; only these labels go to the AI.
"""

import re
from collections import Counter
from datetime import datetime, timedelta

GRID = timedelta(minutes=5)
JOIN = timedelta(minutes=5)       # samples further apart than this start a new stretch
TAIL = timedelta(minutes=1)       # how long the last sample of a stretch counts
BEFORE, AFTER = timedelta(minutes=2), timedelta(minutes=1)
POOR_ACCURACY = 100.0             # metres; worse than this is "low" confidence


ADDRESS = re.compile(r"^\d+[A-Za-z]?(-\d+)?\s")


def place_name(name):
    """Auday keeps a name only for a real place ("City University"); a bare street address such as
    "100 Main St" counts as unresolved."""
    name = (name or "").strip()
    return None if not name or ADDRESS.match(name) else name


def parse(samples):
    """API samples -> sorted [{"t": datetime, "lat", "lon", "accuracy", "name"}]. Raises ValueError."""
    out = []
    for item in samples:
        t = datetime.fromisoformat(item["t"])
        if t.tzinfo is None:
            raise ValueError("Place times must include a UTC offset.")
        lat, lon = float(item["lat"]), float(item["lon"])
        if not (-90 <= lat <= 90 and -180 <= lon <= 180):
            raise ValueError("Place coordinates are out of range.")
        out.append({"t": t, "lat": lat, "lon": lon, "accuracy": float(item.get("accuracy") or 0),
                    "name": place_name(item.get("name"))})
    return sorted(out, key=lambda s: s["t"])


def _iso(dt):
    return dt.replace(microsecond=0).isoformat()


def _stretches(samples):
    run = []
    for sample in samples:
        if run and sample["t"] - run[-1]["t"] > JOIN:
            yield run
            run = []
        run.append(sample)
    if run:
        yield run


def _grid_after(a, b):
    tick = a.replace(minute=a.minute - a.minute % 5, second=0, microsecond=0) + GRID
    while tick < b:
        yield tick
        tick += GRID


def context(samples, start, end, cuts=()):
    """locationContext labels for [start, end). `samples` from parse() (datetimes), `cuts` the
    audio-fragment boundaries. Keys in the captured (alphabetical) order."""
    out = []
    for run in _stretches(samples):
        a, b = max(run[0]["t"], start), min(run[-1]["t"] + TAIL, end)
        if a >= b:
            continue
        # The 5-minute grid includes every clock hour. A lone sample's minute is cut only at the
        # hour (captured: 11:09:36–11:10:36 stays one item).
        grid = _grid_after(a, b) if len(run) > 1 else (t for t in _grid_after(a, b) if t.minute == 0)
        points = sorted({a, b, *grid, *(c for c in cuts if a < c < b)})
        for s, e in zip(points, points[1:]):
            evidence = [x for x in run if s - BEFORE <= x["t"] <= e + AFTER] or \
                [min(run, key=lambda x: abs((x["t"] - s).total_seconds()))]
            accuracy = sorted(x["accuracy"] for x in evidence)[len(evidence) // 2]
            names = Counter(x["name"] for x in evidence if x["name"])
            label = {"confidence": "low" if len(evidence) < 2 or accuracy > POOR_ACCURACY else "medium",
                     "end": _iso(e), "evidenceEnd": _iso(evidence[-1]["t"]),
                     "evidenceStart": _iso(evidence[0]["t"]), "isApproximate": True}
            if names:
                label["name"] = names.most_common(1)[0][0]
            label.update(nameSource="appleGeocoder" if names else "unresolved", start=_iso(s))
            out.append(label)
    return out
