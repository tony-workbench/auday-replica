"""Incremental processing: each transcript record revision is processed exactly once.

Only `transcript` records feed extraction. Highlights, summaries and reflections are
AI interpretations (auday.ai/faq: "A summary is AI's interpretation"), so they are
stored for context but never become memory evidence (our policy).
"""

from dataclasses import dataclass, field

import jsonschema

from .consolidate import consolidate
from .extract import extract_batch
from .llm import Usage


@dataclass
class RecordReport:
    record_id: str
    extracted: int = 0
    accepted: list = field(default_factory=list)
    dropped: list = field(default_factory=list)
    decisions: list = field(default_factory=list)
    skipped_existing: bool = False
    error: str = None


class MemoryEngine:
    def __init__(self, store, provider, *, user_labels=("user", "me", "USER")):
        self.store, self.provider, self.user_labels = store, provider, user_labels
        self.usage = Usage()

    def ingest(self, record):
        self.store.put_record(record)
        report = RecordReport(record["id"])
        revision = record.get("revision", 1)
        if record["kind"] != "transcript":
            return report
        if self.store.is_processed(record["id"], revision):
            report.skipped_existing = True
            return report
        try:
            result = extract_batch([record], self.provider, user_labels=self.user_labels, usage=self.usage)
        except (ValueError, jsonschema.ValidationError) as error:
            # Unusable model output: write nothing, leave the record unprocessed for a retry.
            report.error = f"extraction failed: {str(error)[:200]}"
            return report
        report.extracted = len(result.accepted)
        report.accepted = [item["content"] for item in result.accepted]
        report.dropped = [(item.get("content"), reason) for item, reason in result.dropped]
        for item in result.accepted:
            report.decisions.append(consolidate(self.store, item, self.provider, self.usage))
        self.store.mark_processed(record["id"], revision)
        return report

    def ingest_batch(self, records):
        """One extraction call for a group of transcripts (e.g. one hour)."""
        for record in records:
            self.store.put_record(record)
        todo = [r for r in records if r["kind"] == "transcript"
                and not self.store.is_processed(r["id"], r.get("revision", 1))]
        report = RecordReport(",".join(r["id"] for r in todo))
        if not todo:
            report.skipped_existing = True
            return report
        try:
            result = extract_batch(todo, self.provider, user_labels=self.user_labels, usage=self.usage)
        except (ValueError, jsonschema.ValidationError) as error:
            report.error = f"extraction failed: {str(error)[:200]}"
            return report
        report.extracted = len(result.accepted)
        report.accepted = [item["content"] for item in result.accepted]
        report.dropped = [(item.get("content"), reason) for item, reason in result.dropped]
        for item in result.accepted:
            report.decisions.append(consolidate(self.store, item, self.provider, self.usage))
        for record in todo:
            self.store.mark_processed(record["id"], record.get("revision", 1))
        return report

    def ingest_all(self, records):
        ordered = sorted(records, key=lambda r: (r.get("start") or "", r["id"]))
        return [self.ingest(record) for record in ordered]
