"""Compare the replica's records with what the official Auday Skill synced from a real phone.

  python scripts/compare_with_phone.py --phone <dir> --data <replica data dir>
  python scripts/compare_with_phone.py --phone <dir> --pull <path to the Skill's bootstrap.sh>

<dir> holds one <kind>.jsonl per record kind (transcript, summary, highlight, reflection, memory),
one record per line, as the Skill's `search --kind <kind>` returns them; --pull fills it by paging
through `search`. Only field names, states and counts are printed, never record text, so the
output is safe to paste into an issue. Synced records are private: keep <dir> outside the repo.
"""

import argparse
import json
import subprocess
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

KINDS = ("transcript", "summary", "highlight", "reflection", "memory")


def pull(bootstrap, directory):
    directory.mkdir(parents=True, exist_ok=True)
    for kind in KINDS:
        rows, offset = [], 0
        while True:
            out = subprocess.run(["/bin/sh", bootstrap, "search", "--kind", kind, "--limit", "100",
                                  "--offset", str(offset)], capture_output=True, text=True, check=True).stdout
            page = json.loads(out).get("records", [])
            rows += page
            if len(page) < 100:
                break
            offset += 100
        (directory / f"{kind}.jsonl").write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))
        print(f"pulled {kind}: {len(rows)}", file=sys.stderr)


def load_phone(directory):
    out = []
    for kind in KINDS:
        path = directory / f"{kind}.jsonl"
        if path.exists():
            out += [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    return out


def load_replica(data_dir):
    from app import auday_export
    from app.core import App
    return auday_export.library(App(data_dir))


def shape(records):
    """kind -> state -> (record keys, payload keys, count)."""
    out = {}
    for r in records:
        slot = out.setdefault(r["kind"], {}).setdefault(r.get("state"), [Counter(), Counter(), 0])
        slot[0].update(r.keys())
        slot[1].update((r.get("payload") or {}).keys())
        slot[2] += 1
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--phone", required=True, type=Path)
    parser.add_argument("--data", help="replica data directory")
    parser.add_argument("--pull", help="the Auday Skill's scripts/bootstrap.sh; refreshes --phone first")
    args = parser.parse_args()
    if args.pull:
        pull(args.pull, args.phone)
    phone = shape(load_phone(args.phone))
    replica = shape(load_replica(args.data)) if args.data else {}
    for kind in KINDS:
        print(f"\n== {kind}")
        states = sorted(set(phone.get(kind, {})) | set(replica.get(kind, {})), key=str)
        for state in states:
            p = phone.get(kind, {}).get(state)
            q = replica.get(kind, {}).get(state)
            print(f"  state {state!r}: phone {p[2] if p else 0}, replica {q[2] if q else 0}")
            if p and q:
                for label, a, b in (("record", p[0], q[0]), ("payload", p[1], q[1])):
                    missing, extra = sorted(set(a) - set(b)), sorted(set(b) - set(a))
                    if missing:
                        print(f"    {label} fields only on the phone : {', '.join(missing)}")
                    if extra:
                        print(f"    {label} fields only in replica   : {', '.join(extra)}")
            elif p:
                print(f"    payload fields: {', '.join(sorted(p[1]))}")


if __name__ == "__main__":
    main()
