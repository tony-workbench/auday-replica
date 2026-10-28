"""Command-line interface to the memory engine: ingest records, review memories, build chat context.

  python -m memengine.cli --db mem.sqlite ingest library.json --provider anthropic
  python -m memengine.cli --db mem.sqlite ingest-auday ~/Library/Application\\ Support/AudayWorkflow/<profile>/library.sqlite
  python -m memengine.cli --db mem.sqlite list [--all]
  python -m memengine.cli --db mem.sqlite confirm|reject|deactivate|reactivate|history mem_00001
  python -m memengine.cli --db mem.sqlite edit mem_00001 "New wording"
  python -m memengine.cli --db mem.sqlite context "Which day do I play badminton?"
  python -m memengine.cli --db mem.sqlite expire 2026-10-24
  python -m memengine.cli --db mem.sqlite reviews
"""

import argparse
import json
import sqlite3
import sys

from . import llm, schema
from .pipeline import MemoryEngine
from .retrieve import format_context, retrieve
from .store import Store


def provider_from(args):
    if args.provider == "anthropic":
        return llm.AnthropicProvider(model=args.model or "claude-haiku-5-5")
    if args.provider == "openai":
        return llm.OpenAICompatibleProvider(model=args.model or "gpt-5-mini", base_url=args.base_url,
                                            system_prefix=getattr(args, "system_prefix", "") or "")
    if args.provider == "gemini":
        return llm.GeminiProvider(model=args.model or "gemini-2.5-flash")
    raise SystemExit(f"unknown provider {args.provider}")


def auday_records(path):
    """Read every record from an Auday Skill desktop cache; each `records.body` holds one record's full JSON."""
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        return [json.loads(body) for (body,) in db.execute("SELECT body FROM records")]
    finally:
        db.close()


def main(argv=None):
    parser = argparse.ArgumentParser(prog="memengine")
    parser.add_argument("--db", default="memory.sqlite")
    parser.add_argument("--provider", default="anthropic")
    parser.add_argument("--model")
    parser.add_argument("--base-url", default="https://api.openai.com/v1")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("ingest").add_argument("library")
    sub.add_parser("ingest-auday").add_argument("sqlite")
    sub.add_parser("list").add_argument("--all", action="store_true")
    for name in ("confirm", "reject", "deactivate", "reactivate", "history"):
        sub.add_parser(name).add_argument("memory_id")
    edit = sub.add_parser("edit")
    edit.add_argument("memory_id")
    edit.add_argument("content")
    context = sub.add_parser("context")
    context.add_argument("query")
    context.add_argument("--budget", type=int, default=400)
    sub.add_parser("expire").add_argument("today")
    sub.add_parser("reviews")
    args = parser.parse_args(argv)

    store = Store(args.db)
    if args.command in ("ingest", "ingest-auday"):
        if args.command == "ingest":
            with open(args.library, encoding="utf-8") as handle:
                data = json.load(handle)
            records = data["records"] if isinstance(data, dict) else data
        else:
            records = auday_records(args.sqlite)
        engine = MemoryEngine(store, provider_from(args))
        for report in engine.ingest_all(records):
            for decision in report.decisions:
                print(f"{report.record_id}: {decision.operation} {decision.memory_id}"
                      f"{' (guard: ' + decision.guard + ')' if decision.guard else ''}")
        print(json.dumps(engine.usage.as_dict()), file=sys.stderr)
    elif args.command == "list":
        for memory in store.all(None if args.all else schema.OPEN):
            print(f"{memory.id} [{memory.status}] {memory.key}: {memory.content} <- {memory.source_ids}")
    elif args.command == "history":
        print(json.dumps(store.versions(args.memory_id), ensure_ascii=False, indent=1))
    elif args.command == "edit":
        print(store.edit(args.memory_id, args.content).content)
    elif args.command in ("confirm", "reject", "deactivate", "reactivate"):
        memory = getattr(store, args.command)(args.memory_id)
        print(f"{memory.id} -> {memory.status}")
    elif args.command == "context":
        print(format_context(retrieve(store, args.query, budget_tokens=args.budget)))
    elif args.command == "expire":
        for memory in store.expire(args.today):
            print(f"expired {memory.id}: {memory.content}")
    elif args.command == "reviews":
        print(json.dumps(store.reviews(), ensure_ascii=False, indent=1))
    store.close()


if __name__ == "__main__":
    main()
