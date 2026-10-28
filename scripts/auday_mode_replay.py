"""Run the replica's Auday mode on the exact inputs Auday sent, and compare with Auday's answers.

  python scripts/auday_mode_replay.py --captures <dir> --key-env <file.env> [--hours 14 15] [--runs 2]

<dir> holds proxy log entries (cloud/capture-worker). For each requested hour we take Auday's own
snippets, scope and profile from its Highlight-selection request, run our three hourly stages,
and print a side-by-side of Highlight titles and memoryPoints. The day's review is replayed from
Auday's own candidates; with --hours, add "review" to include it. Uses the Gemini key in --key-env
(never printed). Captured data is private, so this script only prints and writes no files.
"""

import argparse
import glob
import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from app import auday_mode                                 # noqa: E402
from memengine.llm import GeminiProvider, Usage            # noqa: E402
from replay_capture import read_key                        # noqa: E402  (same folder)


def entries(directory):
    for path in sorted(glob.glob(os.path.join(directory, "*.json"))):
        entry = json.load(open(path))
        try:
            body = json.loads(entry["body"])
            answer = json.loads(json.loads(entry["response"]["body"])["choices"][0]["message"]["content"])
        except (KeyError, ValueError, TypeError):
            continue
        system, user = body["messages"][0]["content"], body["messages"][1]["content"]
        yield system, user, answer


def tag(text, name):
    found = re.search(rf"<{name}>\s*(.*?)\s*</{name}>", text, re.S)
    return found.group(1) if found else None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--captures", required=True)
    parser.add_argument("--key-env", required=True)
    parser.add_argument("--hours", nargs="*", default=None)
    parser.add_argument("--runs", type=int, default=1)
    parser.add_argument("--model", default="gemini-3.8-flash")
    args = parser.parse_args()

    provider = GeminiProvider(model=args.model, api_key=read_key(args.key_env), temperature=None)
    usage = Usage()
    captured = list(entries(args.captures))
    hours = {}
    for system, user, answer in captured:
        scope = tag(user, "hour_scope_data")
        if not scope:
            continue
        hour = json.loads(scope)["start"][11:13]
        slot = hours.setdefault(hour, {"scope": json.loads(scope)})
        if "hour_highlight_selection_request" in user:
            slot["snippets"] = json.loads(tag(user, "recorded_data"))
            slot["auday_highlights"] = answer["highlights"]
            profile = tag(tag(user, "confirmed_fact_data") or "", "confirmed_profile_data") or "[]"
            slot["profile"] = json.loads(profile.replace("<\\/", "</"))
        elif "hour_summary_request" in user:
            slot["auday_summary"] = answer

    for hour in sorted(hours):
        slot = hours[hour]
        if (args.hours and hour not in args.hours) or "snippets" not in slot or "auday_summary" not in slot:
            continue
        print(f"\n=== hour {hour}:00  ({len(slot['snippets'])} snippets, "
              f"{sum(1 for s in slot['snippets'] if s.get('me'))} marked as the owner)")
        print("  Auday highlights :", [h["title"] for h in slot["auday_highlights"]])
        print("  Auday memory     :", [m["text"] for m in slot["auday_summary"]["memoryPoints"]])
        print("  Auday density    :", slot["auday_summary"]["informationDensity"])
        for run in range(args.runs):
            result = auday_mode.process_hour(provider, slot["scope"], slot["snippets"], profile=slot["profile"],
                                             usage=usage)
            print(f"  ours #{run + 1} highlights:", [h["title"] for h in result["highlights"]])
            print(f"  ours #{run + 1} memory    :", [m["text"] for m in result["summary"]["memoryPoints"]])
            print(f"  ours #{run + 1} density   :", result["summary"]["informationDensity"])

    for system, user, answer in captured:
        payload = tag(user, "daily_memory_candidates")
        if not payload or (args.hours and "review" not in args.hours):
            continue
        data = json.loads(payload)
        hour_rows, by_text = [], {}
        for h in data["hours"]:
            hour_rows.append({"hour": h["hourStart"], "summary": h["summary"], "memoryPoints": []})
        for c in data["candidates"]:      # Auday does not say which hour a candidate came from; put all in the first hour
            hour_rows[0]["memoryPoints"].append({"text": c["text"], "topic": c["topic"]})
        print("\n=== daily memory review")
        print("  Auday:", [(m["candidateIDs"], m["kind"], m["ownership"]) for m in answer["memories"]])
        for run in range(args.runs):
            selected, _ = auday_mode.daily_memory_review(provider, hour_rows, data["summary"],
                                                         data["missingHours"], usage=usage)
            print(f"  ours #{run + 1}:", [(m["candidateIDs"], m["kind"], m["ownership"]) for m in selected])
    print("\nusage:", usage.as_dict())


if __name__ == "__main__":
    main()
