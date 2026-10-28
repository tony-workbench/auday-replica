# auday-memory: a traceable, updatable long-term memory engine

The engine is rebuilt from Auday's public materials, not Auday's code. What is known versus guessed: [RESEARCH.md](RESEARCH.md). Test results: [RESULTS.md](RESULTS.md).

## How a transcript becomes memory

```
transcript ──► Extraction (LLM proposes) ──► deterministic checks ──► candidate memories
                                                                        │
          related existing memories ◄── exact key match + vector search ┘
                        │
                        ▼
              Consolidation (LLM proposes ADD/NOOP/MERGE/SUPERSEDE/REVIEW)
                        │
                        ▼
              Guarded executor (code executes; the LLM never writes to the DB directly)
                        │
                        ▼
  SQLite: records (Auday-compatible) · memories (versioned) · memory_versions · memory_events · reviews
                        │
                        ▼
              Retrieval: lifecycle filter → ranking → token budget → citations with sourceIDs
```

1. **Extraction.** The LLM proposes candidate memories from a transcript. Code checks each one's quotes, speaker, expiry and importance.
2. **Finding related memories.** Each candidate is compared with existing memories by exact slot key (design rule 5) and by vector search.
3. **Consolidation.** The LLM proposes one operation per candidate:
   - **ADD**: a new memory;
   - **NOOP**: already known, so only the new source is recorded;
   - **MERGE**: combine it with an existing memory;
   - **SUPERSEDE**: it replaces an outdated memory;
   - **REVIEW**: unsure, so it is queued for the user.
4. **Guarded executor.** Code applies the operation only if it passes the guardrails below.
5. **Storage** in SQLite.
6. **Retrieval** for Chat: drop memories that must not be used (superseded, inactive, expired, and candidates unless enabled), rank the rest, keep within a token budget, and cite each memory's sources (`sourceIDs`).

## Modules

| File | Contents | Origin |
|---|---|---|
| `memengine/schema.py` | States, transition rules, JSON Schemas for extraction and merge | State names from Auday (evidence levels A/B in [RESEARCH.md](RESEARCH.md)); transitions are ours |
| `memengine/store.py` | SQLite; `records` matches Auday's desktop cache | `records` schema is level A; other tables are ours |
| `memengine/embed.py` | Vectors stored as float16; an offline `HashEmbedder` (matches words, not meaning) and an `HTTPEmbedder` for any OpenAI-compatible service (works with EmbeddingGemma) | float16 / 768 dimensions follow the official Auday Skill on the desktop |
| `memengine/prompts.py` | Extraction and merge prompts | Ours |
| `memengine/extract.py` | Calls the LLM, then checks verbatim evidence, speaker, expiry and importance | Ours |
| `memengine/consolidate.py` | Neighbor retrieval, LLM decision, guarded executor | Ours |
| `memengine/retrieve.py` | Context retrieval for Chat | Ours |
| `memengine/llm.py` | Providers: Anthropic, OpenAI-compatible, Gemini, and replay of recorded answers; token counting | Ours |
| `memengine/pipeline.py` | Runs each transcript revision through the steps above, once | Ours |
| `memengine/cli.py` | Command-line tool (see Usage) | Ours |

## Design rules

1. **The LLM proposes; code executes.** Every operation must pass these guardrails:
   - the target must be a neighbor returned by retrieval;
   - MERGE/SUPERSEDE need strong evidence (the user's own words, stated with certainty); weak evidence goes to REVIEW;
   - older evidence cannot override a newer memory;
   - a confirmed memory's successor is only saved, never auto-confirmed;
   - rejected facts are never revived and inactive memories never reactivated automatically.
2. **Evidence must appear verbatim in the transcript.** If a quote isn't there, the whole memory is dropped.
3. **Speaker attribution is strict.** A memory counts as `user_stated` only if at least one quote comes from a segment that matches the user's voiceprint (Auday's "confirmed voice"). Otherwise it becomes `inferred` and stays a candidate. Memories from recordings without speaker labels are never saved automatically.
4. **Extract only from transcripts.** Summaries and Reflections are the AI's interpretation (per Auday's FAQ), so they are not evidence.
5. **Slot keys are always English.** A slot key names what a memory is about (e.g. `preference.editor`). The same fact in Chinese and English then lands in the same slot, even with the word-matching `HashEmbedder`, so SUPERSEDE matches reliably.
6. **Nothing is ever deleted.** Content changes create a new version, state changes go to the event log, and SUPERSEDE links both ways.
7. **Each record version is processed once.** Each `(record_id, revision)` pair runs once; an edited transcript gets a new revision and runs again.

## Memory states (our design, Auday's state names)

Arrows show who may make each transition: the system, the user, or expiry.

```
candidate ─system/user─► saved ─user─► confirmed
    │                     │               │
    ├─user─► rejected ◄───┴─user──────────┤
    └────────system/user──► superseded ◄──┘   (terminal, traceable)
saved/confirmed/candidate ─user or expiry─► inactive ─user─► saved/confirmed
```

## Usage

```bash
.venv/bin/python -m unittest discover -s tests             # 151 deterministic tests (including the app)
.venv/bin/python eval/run_eval.py --provider anthropic --model claude-haiku-5-5   # needs ANTHROPIC_API_KEY
.venv/bin/python eval/run_eval.py --provider openai --model gpt-5-mini            # or any OpenAI-compatible endpoint via --base-url
.venv/bin/python eval/run_eval.py                                  # replay eval/cassettes/blind.json
.venv/bin/python -m memengine.cli --db mem.sqlite ingest-auday "<AudayWorkflow profile>/library.sqlite"
.venv/bin/python -m memengine.cli --db mem.sqlite context "我周几打羽毛球？"   # "What day do I play badminton?"
```
