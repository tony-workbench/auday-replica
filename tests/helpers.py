"""Shared test helpers: record and memory builders and a scripted model. Importing this module
also puts the repository root on sys.path."""

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from memengine import prompts  # noqa: E402
from memengine.llm import ScriptedProvider  # noqa: E402


def transcript(record_id, start, segments, revision=1):
    return {"id": record_id, "kind": "transcript", "start": start, "timeZone": "Asia/Shanghai",
            "text": "\n".join(s["text"] for s in segments), "segments": segments,
            "status": "saved", "sourceIDs": [], "revision": revision}


def mem(content, key, quote, record_id, category="preference", attribution="user_stated",
        certainty="definite", temporal="stable", importance=3, valid_until=None, replaces=None):
    return {"content": content, "key": key, "category": category, "attribution": attribution,
            "certainty": certainty, "temporal": temporal, "valid_until": valid_until,
            "importance": importance, "replaces": replaces,
            "evidence": [{"record_id": record_id, "quote": quote, "speaker": "USER"}]}


def record_id_of(user_prompt):
    return re.search(r"RECORD_ID: (\S+)", user_prompt).group(1)


def consolidation_view(user_prompt):
    new_part, existing_part = user_prompt.split("\n\nEXISTING MEMORIES:\n")
    return json.loads(new_part.split("NEW MEMORY:\n", 1)[1]), json.loads(existing_part)


class Oracle:
    """Scripted model. Extraction answers come from a {record_id: [items]} table; consolidation
    answers come from `decide(new, existing)`. The default decision is NOOP for the same key and
    content, SUPERSEDE for the same key with new content, and ADD otherwise."""

    def __init__(self, extractions, decide=None):
        self.extractions = extractions
        self.decide = decide or self.default_decide
        self.provider = ScriptedProvider(self.answer)

    @staticmethod
    def default_decide(new, existing):
        for memory in existing:
            if memory["key"] == new["key"] and memory["status"] != "superseded":
                if memory["content"] == new["content"]:
                    return {"operation": "NOOP", "target_id": memory["id"], "reason": "same"}
                return {"operation": "SUPERSEDE", "target_id": memory["id"], "reason": "changed"}
        return {"operation": "ADD", "target_id": None, "reason": "new"}

    def answer(self, system, user):
        if system == prompts.EXTRACTION_SYSTEM:
            items = self.extractions.get(record_id_of(user), [])
            return {"memories": items() if callable(items) else items}
        return self.decide(*consolidation_view(user))
