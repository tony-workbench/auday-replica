"""Vocabulary and JSON Schemas shared by extraction, consolidation and storage.

Status names follow the public Auday Skill vocabulary (SKILL.md / references/context.md):
confirmed, automatically saved ("saved" in fixtures), candidate, rejected, superseded,
plus "inactive" from the auday.ai FAQ ("Moving one to Inactive stops its future use").
The transition rules below are OUR design; Auday's real state machine is not public.
"""

import jsonschema

KINDS = ("transcript", "highlight", "summary", "reflection", "memory")

CANDIDATE, SAVED, CONFIRMED = "candidate", "saved", "confirmed"
REJECTED, SUPERSEDED, INACTIVE = "rejected", "superseded", "inactive"
STATUSES = (CANDIDATE, SAVED, CONFIRMED, REJECTED, SUPERSEDED, INACTIVE)
ACTIVE = (SAVED, CONFIRMED)           # used for future AI answers
OPEN = (CANDIDATE, SAVED, CONFIRMED)  # may still be merged / superseded

# (from, to) -> actors allowed to make the move. "system" = pipeline / LLM-driven.
TRANSITIONS = {
    (CANDIDATE, SAVED): {"system", "user"},
    (CANDIDATE, CONFIRMED): {"user"},
    (CANDIDATE, REJECTED): {"user"},
    (CANDIDATE, SUPERSEDED): {"system", "user"},
    (CANDIDATE, INACTIVE): {"system", "user"},
    (SAVED, CONFIRMED): {"user"},
    (SAVED, REJECTED): {"user"},
    (SAVED, SUPERSEDED): {"system", "user"},
    (SAVED, INACTIVE): {"system", "user"},
    (CONFIRMED, REJECTED): {"user"},
    (INACTIVE, REJECTED): {"user"},
    (CONFIRMED, SUPERSEDED): {"system", "user"},  # system path is guarded in consolidate.py
    (CONFIRMED, INACTIVE): {"system", "user"},    # system path only for expiry
    (INACTIVE, SAVED): {"user"},
    (INACTIVE, CONFIRMED): {"user"},
    (REJECTED, CANDIDATE): {"user"},
}

CATEGORIES = ("identity", "preference", "relationship", "routine", "plan",
              "goal", "project", "work", "constraint", "other")
OPERATIONS = ("ADD", "NOOP", "MERGE", "SUPERSEDE", "REVIEW")

MEMORY_ITEM_SCHEMA = {
    "type": "object",
    "required": ["content", "key", "category", "attribution", "certainty",
                 "temporal", "importance", "evidence"],
    "additionalProperties": False,
    "properties": {
        "content": {"type": "string", "minLength": 2, "maxLength": 300},
        "key": {"type": "string", "pattern": r"^[a-z0-9_]+(\.[a-z0-9_]+){1,4}$"},
        "category": {"enum": list(CATEGORIES)},
        "attribution": {"enum": ["user_stated", "inferred"]},
        "certainty": {"enum": ["definite", "tentative"]},
        "temporal": {"enum": ["stable", "temporary"]},
        "valid_until": {"type": ["string", "null"], "pattern": r"^\d{4}-\d{2}-\d{2}$"},
        "importance": {"type": "integer", "minimum": 1, "maximum": 5},
        "replaces": {"type": ["string", "null"], "maxLength": 300},
        "evidence": {
            "type": "array", "minItems": 1, "maxItems": 3,
            "items": {
                "type": "object",
                "required": ["record_id", "quote"],
                "additionalProperties": False,
                "properties": {
                    "record_id": {"type": "string"},
                    "quote": {"type": "string", "minLength": 1, "maxLength": 300},
                    "speaker": {"type": ["string", "null"]},
                },
            },
        },
    },
}

# Envelope only: each memory is validated on its own (MEMORY_ITEM_SCHEMA) so one bad item
# cannot sink a batch, and the informational "skipped" list never blocks extraction.
EXTRACTION_SCHEMA = {
    "type": "object",
    "required": ["memories"],
    "properties": {"memories": {"type": "array", "items": {"type": "object"}},
                   "skipped": {"type": "array"}},
}

CONSOLIDATION_SCHEMA = {
    "type": "object",
    "required": ["operation", "target_id", "reason"],
    "additionalProperties": False,
    "properties": {
        "operation": {"enum": list(OPERATIONS)},
        "target_id": {"type": ["string", "null"]},
        "merged_content": {"type": ["string", "null"], "maxLength": 400},
        "reason": {"type": "string", "maxLength": 400},
    },
}


def validate(value, schema):
    """Raise jsonschema.ValidationError if value does not match schema."""
    jsonschema.validate(value, schema)
    return value
