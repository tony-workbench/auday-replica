"""One page that shows how a day's speech became memories, step by step.

  python scripts/lineage_report.py --phone <dir> [--captures <dir>] --out report.html
  python scripts/lineage_report.py --data <replica data dir> --out report.html

Reads Auday-shaped records: a phone sync (<kind>.jsonl, see compare_with_phone.py) or the
replica's own data. With --captures (proxy logs from cloud/capture-worker) it also shows the daily
review's kind and ownership for every candidate, which the phone does not keep.

For each hour: snippets -> owner-labelled snippets -> Highlights -> memory candidates. For each
candidate: daily review (kind, ownership) -> local filter -> memory state. The page contains
private transcript-derived text: write it outside the repository and do not publish it.
"""

import argparse
import glob
import html
import json
import os
import re
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from scripts.compare_with_phone import load_phone, load_replica   # noqa: E402

REVIEWABLE = ("attribute", "state", "majorChange")


def reviews(directory):
    """Captured daily memory reviews: {(day, candidate text): {"kind", "ownership", "text"}}."""
    out = {}
    for path in sorted(glob.glob(os.path.join(directory, "*.json"))):
        entry = json.load(open(path))
        try:
            user = json.loads(entry["body"])["messages"][1]["content"]
            answer = json.loads(json.loads(entry["response"]["body"])["choices"][0]["message"]["content"])
        except (KeyError, ValueError, TypeError, IndexError):
            continue
        found = re.search(r"<daily_memory_candidates>\s*(.*?)\s*</daily_memory_candidates>", user, re.S)
        if not found:
            continue
        candidates = {c["id"]: c for c in json.loads(found.group(1))["candidates"]}
        chosen = {}
        for item in answer.get("memories", []):
            for cid in item.get("candidateIDs", []):
                chosen.setdefault(cid, item)
        for cid, candidate in candidates.items():
            item = chosen.get(cid)
            out[candidate["text"]] = ({"kind": item["kind"], "ownership": item["ownership"], "text": item["text"],
                                       "mid": cid} if item else {"kind": None, "mid": cid})
    return out


def build(records, review):
    by_kind = defaultdict(list)
    for r in records:
        by_kind[r["kind"]].append(r)
    memories = {r["payload"]["id"]: r for r in by_kind["memory"]}
    hours = {}
    for t in by_kind["transcript"]:
        hour = hours.setdefault(t["start"][:13], {"snippets": 0, "owner": 0, "mixed": 0, "highlights": [],
                                                    "candidates": [], "short": ""})
        hour["snippets"] += 1
        who = ((t["payload"].get("speaker") or {}).get("attribution"))
        hour["owner"] += who == "owner"
        hour["mixed"] += who == "contains-owner"
    for h in by_kind["highlight"]:
        hours.setdefault(h["start"][:13], {"snippets": 0, "owner": 0, "mixed": 0, "highlights": [],
                                           "candidates": [], "short": ""})["highlights"].append(h["title"])
    for s in by_kind["summary"]:
        hour = hours.setdefault(s["start"][:13], {"snippets": 0, "owner": 0, "mixed": 0, "highlights": [],
                                                  "candidates": [], "short": ""})
        if s["state"] == "saved-overview":
            hour["short"] = s["payload"].get("shortNote", "")
            hour["density"] = s["payload"].get("informationDensity")
            continue
        for point in s["payload"].get("memoryPoints", []):
            memory = memories.get(point.get("id"))
            seen = review.get(point["text"])
            if seen and seen.get("kind"):
                kept = seen["kind"] in REVIEWABLE and seen["ownership"] == "clear"
                verdict = "kept" if kept else ("dropped: " + ("not lasting" if seen["kind"] not in REVIEWABLE
                                                              else "ownership unclear"))
            elif seen:
                verdict = "not selected by the review"
            else:
                verdict = "promoted" if memory else ("no review captured" if review else "not promoted")
            hour["candidates"].append({
                "text": point["text"], "topic": point.get("topic", ""), "stable": point.get("isStableCandidate"),
                "sources": len(point.get("sources", [])), "review": seen, "verdict": verdict,
                "memory": memory and {"state": memory["state"], "text": memory["text"], "topic": memory["title"]}})
    return dict(sorted(hours.items())), by_kind


CSS = """
:root { --bg:#f6f7f5; --surface:#fff; --ink:#1c211e; --muted:#5f6a64; --line:#dde2de; --keep:#2f6f5a;
  --drop:#a4472f; --warn:#9a6d12; --soft:#eef2ef; --mono: ui-monospace, Menlo, monospace;
  --body: -apple-system, "PingFang SC", "Noto Sans SC", system-ui, sans-serif; }
@media (prefers-color-scheme: dark) { :root { --bg:#121513; --surface:#1a1f1c; --ink:#e4eae6; --muted:#9aa7a0;
  --line:#2b332e; --keep:#7cc4a8; --drop:#e58e74; --warn:#e0b45a; --soft:#202723; color-scheme: dark; } }
* { box-sizing: border-box; }
body { margin:0; background:var(--bg); color:var(--ink); font:15px/1.55 var(--body); padding:24px 16px 64px; }
main { max-width: 1080px; margin: 0 auto; display: grid; gap: 28px; }
h1 { margin:0; font-size:1.5rem; } h2 { margin:0 0 10px; font-size:1.1rem; }
.lede, .muted { color: var(--muted); } .mono { font-family: var(--mono); font-size: .8rem; }
.flow { display:flex; flex-wrap:wrap; gap:6px; align-items:center; color:var(--muted); font-size:.9rem; }
.flow b { color: var(--ink); background: var(--surface); border:1px solid var(--line); border-radius:6px; padding:2px 8px; }
table { width:100%; border-collapse: collapse; background: var(--surface); border:1px solid var(--line); border-radius:10px; overflow:hidden; }
th, td { text-align:left; vertical-align: top; padding: 9px 10px; border-bottom: 1px solid var(--line); }
th { font-size:.78rem; letter-spacing:.04em; color: var(--muted); font-weight:600; background: var(--soft); }
td.num { font-variant-numeric: tabular-nums; text-align: right; white-space: nowrap; }
.wrap { overflow-x: auto; }
.tag { font-family: var(--mono); font-size:.72rem; padding:1px 7px; border-radius:99px; border:1px solid currentColor; white-space:nowrap; }
.keep { color: var(--keep); } .drop { color: var(--drop); } .warn { color: var(--warn); }
.bar { height: 8px; background: var(--soft); border-radius: 4px; position: relative; min-width: 80px; }
.bar i { position:absolute; inset:0 auto 0 0; background: var(--keep); border-radius: 4px; }
.cards { display:grid; gap:10px; }
.card { background:var(--surface); border:1px solid var(--line); border-radius:10px; padding:12px 14px;
  display:grid; grid-template-columns: repeat(4, minmax(0,1fr)); gap: 12px; }
.card > div { min-width:0; } .step { font-size:.72rem; color:var(--muted); letter-spacing:.05em; margin-bottom:3px; }
@media (max-width: 760px) { .card { grid-template-columns: 1fr; } }
"""


def esc(value):
    return html.escape(str(value if value is not None else ""))


def render(hours, by_kind, title):
    total = defaultdict(int)
    for hour in hours.values():
        total["snippets"] += hour["snippets"]
        total["owner"] += hour["owner"] + hour["mixed"]
        total["highlights"] += len(hour["highlights"])
        total["candidates"] += len(hour["candidates"])
        total["memories"] += sum(1 for c in hour["candidates"] if c["memory"])
    peak = max((h["snippets"] for h in hours.values()), default=1) or 1
    rows = []
    for key, hour in hours.items():
        rows.append(
            f"<tr><td class='mono'>{esc(key[5:].replace('T', ' '))}:00</td>"
            f"<td><div class='bar'><i style='width:{100 * hour['snippets'] / peak:.0f}%'></i></div></td>"
            f"<td class='num'>{hour['snippets']}</td><td class='num'>{hour['owner']} + {hour['mixed']}*</td>"
            f"<td class='num'>{len(hour['highlights'])}</td><td class='num'>{len(hour['candidates'])}</td>"
            f"<td class='num'>{sum(1 for c in hour['candidates'] if c['memory'])}</td>"
            f"<td class='num'>{esc(hour.get('density', ''))}</td><td>{esc(hour['short'][:140])}</td></tr>")
    cards = []
    for key, hour in hours.items():
        for c in hour["candidates"]:
            r = c["review"] or {}
            cls = "keep" if c["memory"] else "drop"
            review = (f"<span class='tag {'keep' if r.get('kind') in REVIEWABLE else 'drop'}'>{esc(r.get('kind'))}</span> "
                      f"<span class='tag {'keep' if r.get('ownership') == 'clear' else 'warn'}'>{esc(r.get('ownership'))}</span>"
                      f"<div class='muted mono'>{esc(r.get('mid'))}</div>") if r.get("kind") else \
                     f"<span class='muted'>{'not selected' if r else 'not captured'}</span>"
            memory = (f"<span class='tag keep'>{esc(c['memory']['state'])}</span><div>{esc(c['memory']['text'])}</div>"
                      f"<div class='muted'>{esc(c['memory']['topic'])}</div>") if c["memory"] else "<span class='muted'>—</span>"
            cards.append(
                f"<div class='card'><div><div class='step'>1 · HOURLY CANDIDATE · {esc(key[11:13])}:00</div>"
                f"<div>{esc(c['text'])}</div><div class='muted'>{esc(c['topic'])} · "
                f"{'stable' if c['stable'] else 'not stable'}</div></div>"
                f"<div><div class='step'>2 · DAILY REVIEW</div>{review}</div>"
                f"<div><div class='step'>3 · LOCAL FILTER</div><span class='tag {cls}'>{esc(c['verdict'])}</span></div>"
                f"<div><div class='step'>4 · MEMORY · sources {c['sources']} snippets</div>{memory}</div></div>")
    return f"""<!doctype html><html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>{esc(title)}</title><style>{CSS}</style></head>
<body><main>
<header><h1>{esc(title)}</h1><p class="lede">From speech to memory, one step at a time. Private: generated from your own recordings.</p></header>
<section><div class="flow"><b>{total['snippets']} snippets</b>→<b>{total['owner']} labelled as you</b>→
<b>{total['highlights']} Highlights</b>→<b>{total['candidates']} memory candidates</b>→<b>{total['memories']} memories</b></div></section>
<section><h2>Each hour</h2><div class="wrap"><table><thead><tr><th>Hour</th><th>Transcript</th><th>Snippets</th>
<th>Me + Me*</th><th>Highlights</th><th>Candidates</th><th>Memories</th><th>Density</th><th>Short note</th></tr></thead>
<tbody>{''.join(rows)}</tbody></table></div></section>
<section><h2>Each candidate</h2><div class="cards">{''.join(cards) or "<p class='muted'>No memory candidates.</p>"}</div></section>
<p class="muted">Generated {esc(datetime.now().strftime('%Y-%m-%d %H:%M'))} by scripts/lineage_report.py</p>
</main></body></html>"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--phone", type=Path)
    parser.add_argument("--data")
    parser.add_argument("--captures")
    parser.add_argument("--out", required=True)
    parser.add_argument("--title", default="Memory lineage")
    args = parser.parse_args()
    if not (args.phone or args.data):
        parser.error("give --phone or --data")
    records = load_phone(args.phone) if args.phone else load_replica(args.data)
    hours, by_kind = build(records, reviews(args.captures) if args.captures else {})
    Path(args.out).write_text(render(hours, by_kind, args.title))
    print(args.out)


if __name__ == "__main__":
    main()
