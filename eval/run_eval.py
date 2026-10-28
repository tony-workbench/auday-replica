"""Scenario evaluation of the memory engine: run every scenario, score it against gold, write a report.

  # live provider
  python eval/run_eval.py --provider anthropic --model claude-haiku-5-5
  # replay (the default): answers come from a cassette; unanswered prompts go to eval/pending.json
  python eval/run_eval.py --provider replay --cassette eval/cassettes/blind.json
  # add answers to those pending prompts ({key: answer}) to the cassette
  python eval/run_eval.py --merge-answers answers.json --cassette eval/cassettes/blind.json

Gold expectations live in eval/scenarios.json and were written before any model ran.
The summary goes to eval/report.json and the terminal, with PASS/FAIL per scenario.
"""

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from memengine import MemoryEngine, Store, llm, prompts, schema  # noqa: E402
from memengine.extract import extract, normalize  # noqa: E402

SYSTEM_NAMES = {prompts.EXTRACTION_SYSTEM: "extraction", prompts.CONSOLIDATION_SYSTEM: "consolidation"}


def build_record(session):
    record = {"id": session["id"], "kind": session.get("kind", "transcript"),
              "start": session["start"], "timeZone": "Asia/Shanghai", "status": "saved",
              "sourceIDs": session.get("sourceIDs", []), "revision": 1}
    if "segments" in session:
        record["segments"] = session["segments"]
        record["text"] = "\n".join(s["text"] for s in session["segments"])
    else:
        record["text"] = session["text"]
    return record


def matches(pattern, text):
    return re.search(pattern.replace("(?i)", ""), text, re.I) is not None


def run_scenario(scenario, provider):
    store = Store()
    for seed in scenario.get("seed", []):
        store.add(actor="seed", op="SEED", reason="scenario seed", **seed)
    engine = MemoryEngine(store, provider)
    trace = {"extractions": {}, "decisions": [], "complete": True}
    for session in scenario["sessions"]:
        record = build_record(session)
        try:
            report = engine.ingest(record)
        except llm.PendingResponse:
            trace["complete"] = False
            break
        if report.error:
            trace.setdefault("errors", []).append({"record": record["id"], "error": report.error})
        if record["kind"] == "transcript":
            trace["extractions"][record["id"]] = {"accepted": report.accepted, "dropped": report.dropped}
        for decision in report.decisions:
            trace["decisions"].append({"record": record["id"], "op": decision.operation,
                                       "proposed": decision.proposed, "guard": decision.guard,
                                       "memory_id": decision.memory_id, "target_id": decision.target_id})
    if trace["complete"] and scenario.get("lifecycle_at"):
        store.expire(scenario["lifecycle_at"])
    return store, engine.usage, trace


def score(scenario, store, trace):
    gold = scenario["gold"]
    out = {"checks": [], "required": 0, "found": 0, "accepted": 0, "matched": 0,
           "false_extractions": 0, "unexpected": [], "dup_violations": 0, "dup_checks": 0,
           "trace_ok": 0, "trace_total": 0}
    for record_id, spec in gold.get("extract", {}).items():
        items = trace["extractions"].get(record_id, {}).get("accepted", [])
        ok_patterns = spec.get("required", []) + spec.get("allowed", [])
        for pattern in spec.get("required", []):
            out["required"] += 1
            out["found"] += any(matches(pattern, c or "") for c in items)
        for content in items:
            out["accepted"] += 1
            if any(matches(p, content) for p in spec.get("forbidden", [])):
                out["false_extractions"] += 1
            elif any(matches(p, content) for p in ok_patterns):
                out["matched"] += 1
            else:
                out["unexpected"].append(content)
    memories = store.all()
    for check in gold.get("final", []):
        hits = [m for m in memories if m.status in check["status_in"] and matches(check["pattern"], m.content)]
        ok = len(hits) >= check.get("min", 0) and len(hits) <= check.get("max", 10 ** 6)
        if check.get("valid_until"):
            ok = ok and all(m.valid_until for m in hits)
        if check.get("dup_check"):
            out["dup_checks"] += 1
            out["dup_violations"] += len(hits) > 1
        out["checks"].append({"pattern": check["pattern"], "status_in": check["status_in"],
                              "count": len(hits), "ok": ok,
                              "hits": [f"{m.id}[{m.status}] {m.content}" for m in hits]})
    for check in gold.get("cite", []):
        hits = [m for m in memories if m.status in schema.ACTIVE and matches(check["pattern"], m.content)]
        ok = bool(hits) and all(set(check["records"]) <= set(m.source_ids) for m in hits)
        out["checks"].append({"cite": check["records"], "pattern": check["pattern"], "ok": ok,
                              "hits": [f"{m.id} {m.source_ids}" for m in hits]})
    # Provenance: every evidence quote must appear verbatim in a record the memory cites.
    # Quotes from seed records that were never ingested are skipped.
    for memory in memories:
        for evidence in memory.evidence:
            record = store.record(evidence["record_id"])
            if record is None and evidence["record_id"].startswith(("seed-", "transcript-0")):
                continue
            out["trace_total"] += 1
            quote = normalize(re.sub(r"^\[[^\]]+\]\s*", "", evidence["quote"])).strip("，。！？、,.!?;；:：\"' ")
            out["trace_ok"] += bool(record and evidence["record_id"] in memory.source_ids
                                    and quote in normalize(record.get("text", "")))
    return out


def precollect(scenarios, provider):
    """Extraction does not depend on store state, so collect every missing extraction prompt
    up front; one pending file can then cover them all, not only the first per scenario."""
    for scenario in scenarios:
        for session in scenario["sessions"]:
            record = build_record(session)
            if record["kind"] == "transcript":
                try:
                    extract(record, provider)
                except llm.PendingResponse:
                    pass


def write_pending(pending, path):
    requests = [{"key": key, "type": SYSTEM_NAMES[p["system"]], "user": p["user"]}
                for key, p in pending.items()]
    path.write_text(json.dumps({"prompt_version": prompts.PROMPT_VERSION,
                                "systems": {"extraction": prompts.EXTRACTION_SYSTEM,
                                            "consolidation": prompts.CONSOLIDATION_SYSTEM},
                                "requests": requests}, ensure_ascii=False, indent=1))


def merge_answers(answers_path, cassette_path):
    cassette = json.loads(cassette_path.read_text()) if cassette_path.exists() else {}
    answers = json.loads(Path(answers_path).read_text())
    for key, value in answers.items():
        cassette[key] = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
    cassette_path.parent.mkdir(parents=True, exist_ok=True)
    cassette_path.write_text(json.dumps(cassette, ensure_ascii=False, indent=1))
    print(f"cassette now has {len(cassette)} answers")


def provider_from(args, pending):
    if args.provider == "replay":
        return llm.ReplayProvider(str(args.cassette), pending)
    from memengine.cli import provider_from as live
    return live(args)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--provider", default="replay")
    parser.add_argument("--model")
    parser.add_argument("--base-url", default="https://api.openai.com/v1")
    parser.add_argument("--system-prefix", default="", help='e.g. "/no_think\\n" for SmolLM3/Qwen3')
    parser.add_argument("--cassette", type=Path, default=ROOT / "eval/cassettes/blind.json")
    parser.add_argument("--pending", type=Path, default=ROOT / "eval/pending.json")
    parser.add_argument("--report", type=Path, default=ROOT / "eval/report.json")
    parser.add_argument("--only")
    parser.add_argument("--merge-answers")
    args = parser.parse_args()
    if args.merge_answers:
        return merge_answers(args.merge_answers, args.cassette)

    scenarios = json.loads((ROOT / "eval/scenarios.json").read_text())
    if args.only:
        scenarios = [s for s in scenarios if re.search(args.only, s["id"])]
    pending = {}
    provider = provider_from(args, pending)
    if args.provider == "replay":
        precollect(scenarios, provider)

    results, totals, usage_total = [], Counter(), llm.Usage()
    for scenario in scenarios:
        store, usage, trace = run_scenario(scenario, provider)
        usage_total.calls += usage.calls
        usage_total.input_tokens += usage.input_tokens
        usage_total.output_tokens += usage.output_tokens
        usage_total.estimated |= usage.estimated
        if not trace["complete"]:
            results.append({"id": scenario["id"], "complete": False})
            continue
        result = score(scenario, store, trace)
        result.update(id=scenario["id"], covers=scenario["covers"], complete=True,
                      decisions=trace["decisions"], errors=trace.get("errors", []),
                      dropped={k: v["dropped"] for k, v in trace["extractions"].items() if v["dropped"]},
                      usage=usage.as_dict(),
                      final=[f"{m.id}[{m.status}] {m.key}: {m.content} <- {m.source_ids}" for m in store.all()])
        results.append(result)
        for name in ("required", "found", "accepted", "matched", "false_extractions",
                     "dup_violations", "dup_checks", "trace_ok", "trace_total"):
            totals[name] += result[name]
        totals["checks"] += len(result["checks"])
        totals["checks_ok"] += sum(c["ok"] for c in result["checks"])
        totals["unexpected"] += len(result["unexpected"])
        totals["errors"] += len(trace.get("errors", []))
        totals["guarded"] += sum(1 for d in trace["decisions"] if d["guard"])
        totals["scenarios_ok"] += all(c["ok"] for c in result["checks"])

    if pending:
        write_pending(pending, args.pending)
        print(f"{len(pending)} prompts pending -> {args.pending}")
    complete = [r for r in results if r["complete"]]
    conflict_checks = [c for r in complete if {"preference_change", "conflict", "cross_session_update",
                                               "confirmed_protection", "rejected_respect",
                                               "temporary_plan", "candidate_promotion"} & set(r["covers"])
                       for c in r["checks"]]
    summary = {
        "prompt_version": prompts.PROMPT_VERSION,
        "provider": args.provider if args.provider != "replay" else f"replay:{args.cassette.name}",
        "scenarios": len(scenarios), "complete": len(complete),
        "scenarios_all_checks_pass": totals["scenarios_ok"],
        "final_state_checks": f"{totals['checks_ok']}/{totals['checks']}",
        "extraction_recall": round(totals["found"] / totals["required"], 3) if totals["required"] else None,
        "extraction_miss_rate": round(1 - totals["found"] / totals["required"], 3) if totals["required"] else None,
        "extraction_precision_vs_gold": round(totals["matched"] / totals["accepted"], 3) if totals["accepted"] else None,
        "false_extraction_rate": round(totals["false_extractions"] / totals["accepted"], 3) if totals["accepted"] else None,
        "unexpected_extractions": totals["unexpected"],
        "duplicate_rate": round(totals["dup_violations"] / totals["dup_checks"], 3) if totals["dup_checks"] else None,
        "conflict_handling_accuracy": round(sum(c["ok"] for c in conflict_checks) / len(conflict_checks), 3) if conflict_checks else None,
        "source_traceability": round(totals["trace_ok"] / totals["trace_total"], 3) if totals["trace_total"] else None,
        "guard_interventions": totals["guarded"],
        "extraction_failures": totals["errors"],
        "usage": usage_total.as_dict(),
    }
    args.report.write_text(json.dumps({"summary": summary, "scenarios": results}, ensure_ascii=False, indent=1))
    print(json.dumps(summary, ensure_ascii=False, indent=1))
    for result in complete:
        failed = [c for c in result["checks"] if not c["ok"]]
        mark = "PASS" if not failed else "FAIL"
        print(f"{mark} {result['id']}" + "".join(f"\n     x {c['pattern']} {c.get('status_in', '')} -> {c['hits']}" for c in failed))
    for result in results:
        if not result["complete"]:
            print(f"PENDING {result['id']}")


if __name__ == "__main__":
    main()
