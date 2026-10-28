# Test results (2026-10-24, prompt_version 2026-10-24.1)

Memory engine results on 2026-10-24. Terms (ADD, NOOP, MERGE, SUPERSEDE, REVIEW) are defined in [MEMORY_ENGINE.md](MEMORY_ENGINE.md); current test counts are in [App tests](#5-app-tests).

## 1. Deterministic tests: 34/34 passed

`.venv/bin/python -m unittest discover -s tests`. No AI model needed: a scripted stand-in returns fixed output, well-behaved and malicious.

| Category | What is covered |
|---|---|
| Storage | Round-trip of the official fixtures `memory-1`/`memory-2`/`transcript-000`; unknown kinds rejected; **after reopening from disk**, status, provenance, events and vectors are intact |
| State machine | The system cannot confirm or reject; it can set inactive only on expiry; superseded is terminal; a user edit creates a new, confirmed version |
| Extraction guardrails | Fabricated quotes dropped; quotes with speaker labels or punctuation still accepted; other people's words downgraded to candidate; no speaker label means never auto-saved; uncertain wording downgraded to candidate; trivia, already-expired plans and cross-record quotes dropped; invalid JSON retried once |
| Merge guardrails | Strong-evidence SUPERSEDE of a confirmed memory saves the new one, and the old one keeps its provenance; weak-evidence SUPERSEDE → REVIEW; older evidence cannot override a newer memory; unknown target id → REVIEW; NOOP only appends provenance; NOOP or MERGE promotes a candidate to saved when backed by the user's own words; rejected memories stay rejected; inactive memories are not reactivated or edited; no neighbors → ADD without calling the LLM |
| Retrieval | Filters out superseded, inactive, candidate and expired plans; candidates only when enabled, marked unverified; respects the token budget; includes sourceIDs |
| Pipeline | Each `(record, revision)` is processed once; a new revision is processed again; summaries are not used for extraction |
| Scale | 100 sessions: 5 stable facts that keep recurring, plus 1 fact that changes every 10 sessions. Always 6 active and 9 superseded memories; the cat's-name memory collects 20 sources; runs in under 1 second |

## 2. Scenario eval: 19/19 scenarios, 38/38 final-state checks passed

A separate Claude Sonnet agent played the model "blind": it saw only the prompts in `eval/pending.json` and was told (not forced) not to read the gold labels or code. Three rounds, since merge depends on extraction output. Answers are recorded in `eval/cassettes/blind.json`; `.venv/bin/python eval/run_eval.py` replays them offline with identical results.

| Metric | Result | Notes |
|---|---|---|
| Extraction recall / miss rate | 1.00 / 0.00 | 18 required facts; recall = share of them found |
| Extraction precision (vs. gold) | 1.00 | Nothing extracted beyond the expected facts |
| False memory rate (forbidden) | 0.00 | Other people's facts, sarcasm, AI guesses, injection and hypotheticals all kept out |
| Duplicate rate | 0.00 | The oat latte, mentioned in Chinese and in English, merged via NOOP with both sources kept |
| Conflict-handling accuracy | 1.00 | SUPERSEDE chains correct for seat, editor (English → Chinese) and employer (ByteDance → Tencent); the confirmed peanut allergy survived a Chinese "maybe"; the rejected milk tea stayed rejected |
| Provenance rate | 1.00 | Every evidence quote appears verbatim in the record it cites |
| Guardrail interventions | 0 | The model never proposed a disallowed operation, so guardrails were tested only in unit tests |
| Tokens | 33 calls, about 31k input + 3k output (estimated) | About 1.4k tokens per transcript; mostly the ~1k-token extraction system prompt, which prompt caching could cut |

### The one failure, fixed before the final run

`18_candidate_corroborated` failed in round 2: the model chose MERGE for a candidate the user repeated, but the engine promoted candidates only on NOOP. MERGE now uses the same promotion (`consolidate._promote`), with a regression test. The gold was not changed.

### What this 100% does not show

- **Few, clean scenarios.** 19 scenarios, 25 short transcripts; real hours have noise, casual speech and transcription errors.
- **One author for prompt and gold**, so some scenarios may only test rules the prompt states.
- **A strong model.** Sonnet is stronger than a cheap production model; the guardrails were not stressed.
- **A word-matching embedder.** The offline `HashEmbedder` matches words, not meaning, so cross-language merging relies on the English slot key. Inconsistent key names would miss related memories; untested here.

## 3. Known design limitations

1. If a record crashes mid-merge, the next run re-extracts it and relies on NOOP for dedup. There is no transactional rollback.
2. The merge step calls the model once per candidate memory; candidates are not batched.
3. No periodic full consolidation: over time, several compatible fine-grained memories can pile up on one topic.
4. The REVIEW queue only collects items and does not notify the user; it needs a UI.
5. Expiry uses only `valid_until`. Undated temporary facts (e.g. "I'm busy this week") rely on extraction skipping them.

## 4. Real local model: SmolLM3-3B-4bit (MLX, Apple M2 8GB)

```bash
.venv/bin/python eval/run_eval.py --provider openai --base-url http://127.0.0.1:8089/v1 \
  --model default_model --system-prefix $'/no_think\n' --report eval/report_smollm3.json
```

Needs the MLX server from the main README on port 8089. The prompt was not tuned for the small model.

| Metric | SmolLM3-3B | Blind Sonnet (replay) |
|---|---|---|
| Scenarios passing all checks | 10/19 | 19/19 |
| Final-state checks | 22/38 | 38/38 |
| Extraction recall | **0.31** | 1.00 |
| False memory rate | **0.00** | 0.00 |
| Duplicate rate | 0.33 | 0.00 |
| Conflict-handling accuracy | 0.50 | 1.00 |
| Provenance rate | **1.00** | 1.00 |
| Unparseable extraction output (safely wrote nothing) | 1 | 0 |
| Runtime | 30 calls, 7 min 26 s | — |

**Every failure was a miss**: weak Chinese understanding, inconsistent slot names that blocked merges, no SUPERSEDE proposed. No wrong, misattributed or overwritten memories. All 8 safety scenarios passed (other people's facts, AI guesses, sarcasm, prompt injection, confirmed-memory protection, no revival of rejected memories, unknown speaker, uncertain plans). A weaker model costs recall, not safety.

## 5. App tests

`tests/test_app.py` had 7 tests:
- Hourly processing: a Highlight whose quote is not the original wording is dropped; the same text is not extracted twice.
- Invalid AI output marks that hour as failed, keeps the original text and writes no memory.
- Daily Reflection: nonexistent source ids are removed.
- Chat: fabricated citations are removed.
- The export format matches the Auday test fixtures.
- The API key is masked in the API.
- End-to-end round trip through the HTTP API.

With the engine's 34 tests, that was 41, all passing. Today `tests/` has 151 tests: 11 in `tests/test_app.py` and 36 in `tests/test_engine.py`.
