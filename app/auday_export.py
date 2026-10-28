"""The replica's records in the shape the official Auday Skill syncs from the phone.

Observed on a real phone (docs/AUDAY_OBSERVATIONS.md): one transcript record per snippet; two
records per processed hour (`saved` holds the Summary, `saved-overview` the short note and
density); Highlights; one Reflection per day keyed by local midnight; memories that keep the ID
of the hourly candidate they were promoted from. Every record has id, kind, payload, start, state,
text, timeZone, timeZoneBasis and title. Fields Auday derives from data we do not have (body and
location context, artwork) are left out.
"""

import hashlib
import json
from datetime import datetime, timedelta, timezone

SESSION_GAP = timedelta(minutes=10)     # a longer silence starts a new recording session
SPEAKER = {"Me": "owner", "Me*": "contains-owner"}     # Auday's speaker.attribution values
PROMPT_VERSION = "replica-1"
STATES = {"candidate": "candidate", "confirmed": "confirmed", "saved": "automaticallySaved",
          "rejected": "rejected", "superseded": "superseded", "inactive": "inactive"}


def audio_asset_id(replica_id):
    """The phone names audio assets `audio-` plus 64 hex digits."""
    return "audio-" + hashlib.sha256(replica_id.encode()).hexdigest()


def _utc(value):
    return datetime.fromisoformat(value).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _hour(dt):
    return dt.replace(minute=0, second=0, microsecond=0)


def _base(kind, rid, start, state, text, title, time_zone, payload, **extra):
    return {"id": f"{kind}:{rid}" if kind in ("transcript", "memory") else rid, "kind": kind, "payload": payload,
            "start": start, "state": state, "text": text, "timeZone": time_zone,
            "timeZoneBasis": "current-display", "title": title, **extra}


def transcript_records(transcripts, time_zone):
    """One record per snippet. hourIndex counts hours from the start of its recording session."""
    out, session, session_start, last_end = [], None, None, None
    for record in sorted(transcripts, key=lambda r: r["start"]):
        base = datetime.fromisoformat(record["start"])
        for n, segment in enumerate(record.get("segments") or []):
            start = base + timedelta(seconds=segment.get("start", 0))
            end = base + timedelta(seconds=segment.get("end", segment.get("start", 0)))
            if last_end is None or start - last_end > SESSION_GAP:
                session, session_start = record["id"], start
            last_end = end
            hour_index = int((_hour(start) - _hour(session_start)).total_seconds() // 3600)
            payload = {"hourIndex": hour_index, "hourStart": _hour(start).isoformat(), "sessionID": session,
                       "sourceID": record["id"], "offset": segment.get("start", 0),
                       "endOffset": segment.get("end", 0)}
            for key in ("emotion", "event"):
                if segment.get(key):
                    payload[key] = segment[key]
            if segment.get("owner") in SPEAKER:
                payload["speaker"] = {"attribution": SPEAKER[segment["owner"]], "source": "Auday Replica"}
            extra = {"audioAssetIDs": [audio_asset_id(record["audioAssetID"])]} if record.get("audioAssetID") else {}
            out.append(_base("transcript", f"{record['id']}-{n}", start.isoformat(), "saved", segment["text"], "",
                             time_zone, payload, end=end.isoformat(), **extra))
    return out


def _memory_point(point):
    return {"id": point.get("id"), "text": point["text"], "topic": point["topic"],
            "isStableCandidate": bool(point.get("isStableCandidate", point.get("stable"))),
            "sources": point.get("sources", [])}


def hour_records(summary, time_zone):
    """Auday keeps each hour twice: `saved` (the Summary) and `saved-overview` (short note, density)."""
    hour_id = _utc(summary["start"])
    stamp = int(datetime.fromisoformat(summary["start"]).timestamp() * 1000)
    common = {"id": hour_id, "model": summary.get("model", ""), "shortNote": summary["title"],
              "generatedAt": summary.get("updated_at", ""), "promptVersion": PROMPT_VERSION}
    saved = {**common, "summary": summary["text"], "attentionPoints": summary.get("attentionPoints", []),
             "memoryPoints": [_memory_point(p) for p in summary.get("memoryPoints", [])], "keywords": [],
             "outputLanguage": summary.get("outputLanguage", "english"),
             "sources": summary.get("sourceIDs", [])}
    overview = {**common, "informationDensity": summary.get("informationDensity"),
                "sources": summary.get("sourceIDs", [])}
    return [_base("summary", f"summary:{stamp}", summary["start"], "saved", summary["text"], summary["title"],
                  time_zone, saved),
            _base("summary", f"overview:{stamp}", summary["start"], "saved-overview", summary["title"],
                  summary["title"], time_zone, overview)]


def highlight_record(highlight, time_zone):
    payload = {"id": highlight["id"], "title": highlight["title"], "selectionReason": highlight.get("reason", ""),
               "summary": highlight["text"], "attentionPoints": highlight.get("attentionPoints", []),
               "start": _utc(highlight["start"]), "end": _utc(highlight.get("end", highlight["start"])),
               "interpretationComplete": bool(highlight["text"]), "manualMarkIDs": [],
               "mayContinueBeyondScope": bool(highlight.get("mayContinueBeyondScope")), "sources": highlight.get("sourceIDs", []),
               "signals": highlight.get("signals", [])}
    start = datetime.fromisoformat(highlight["start"])
    return _base("highlight", highlight["id"], highlight["start"], "complete", highlight["text"], highlight["title"],
                 time_zone, payload, end=highlight.get("end", highlight["start"]),
                 hourStart=_hour(start).isoformat(), generatedAt=highlight.get("updated_at", ""))


def reflection_record(reflection, time_zone):
    end = datetime.fromisoformat(reflection["start"])
    day = end.replace(hour=0, minute=0, second=0, microsecond=0)
    payload = {"id": _utc(day.isoformat()), "shortNote": reflection["title"], "summary": reflection.get("summary", ""),
               "reflection": {"sentence": reflection["title"], "body": reflection["text"]},
               "reviewWindow": {"start": _utc(reflection.get("windowStart", reflection["start"])),
                                "end": _utc(reflection["start"]),
                                "schedule": {"hour": end.hour, "minute": end.minute}},
               "isDraft": False, "sources": reflection.get("sourceIDs", []),
               "missingHours": reflection.get("missingHours", []), "model": reflection.get("model", ""),
               "generatedAt": reflection.get("updated_at", ""), "promptVersion": PROMPT_VERSION,
               "memoryPromotion": {"completedAt": _utc(reflection["start"]), "memoryIDs": reflection.get("memories", []),
                                   "missingHours": reflection.get("missingHours", [])}}
    return _base("reflection", payload["id"], day.isoformat(), "complete", reflection["text"], reflection["title"],
                 time_zone, payload, savedVersion="current")


def _review_fields(memory, events, source_text):
    """What Auday adds when the user reviews (seen after "This is about me" / "Ignore"):
    confirmed -> userConfirmedAt, firstSavedAt and a fingerprint of each source as confirmed;
    rejected (Ignore) or deactivated -> inactivatedAt."""
    out = {}
    for event in events:
        new = json.loads(event["payload"] or "{}").get("new")
        if new in ("confirmed", "saved") and "firstSavedAt" not in out:
            out["firstSavedAt"] = _utc(event["ts"])
        if new == "confirmed" and event["actor"] == "user" and "userConfirmedAt" not in out:
            out["userConfirmedAt"] = _utc(event["ts"])
            out["confirmedSourceFingerprints"] = {
                sid: hashlib.sha256(source_text(sid).encode()).hexdigest() for sid in memory.source_ids}
        if new in ("rejected", "inactive"):
            out["inactivatedAt"] = _utc(event["ts"])
    return out


def memory_record(memory, time_zone, events=(), source_text=lambda sid: "", candidate_ids=None):
    """`memory` is memengine.store.Memory. Auday keeps no kind or ownership on the record."""
    state = STATES.get(memory.status, memory.status)
    created = memory.created_at or memory.observed_at
    promoted = datetime.fromisoformat(memory.observed_at or created).replace(hour=0, minute=0, second=0, microsecond=0)
    payload = {"id": memory.id, "text": memory.content, "topic": memory.key, "state": state,
               "createdAt": _utc(created), "updatedAt": _utc(memory.updated_at or created),
               "reviewStartedAt": _utc(created), "promotionDayID": _utc(promoted.isoformat()),
               "promotionDayIDs": [_utc(promoted.isoformat())],
               "isUserCorrected": memory.version > 1, "promotedCandidateIDs": candidate_ids or [memory.id],
               "supersedes": [memory.supersedes] if memory.supersedes else [],
               "sources": memory.source_ids, "evidence": memory.evidence,
               **_review_fields(memory, events, source_text)}
    return _base("memory", memory.id, created, state, memory.content, memory.key, time_zone, payload,
                 updatedAt=memory.updated_at or created)


def library(app):
    """Every replica record in the Auday shape, Auday-mode hours only for summaries and Highlights."""
    tz = app.time_zone()
    out = transcript_records(app.records("transcript"), tz)
    for summary in app.records("summary"):
        if summary.get("pipeline") == "auday":
            out += hour_records(summary, tz)
    out += [highlight_record(h, tz) for h in app.records("highlight") if h.get("pipeline") == "auday"]
    out += [reflection_record(r, tz) for r in app.records("reflection") if r.get("pipeline") == "auday"]
    events = {}
    for event in app.store.events():
        if event["op"] == "STATUS":
            events.setdefault(event["memory_id"], []).append(event)
    def text(sid):
        record = app.store.record(sid)
        return (record or {}).get("text", "")
    from app.auday_mode import promoted_ids
    out += [memory_record(m, tz, events.get(m.id, []), text, promoted_ids(app.store, m.id)) for m in app.store.all()]
    return out
