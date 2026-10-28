"""SQLite store.

`records` mirrors the Auday desktop cache exactly (scripts/auday.py:
records(id, kind, text, date, body)), so an Auday Skill profile database can be read
as input. Everything else is our own design: versioned memories, an append-only event
log, review queue, processed-record bookkeeping and float16 vectors.
"""

import json
import sqlite3
from dataclasses import dataclass, field
from datetime import datetime, timezone

import numpy as np

from . import schema
from .embed import HashEmbedder, from_blob, to_blob

DDL = """
CREATE TABLE IF NOT EXISTS records(id TEXT PRIMARY KEY, kind TEXT, text TEXT, date TEXT, body TEXT);
CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS memories(
  id TEXT PRIMARY KEY,
  key TEXT NOT NULL,
  category TEXT NOT NULL,
  content TEXT NOT NULL,
  status TEXT NOT NULL,
  status_reason TEXT,
  attribution TEXT NOT NULL,
  certainty TEXT NOT NULL,
  temporal TEXT NOT NULL,
  importance INTEGER NOT NULL,
  valid_until TEXT,
  observed_at TEXT,
  version INTEGER NOT NULL DEFAULT 1,
  supersedes TEXT,
  superseded_by TEXT,
  source_ids TEXT NOT NULL,
  evidence TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS memories_key ON memories(key);
CREATE INDEX IF NOT EXISTS memories_status ON memories(status);
CREATE TABLE IF NOT EXISTS memory_versions(
  memory_id TEXT, version INTEGER, content TEXT, status TEXT, source_ids TEXT,
  evidence TEXT, op TEXT, reason TEXT, changed_at TEXT,
  PRIMARY KEY(memory_id, version, changed_at)
);
CREATE TABLE IF NOT EXISTS memory_events(
  seq INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT, actor TEXT, op TEXT,
  memory_id TEXT, target_id TEXT, payload TEXT
);
CREATE TABLE IF NOT EXISTS reviews(
  id INTEGER PRIMARY KEY AUTOINCREMENT, memory_id TEXT, target_id TEXT,
  reason TEXT, state TEXT DEFAULT 'open', created_at TEXT
);
CREATE TABLE IF NOT EXISTS processed_records(
  record_id TEXT, revision TEXT, processed_at TEXT, PRIMARY KEY(record_id, revision)
);
CREATE TABLE IF NOT EXISTS memory_vectors(
  memory_id TEXT PRIMARY KEY, version INTEGER, model TEXT, vector BLOB
);
"""


def utcnow():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


@dataclass
class Memory:
    id: str
    key: str
    category: str
    content: str
    status: str
    attribution: str
    certainty: str
    temporal: str
    importance: int
    source_ids: list
    evidence: list
    valid_until: str = None
    observed_at: str = None
    version: int = 1
    supersedes: str = None
    superseded_by: str = None
    status_reason: str = None
    created_at: str = None
    updated_at: str = None
    score: float = field(default=0.0, compare=False)

    @property
    def strong(self):
        return self.attribution == "user_stated" and self.certainty == "definite"


class TransitionError(ValueError):
    pass


class Store:
    def __init__(self, path=":memory:", embedder=None):
        self.db = sqlite3.connect(path, timeout=30, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        if path != ":memory:":
            self.db.execute("PRAGMA journal_mode=WAL")
        self.db.executescript(DDL)
        self.embedder = embedder or HashEmbedder()

    def close(self):
        self.db.close()

    # ---------- Auday-compatible records ----------
    def put_record(self, record):
        if record.get("kind") not in schema.KINDS:
            raise ValueError(f"unknown kind: {record.get('kind')}")
        date = (record.get("start") or "")[:10]
        with self.db:
            self.db.execute("INSERT OR REPLACE INTO records VALUES(?,?,?,?,?)",
                            (record["id"], record["kind"], record.get("text", ""), date,
                             json.dumps(record, ensure_ascii=False)))

    def record(self, record_id):
        row = self.db.execute("SELECT body FROM records WHERE id=?", (record_id,)).fetchone()
        return json.loads(row["body"]) if row else None

    def mark_processed(self, record_id, revision):
        with self.db:
            self.db.execute("INSERT OR IGNORE INTO processed_records VALUES(?,?,?)",
                            (record_id, str(revision), utcnow()))

    def is_processed(self, record_id, revision):
        return self.db.execute("SELECT 1 FROM processed_records WHERE record_id=? AND revision=?",
                               (record_id, str(revision))).fetchone() is not None

    # ---------- memories ----------
    def _row(self, row):
        data = dict(row)
        data["source_ids"] = json.loads(data["source_ids"])
        data["evidence"] = json.loads(data["evidence"])
        return Memory(**data)

    def get(self, memory_id):
        row = self.db.execute("SELECT * FROM memories WHERE id=?", (memory_id,)).fetchone()
        return self._row(row) if row else None

    def all(self, statuses=None):
        sql, args = "SELECT * FROM memories", ()
        if statuses:
            sql += f" WHERE status IN ({','.join('?' * len(statuses))})"
            args = tuple(statuses)
        return [self._row(r) for r in self.db.execute(sql + " ORDER BY id", args)]

    def _next_id(self):
        count = self.db.execute("SELECT COUNT(*) FROM memories").fetchone()[0]
        return f"mem_{count + 1:05d}"

    def _event(self, actor, op, memory_id=None, target_id=None, **payload):
        self.db.execute("INSERT INTO memory_events(ts,actor,op,memory_id,target_id,payload)"
                        " VALUES(?,?,?,?,?,?)",
                        (utcnow(), actor, op, memory_id, target_id,
                         json.dumps(payload, ensure_ascii=False)))

    def _snapshot(self, memory, op, reason):
        self.db.execute("INSERT OR REPLACE INTO memory_versions VALUES(?,?,?,?,?,?,?,?,?)",
                        (memory.id, memory.version, memory.content, memory.status,
                         json.dumps(memory.source_ids), json.dumps(memory.evidence, ensure_ascii=False),
                         op, reason, utcnow()))

    def _write(self, m):
        m.updated_at = utcnow()
        self.db.execute(
            "INSERT OR REPLACE INTO memories VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (m.id, m.key, m.category, m.content, m.status, m.status_reason, m.attribution,
             m.certainty, m.temporal, m.importance, m.valid_until, m.observed_at, m.version,
             m.supersedes, m.superseded_by, json.dumps(m.source_ids),
             json.dumps(m.evidence, ensure_ascii=False), m.created_at or m.updated_at, m.updated_at))
        vector = self.embedder.embed([f"{m.key} {m.content}"])[0]
        self.db.execute("INSERT OR REPLACE INTO memory_vectors VALUES(?,?,?,?)",
                        (m.id, m.version, self.embedder.name, to_blob(vector)))

    def add(self, *, actor="system", op="ADD", reason=None, id=None, **fields):
        with self.db:
            memory = Memory(id=id or self._next_id(), created_at=utcnow(), **fields)
            if memory.status not in schema.STATUSES:
                raise ValueError(memory.status)
            self._write(memory)
            self._snapshot(memory, op, reason)
            self._event(actor, op, memory.id, memory.supersedes, reason=reason,
                        content=memory.content, status=memory.status)
        return memory

    def transition(self, memory_id, new_status, *, actor, reason, superseded_by=None):
        memory = self.get(memory_id)
        if memory is None:
            raise KeyError(memory_id)
        allowed = schema.TRANSITIONS.get((memory.status, new_status), set())
        if actor not in allowed:
            raise TransitionError(f"{actor} cannot move {memory.status} -> {new_status}")
        if actor == "system" and new_status == schema.INACTIVE and reason != "expired":
            raise TransitionError("system may only deactivate expired memories")
        with self.db:
            old = memory.status
            memory.status, memory.status_reason = new_status, reason
            if superseded_by:
                memory.superseded_by = superseded_by
            self._write(memory)
            self._snapshot(memory, f"STATUS:{old}->{new_status}", reason)
            self._event(actor, "STATUS", memory_id, superseded_by, old=old, new=new_status,
                        reason=reason)
        return memory

    def revise(self, memory_id, *, actor, op, reason, content=None, evidence=None,
               source_ids=None, **changes):
        """New version of the same memory. Old versions stay in memory_versions."""
        memory = self.get(memory_id)
        with self.db:
            if content is not None and content != memory.content:
                memory.content = content
                memory.version += 1
            for item in evidence or []:
                if item not in memory.evidence:
                    memory.evidence.append(item)
            for sid in source_ids or []:
                if sid not in memory.source_ids:
                    memory.source_ids.append(sid)
            for name, value in changes.items():
                setattr(memory, name, value)
            self._write(memory)
            self._snapshot(memory, op, reason)
            self._event(actor, op, memory_id, None, reason=reason, content=memory.content)
        return memory

    def open_review(self, memory_id, target_id, reason):
        with self.db:
            self.db.execute("INSERT INTO reviews(memory_id,target_id,reason,created_at) VALUES(?,?,?,?)",
                            (memory_id, target_id, reason, utcnow()))

    def reviews(self, state="open"):
        return [dict(r) for r in self.db.execute("SELECT * FROM reviews WHERE state=?", (state,))]

    def versions(self, memory_id):
        return [dict(r) for r in self.db.execute(
            "SELECT * FROM memory_versions WHERE memory_id=? ORDER BY changed_at, version", (memory_id,))]

    def events(self):
        return [dict(r) for r in self.db.execute("SELECT * FROM memory_events ORDER BY seq")]

    def similar(self, text, statuses, limit=5, min_score=0.3):
        query = self.embedder.embed([text])[0]
        marks = ",".join("?" * len(statuses))
        rows = self.db.execute(
            f"SELECT m.*, v.vector FROM memories m JOIN memory_vectors v ON v.memory_id=m.id"
            f" WHERE m.status IN ({marks})", tuple(statuses)).fetchall()
        scored = []
        for row in rows:
            data = dict(row)
            score = float(np.dot(query, from_blob(data.pop("vector"))))
            if score >= min_score:
                memory = self._row(data)
                memory.score = score
                scored.append(memory)
        return sorted(scored, key=lambda m: -m.score)[:limit]

    # ---------- user actions (the "Remembered facts" screen) ----------
    def confirm(self, memory_id):
        return self.transition(memory_id, schema.CONFIRMED, actor="user", reason="user confirmed")

    def reject(self, memory_id):
        return self.transition(memory_id, schema.REJECTED, actor="user", reason="user rejected")

    def deactivate(self, memory_id):
        return self.transition(memory_id, schema.INACTIVE, actor="user", reason="user deactivated")

    def reactivate(self, memory_id):
        return self.transition(memory_id, schema.SAVED, actor="user", reason="user reactivated")

    def edit(self, memory_id, content):
        memory = self.revise(memory_id, actor="user", op="EDIT", reason="user edit", content=content,
                             attribution="user_stated", certainty="definite")
        if memory.status != schema.CONFIRMED:
            memory = self.transition(memory_id, schema.CONFIRMED, actor="user", reason="user edit")
        return memory

    def expire(self, today):
        """Deactivate open memories whose valid_until is before `today` (YYYY-MM-DD)."""
        expired = []
        for memory in self.all(schema.OPEN):
            if memory.valid_until and memory.valid_until < today:
                expired.append(self.transition(memory.id, schema.INACTIVE, actor="system",
                                               reason="expired"))
        return expired
