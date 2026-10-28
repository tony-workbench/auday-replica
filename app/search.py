"""Keyword + semantic search over records.

Chunking mirrors the Auday desktop skill (scripts/semantic_search.py: 900-character
chunks, 100-character overlap, float16 vectors, cosine). The embedder is pluggable;
the default is the offline HashEmbedder from memengine.
"""

import json

import numpy as np

from memengine.embed import from_blob, lexical_overlap as _lexical, to_blob

CHUNK, OVERLAP = 900, 100

DDL = """
CREATE TABLE IF NOT EXISTS chunks(
  record_id TEXT, ordinal INTEGER, kind TEXT, date TEXT, text TEXT, model TEXT, vector BLOB,
  PRIMARY KEY(record_id, ordinal));
"""


def chunks(text):
    if len(text) <= CHUNK:
        return [text]
    step = CHUNK - OVERLAP
    return [text[i:i + CHUNK] for i in range(0, len(text) - OVERLAP, step)]


def index_record(db, embedder, record):
    db.execute("DELETE FROM chunks WHERE record_id=?", (record["id"],))
    parts = [p for p in chunks(record.get("text", "")) if p.strip()]
    if not parts:
        return
    vectors = embedder.embed([f"{record.get('title', '')} {p}" for p in parts])
    for ordinal, (part, vector) in enumerate(zip(parts, vectors)):
        db.execute("INSERT INTO chunks VALUES(?,?,?,?,?,?,?)",
                   (record["id"], ordinal, record["kind"], (record.get("start") or "")[:10], part,
                    embedder.name, to_blob(vector)))


def search(db, embedder, query, *, mode="hybrid", kinds=None, date=None, dates=None, date_from=None,
           date_to=None, limit=10):
    """`date` one day, `dates` several days, `date_from`/`date_to` a range (inclusive), like Auday's
    search scope."""
    sql, args = "SELECT c.record_id, c.kind, c.date, c.text, c.vector, r.body FROM chunks c " \
                "JOIN records r ON r.id = c.record_id WHERE 1=1", []
    if kinds:
        sql += f" AND c.kind IN ({','.join('?' * len(kinds))})"
        args += list(kinds)
    if date:
        sql += " AND c.date = ?"
        args.append(date)
    if dates:
        sql += f" AND c.date IN ({','.join('?' * len(dates))})"
        args += list(dates)
    if date_from:
        sql += " AND c.date >= ?"
        args.append(date_from)
    if date_to:
        sql += " AND c.date <= ?"
        args.append(date_to)
    rows = db.execute(sql, args).fetchall()
    if not rows:
        return []
    if mode == "keyword":
        needle = query.lower()
        scored = [(1.0 if needle in row[3].lower() else _lexical(query, row[3]), row) for row in rows]
        scored = [s for s in scored if s[0] >= 0.5]
    else:
        q = embedder.embed([query])[0]
        scored = []
        for row in rows:
            cos = float(np.dot(q, from_blob(row[4])))
            lex = _lexical(query, row[3])
            score = cos if mode == "semantic" else 0.55 * cos + 0.45 * lex
            scored.append((score, row))
        scored = [s for s in scored if s[0] >= 0.12]
    best = {}
    for score, row in sorted(scored, key=lambda s: -s[0]):
        if row[0] not in best:
            body = json.loads(row[5])
            best[row[0]] = {"id": row[0], "kind": row[1], "date": row[2], "score": round(score, 3),
                            "snippet": row[3][:240], "title": body.get("title"),
                            "start": body.get("start"), "record": body}
        if len(best) >= limit:
            break
    return list(best.values())
