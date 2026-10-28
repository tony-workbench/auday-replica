"""Run the replica end to end on the phone's own audio and compare it with what Auday produced.

  python scripts/compare_full_day.py --audio <dir> --phone <dir> --data <new data dir> --key-env <file.env>
      [--reflection 16:07] [--day 2026-10-27T16:07] [--redo]

<audio>  the Auday Skill's audio folder (CAF fragments with .asset.json next to each)
<phone>  synced records, one <kind>.jsonl per kind (see compare_with_phone.py --pull)
<data>   a NEW replica data directory for this run (never your everyday data/)

Steps: import every fragment at its recorded start time, transcribe with SenseVoice, enrol the
voiceprint from the snippets Auday itself labelled as the owner, process every hour in Auday mode
with Gemini, run the daily pass, then print, for both, each hour's snippets, owner labels,
Highlights and memory candidates, and the daily memories. The terminal output contains Highlight titles
and memory text, so treat it as private; nothing private is written outside <data>.
Uses the Gemini key from --key-env (never printed).
"""

import argparse
import json
import sys
from collections import defaultdict
from datetime import datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from app import transcribe                                # noqa: E402
from app.core import App                                  # noqa: E402
from memengine.llm import GeminiProvider                  # noqa: E402
from scripts.replay_capture import read_key               # noqa: E402


def load(phone, kind):
    path = Path(phone) / f"{kind}.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()] if path.exists() else []


def import_audio(app, audio_dir):
    assets = []
    for meta_path in sorted(Path(audio_dir).glob("*.asset.json")):
        meta = json.loads(meta_path.read_text())
        meta = meta.get("asset", meta)
        caf = meta_path.with_name(meta_path.name.replace(".asset.json", ".caf"))
        if caf.exists():
            assets.append((meta["start"], meta.get("sessionID"), caf))
    out = []
    for start, session, caf in sorted(assets):
        asset = app.save_audio(caf.read_bytes(), start, suffix=".caf", session=session, fragment=caf.stem[:32])
        out.append(asset["id"])
    return out


def enrol_from_phone(app, phone, audio_ids):
    """Enrol from snippets Auday labelled 'owner' (clean Me), cut from the imported audio."""
    owners = [t for t in load(phone, "transcript") if (t["payload"].get("speaker") or {}).get("attribution") == "owner"
              and len(t["text"].strip(" .。，,")) >= 4
              and (datetime.fromisoformat(t["end"]) - datetime.fromisoformat(t["start"])).total_seconds() >= 3]
    clips = []
    for asset_id in audio_ids:
        asset = app.asset(asset_id)
        begin = datetime.fromisoformat(asset["start"])
        audio = transcribe.read_wav(app.audio_path(asset_id))
        for t in owners:
            a, b = datetime.fromisoformat(t["start"]), datetime.fromisoformat(t["end"])
            offset = (a - begin).total_seconds()
            if 0 <= offset and (b - begin).total_seconds() <= asset["duration"] and not asset.get("timeline"):
                clips.append(audio[int(offset * transcribe.SR):int((b - begin).total_seconds() * transcribe.SR)])
    if not clips:
        return 0.0
    import numpy as np
    import wave
    joined = np.concatenate(clips)
    path = Path(app.data) / "enrol-from-phone.wav"
    with wave.open(str(path), "wb") as out:
        out.setnchannels(1); out.setsampwidth(2); out.setframerate(transcribe.SR)
        out.writeframes((joined * 32767).astype("int16").tobytes())
    app.enroll_voice(path.read_bytes(), ".wav")
    return len(joined) / transcribe.SR


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", required=True)
    parser.add_argument("--phone", required=True)
    parser.add_argument("--data", required=True)
    parser.add_argument("--key-env", required=True)
    parser.add_argument("--model", default="gemini-3.8-flash")
    parser.add_argument("--reflection", default="16:07")
    parser.add_argument("--day", help="run the daily pass as of this local time, e.g. 2026-10-27T16:30")
    parser.add_argument("--redo", action="store_true",
                        help="keep the transcripts, re-enrol and relabel voices, and redo every AI step")
    args = parser.parse_args()

    app = App(args.data, provider=GeminiProvider(model=args.model, api_key=read_key(args.key_env), temperature=None))
    app.update_settings({"pipeline": "auday", "auto_transcribe": False, "auto_hourly": False,
                         "reflection_time": args.reflection, "omit_silence": False})
    if args.redo:
        with app.db:
            for table in ("memories", "memory_vectors", "memory_events", "memory_versions", "reviews", "days", "hours", "processed_records",
                          "auday_promotions"):
                try:
                    app.db.execute(f"DELETE FROM {table}")
                except Exception:
                    pass
            for kind in ("summary", "highlight", "reflection"):
                ids = [r[0] for r in app.db.execute("SELECT id FROM records WHERE kind=?", (kind,))]
                app.db.execute("DELETE FROM records WHERE kind=?", (kind,))
                app.db.executemany("DELETE FROM chunks WHERE record_id=?", [(i,) for i in ids])
        ids = [a for (a,) in app.db.execute("SELECT id FROM assets ORDER BY id")]
        print(f"voiceprint re-enrolled from {enrol_from_phone(app, args.phone, ids):.0f} s", file=sys.stderr)
        print(f"relabelled: {app.relabel_voices()}", file=sys.stderr)
    if not app.records("transcript"):
        ids = import_audio(app, args.audio)
        print(f"imported {len(ids)} fragments", file=sys.stderr)
        seconds = enrol_from_phone(app, args.phone, ids)
        print(f"voiceprint enrolled from {seconds:.0f} s of Auday-labelled owner speech", file=sys.stderr)
        for n, asset_id in enumerate(ids, 1):
            app.run_transcribe(asset_id)
            print(f"transcribed {n}/{len(ids)}", file=sys.stderr)
    hours = sorted({(r["start"][:10], int(r["start"][11:13])) for r in app.records("transcript")})
    for date, hour in hours:
        if not app.store.record(f"summary-{date}T{hour:02d}"):
            app.process_hour(date, hour)
            print(f"processed {date} {hour:02d}:00", file=sys.stderr)
    if args.day:
        app.process_day(datetime.fromisoformat(args.day).astimezone())

    phone_by_hour = defaultdict(lambda: {"snippets": 0, "owner": 0, "mixed": 0, "highlights": [], "candidates": []})
    for t in load(args.phone, "transcript"):
        h = phone_by_hour[t["start"][:13]]
        h["snippets"] += 1
        who = (t["payload"].get("speaker") or {}).get("attribution")
        h["owner"] += who == "owner"
        h["mixed"] += who == "contains-owner"
    for x in load(args.phone, "highlight"):
        phone_by_hour[x["start"][:13]]["highlights"].append(x["title"])
    for x in load(args.phone, "summary"):
        if x["state"] == "saved":
            phone_by_hour[x["start"][:13]]["candidates"] = [m["text"] for m in x["payload"].get("memoryPoints", [])]

    print("\n# Replica vs Auday, hour by hour")
    for date, hour in hours:
        key = f"{date}T{hour:02d}"
        segs = [s for r in app.records("transcript", date, hour) for s in r.get("segments", [])]
        summary = app.store.record(f"summary-{key}") or {}
        mine = {"snippets": len(segs), "owner": sum(s.get("owner") == "Me" for s in segs),
                "mixed": sum(s.get("owner") == "Me*" for s in segs),
                "highlights": [h["title"] for h in app.records("highlight", date, hour)],
                "candidates": [m["text"] for m in summary.get("memoryPoints", [])]}
        theirs = phone_by_hour[key]
        print(f"\n## {key}:00")
        for label, side in (("Auday  ", theirs), ("Replica", mine)):
            print(f"  {label} snippets {side['snippets']:3d}  Me {side['owner']:2d}  Me* {side['mixed']:2d}  "
                  f"Highlights {len(side['highlights'])}  candidates {len(side['candidates'])}")
            for title in side["highlights"]:
                print(f"     H: {title[:90]}")
            for text in side["candidates"]:
                print(f"     M: {text[:90]}")
    print("\n# Memories")
    for m in load(args.phone, "memory"):
        print(f"  Auday   {m['payload']['state']:10s} {m['payload']['text'][:90]}")
    for m in app.store.all():
        print(f"  Replica {m.status:10s} {m.content[:90]}")
    print("\nusage:", app.usage.as_dict())


if __name__ == "__main__":
    main()
