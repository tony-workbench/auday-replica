"""Transcripts -> validated candidate memories.

The LLM proposes; deterministic checks decide what survives:
  1. JSON Schema validation: the envelope (with one retry), then each item on its own.
  2. Every evidence quote must be a verbatim substring of the record it cites, and the
     record must be one of the transcripts given to the model.
  3. attribution "user_stated" needs at least one quote in the user's own voice;
     otherwise the item is kept but downgraded to "inferred".
  4. Expired plans (valid_until before the recording date) are dropped.
  5. Low-importance trivia is dropped; duplicates inside one batch are collapsed.
Each surviving item gets an initial status (saved or candidate) from `initial_status`.

`extract_batch` handles an hour of transcripts in one call, because Auday produces its AI
results hourly; a single record uses the simpler single-record prompt.
"""

import re
import unicodedata
from dataclasses import dataclass, field

import jsonschema

from . import prompts, schema
from .llm import complete_json

_SPACE = re.compile(r"\s+")
_LABEL = re.compile(r"^\[[^\]]+\]\s*")
_EDGE_PUNCT = "，。！？、,.!?;；:：\"'“”‘’「」 "


def normalize(text):
    text = unicodedata.normalize("NFKC", text)
    return _SPACE.sub(" ", text).strip().lower()


def clean_quote(quote):
    return _LABEL.sub("", normalize(quote)).strip(_EDGE_PUNCT)


def transcript_lines(record, user_labels):
    """Return (lines, user_label_present, spans). Lines are "[SPEAKER] text" for the prompt;
    spans are (speaker, text) pairs, with the user's own lines labelled "USER"."""
    segments = (record.get("body") or {}).get("segments") or record.get("segments")
    if not segments:
        return [record.get("text", "")], False, [(None, record.get("text", ""))]
    lines, spans, has_user = [], [], False
    for segment in segments:
        speaker = segment.get("speaker") or "unknown"
        is_user = speaker in user_labels
        has_user |= is_user
        label = "USER" if is_user else speaker
        lines.append(f"[{label}] {segment.get('text', '')}")
        spans.append(("USER" if is_user else speaker, segment.get("text", "")))
    return lines, has_user, spans


@dataclass
class ExtractionResult:
    record_id: str
    accepted: list = field(default_factory=list)
    dropped: list = field(default_factory=list)   # (item, reason) rejected by our checks
    skipped: list = field(default_factory=list)   # what the model chose not to extract


def initial_status(item):
    strong = item["attribution"] == "user_stated" and item["certainty"] == "definite"
    return schema.SAVED if strong and item["importance"] >= 3 else schema.CANDIDATE


def _prompt(records, views, any_user):
    speaker = "USER" if any_user else "(none: speaker identity unknown)"
    if len(records) == 1:
        record = records[0]
        return prompts.extraction_user(record["id"], record.get("start", ""),
                                       record.get("timeZone", "unknown"), speaker, views[0][0])
    blocks = [f"### RECORD_ID: {r['id']}  RECORDED_AT: {r.get('start', '')}\n" + "\n".join(lines)
              for r, (lines, _, _) in zip(records, views)]
    return (f"TIME_ZONE: {records[0].get('timeZone', 'unknown')}\nUSER_SPEAKER: {speaker}\n"
            "Several transcripts follow; cite the RECORD_ID each quote comes from.\n\nTRANSCRIPTS:\n"
            + "\n\n".join(blocks))


def extract_batch(records, provider, *, user_labels=("user", "me", "USER"), usage=None, min_importance=2):
    views = [transcript_lines(r, set(user_labels)) for r in records]
    by_id = {}
    for record, (_, _, spans) in zip(records, views):
        by_id[record["id"]] = {
            "start": record.get("start", ""),
            "full": normalize("\n".join(text for _, text in spans)),
            "user": normalize("\n".join(text for who, text in spans if who == "USER")),
        }
    user = _prompt(records, views, any(v[1] for v in views))
    output = complete_json(provider, prompts.EXTRACTION_SYSTEM, user, schema.EXTRACTION_SCHEMA, usage)
    result = ExtractionResult(",".join(by_id), skipped=output.get("skipped", []))
    first_day = min(info["start"] for info in by_id.values())[:10]
    seen = set()

    for item in output["memories"]:
        try:
            schema.validate(item, schema.MEMORY_ITEM_SCHEMA)
        except jsonschema.ValidationError as error:
            result.dropped.append((item, f"invalid item: {error.message[:120]}"))
            continue
        reason = None
        cited = [(by_id.get(e["record_id"]), clean_quote(e["quote"])) for e in item["evidence"]]
        if any(info is None for info, _ in cited):
            reason = "evidence cites another record"
        elif any(not quote or quote not in info["full"] for info, quote in cited):
            reason = "evidence quote not found verbatim in transcript"
        elif item["importance"] < min_importance:
            reason = "below importance threshold"
        elif item.get("valid_until") and first_day and item["valid_until"] < first_day:
            reason = "plan already expired at recording time"
        elif (item["key"], normalize(item["content"])) in seen:
            reason = "duplicate within batch"
        if reason:
            result.dropped.append((item, reason))
            continue
        if item["attribution"] == "user_stated" and not any(q in info["user"] for info, q in cited):
            item["attribution"] = "inferred"
            item["downgraded"] = "no evidence quote from the user's own voice"
        if item["temporal"] == "stable":
            item["valid_until"] = None
        seen.add((item["key"], normalize(item["content"])))
        item["status"] = initial_status(item)
        source_ids = list(dict.fromkeys(e["record_id"] for e in item["evidence"]))
        item["observed_at"] = max(by_id[s]["start"] for s in source_ids)
        item["source_ids"] = source_ids
        result.accepted.append(item)
    return result


def extract(record, provider, **kwargs):
    return extract_batch([record], provider, **kwargs)
