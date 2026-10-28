"""New candidate -> related old memories -> LLM decision -> guarded execution.

The LLM only *proposes* an operation. `execute` enforces the policy:
  * target_id must be one of the retrieved neighbours.
  * MERGE / SUPERSEDE need strong evidence (user_stated + definite); weaker evidence
    becomes REVIEW: stored as a candidate linked to the target, target untouched.
  * SUPERSEDE needs the new evidence to be at least as recent as the target, so a
    late-processed old transcript cannot overwrite a newer fact.
  * Superseding a confirmed memory yields a *saved* successor: the user confirmed the
    old wording, not the new one.
  * Facts the user rejected are never re-added automatically.
  * Inactive memories are never reactivated automatically.
Nothing is deleted: old versions, sources and status changes stay in the store.
"""

from dataclasses import dataclass

import jsonschema

from . import prompts, schema
from .llm import complete_json

NEIGHBOR_STATUSES = (schema.CANDIDATE, schema.SAVED, schema.CONFIRMED,
                     schema.INACTIVE, schema.REJECTED)


@dataclass
class Decision:
    operation: str           # executed operation
    proposed: str            # what the model proposed (or "ADD" when no neighbours)
    memory_id: str = None    # memory created or modified
    target_id: str = None
    reason: str = ""
    guard: str = None        # set when a guard changed the proposal


def neighbors(store, item, limit=5):
    by_key = [m for m in store.all(NEIGHBOR_STATUSES) if m.key == item["key"]]
    similar = store.similar(f"{item['key']} {item['content']}", NEIGHBOR_STATUSES, limit=limit)
    merged = {m.id: m for m in similar}
    for memory in by_key:
        merged.setdefault(memory.id, memory)
    # Exact-key matches first, then by similarity.
    return sorted(merged.values(), key=lambda m: (m.key != item["key"], -m.score))[:limit + 2]


def _fields(item, status):
    return dict(key=item["key"], category=item["category"], content=item["content"],
                status=status, attribution=item["attribution"], certainty=item["certainty"],
                temporal=item["temporal"], importance=item["importance"],
                valid_until=item.get("valid_until"), observed_at=item["observed_at"],
                source_ids=list(item["source_ids"]), evidence=list(item["evidence"]))


def _strong(item):
    return item["attribution"] == "user_stated" and item["certainty"] == "definite"


def _promote(store, target, item):
    """A candidate that the user now states in their own words becomes saved."""
    if target.status == schema.CANDIDATE and _strong(item):
        store.revise(target.id, actor="system", op="UPGRADE", reason="corroborated by user",
                     attribution="user_stated", certainty="definite")
        store.transition(target.id, schema.SAVED, actor="system",
                         reason="corroborated by the user's own statement")


def decide(store, item, provider, usage=None):
    found = neighbors(store, item)
    if not found:
        return {"operation": "ADD", "target_id": None, "reason": "no related memory"}, found, False
    try:
        proposal = complete_json(provider, prompts.CONSOLIDATION_SYSTEM,
                                 prompts.consolidation_user(item, item["observed_at"], found),
                                 schema.CONSOLIDATION_SCHEMA, usage)
    except (ValueError, jsonschema.ValidationError) as error:
        # An unusable model answer must never touch existing memories.
        proposal = {"operation": "REVIEW", "target_id": found[0].id,
                    "reason": f"invalid model output: {str(error)[:120]}"}
    return proposal, found, True


def consolidate(store, item, provider, usage=None):
    proposal, found, _ = decide(store, item, provider, usage)
    return execute(store, item, proposal, found)


def execute(store, item, proposal, found):
    op = proposal["operation"]
    target_id = proposal.get("target_id")
    reason = proposal.get("reason", "")
    decision = Decision(op, op, target_id=target_id, reason=reason)
    by_id = {m.id: m for m in found}
    target = by_id.get(target_id)

    def guard(new_op, why):
        decision.operation, decision.guard = new_op, why

    if op != "ADD" and target is None:
        guard("REVIEW" if found else "ADD", f"target {target_id!r} is not a retrieved neighbour")
    elif op == "ADD":
        rejected = [m for m in found if m.status == schema.REJECTED and m.key == item["key"]
                    and m.score >= 0.85]
        if rejected:
            target = rejected[0]
            guard("NOOP", "near-identical to a memory the user rejected")
    elif op in ("MERGE", "SUPERSEDE"):
        if target.status not in schema.OPEN:
            guard("ADD", f"target is {target.status}; never edited automatically")
        elif not _strong(item):
            guard("REVIEW", "new evidence is inferred or tentative")
        elif op == "SUPERSEDE" and (item["observed_at"] or "") < (target.observed_at or ""):
            guard("REVIEW", "new evidence is older than the memory it would replace")
        elif op == "MERGE" and not (proposal.get("merged_content") or "").strip():
            guard("REVIEW", "MERGE without merged_content")

    op = decision.operation
    decision.target_id = target.id if target is not None and op != "ADD" else None

    if op == "ADD":
        memory = store.add(reason=reason, **_fields(item, item["status"]))
        decision.memory_id = memory.id
    elif op == "NOOP":
        decision.memory_id = target.id
        if target.status == schema.REJECTED:
            store._event("system", "SUPPRESS", target.id, None, reason="matches rejected memory",
                         content=item["content"], source_ids=item["source_ids"])
        else:
            store.revise(target.id, actor="system", op="CORROBORATE", reason=reason,
                         evidence=item["evidence"], source_ids=item["source_ids"])
            _promote(store, target, item)
    elif op == "MERGE":
        store.revise(target.id, actor="system", op="MERGE", reason=reason,
                     content=proposal["merged_content"].strip(), evidence=item["evidence"],
                     source_ids=item["source_ids"], observed_at=max(item["observed_at"], target.observed_at or ""))
        _promote(store, target, item)
        decision.memory_id = target.id
    elif op == "SUPERSEDE":
        status = schema.SAVED if target.status == schema.CONFIRMED else item["status"]
        if target.status == schema.CANDIDATE and _strong(item):
            status = schema.SAVED
        memory = store.add(op="SUPERSEDE", reason=reason, supersedes=target.id,
                           **_fields(item, status))
        store.transition(target.id, schema.SUPERSEDED, actor="system", reason=reason,
                         superseded_by=memory.id)
        decision.memory_id = memory.id
    elif op == "REVIEW":
        memory = store.add(op="REVIEW", reason=reason, **_fields(item, schema.CANDIDATE))
        store.open_review(memory.id, target.id if target is not None else None,
                          decision.guard or reason)
        decision.memory_id = memory.id
    return decision
