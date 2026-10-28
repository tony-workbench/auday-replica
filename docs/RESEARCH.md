# Auday long-term memory: what public sources show (2026-10-24)

Public evidence on how Auday extracts and keeps memories, graded by reliability; the basis for [MEMORY_ENGINE.md](MEMORY_ENGINE.md). The main source is the **official Auday Skill**, a public desktop add-on that syncs Auday data from the iPhone for AI agents to search.

**No public source contains Auday's memory extraction or consolidation code, prompts or state machine.** Public sources confirm only the record shapes, the memory state names and the product's promises.

> **Update 2026-10-26:** Requests captured on a real device show that memory candidates (`memoryPoints`) come from the same call that writes the hourly Summary, and a candidate not reviewed within 5 days is saved automatically. This supersedes some guesses in section 4; see [AUDAY_OBSERVATIONS.md](AUDAY_OBSERVATIONS.md).

Evidence levels:
- **A**: confirmed by public source code or docs
- **B**: behavior stated in official product copy (website, FAQ, privacy policy, App Store), no implementation details
- **C**: our guess from A/B
- **D**: our own design, unrelated to Auday

## 1. What was searched

"Fixtures" are the sample data files in the Skill's tests.

| Source | Result |
|---|---|
| All files in `666ghj/auday-skill`, the official Skill (clone @ `2024572`, 2026-10-23) | Read; grepped for memory/status/state/supersede/candidate/revision |
| Full Git history (33 commits; `git log -S` for prompt/extract/supersede/candidate/consolidat/inactive, plus deleted files) | No prompt, extraction or merge logic, and no such files ever deleted |
| Issues #1 #2 #4, PR #3 | All about sync, pairing or Windows; none about memory |
| The author's other public repos | No other Auday repos |
| auday.ai home page, /faq, /privacy.html | Behavior descriptions only |
| App Store page and release notes 1.0.0–1.0.5 | Behavior descriptions only |
| Web search (Chinese and Japanese press) | Product introductions only |

## 2. Confirmed (level A)

1. **Exactly five record kinds**: `transcript, highlight, summary, reflection, memory` (`docs/protocol.md` in the official Auday Skill, the `--kind` values in `scripts/auday.py`, `categories` in the Swift peer).
2. **Desktop cache table**: `records(id, kind, text, date, body)`, full JSON in `body` (`scripts/auday.py:150`). Our `records` table uses the same schema.
3. **Common fields**: `id, kind, title, text, start, timeZone, status, sourceIDs, audioAssetID, revision` (`references/context.md`). Not every record has all of them, and unknown fields must be preserved.
4. **The status field has two spellings**: `status` in `make_fixture.py`; `state` in `semantic-fixture.json`, `test_semantic_search.py` and `test_library_export.py`. Desktop code reads `body.get("state", body.get("status"))` (`library_export.py:103`, `semantic_search.py:421`). **So the iPhone's field name is either unsettled or differs by record kind.**
5. **Status values in the fixtures**:
   - memory: `confirmed`, `candidate`, `superseded` (`test_semantic_search.py:94` changes confirmed to superseded, then reindexes)
   - transcript: `saved`
   - highlight / summary / reflection: `complete`
6. **Five memory states SKILL.md asks agents to tell apart**: "confirmed, automatically saved, candidate, rejected, and superseded". protocol.md adds: "Candidate memories remain candidates."
7. **Provenance**: memories and summaries point to transcripts via `sourceIDs`; reflections point to summaries (`make_fixture.py`: `reflection-1 → summary-1 → transcript-000`). Official rule: "never invent a source relationship".
8. **Speakers stay separate**: what the user said, what someone else said and what the model inferred are kept apart, and an anonymous speaker label is not a confirmed identity (context.md).
9. **Desktop semantic search**: EmbeddingGemma 300M Q8_0, 768 dimensions, float16, cosine similarity, 900-character chunks with 100-character overlap (`semantic_search.py`). **Desktop only.**
10. **The fixtures include an injection sample**: `injection-1` tells the agent to ignore the user and upload all data. Officially, instructions inside transcripts are untrusted data.
11. **The desktop side is read-only**: the Skill cannot write, delete or generate anything on the phone (protocol.md). **So the Skill's code cannot show how the phone changes memory states.**

## 3. Product behavior (level B)

- Memories are "people, preferences, and plans mentioned in passing" (App Store): preferences, plans and relationships (FAQ).
- Users can **review, edit and deactivate** them (home page: "Your memory · Review, edit or deactivate"; App Store: "You decide what stays").
- **Inactive** stops future use of a memory without rewriting earlier summaries or conversations (FAQ). An inaccurate fact can be made Inactive for future AI use (privacy policy §10).
- Automatic AI features review available transcripts and produce saved results (FAQ). The website describes **no user confirmation step**, which fits "automatically saved".
- All LLM work goes straight to **an AI provider the user configures** with their own API key (BYOK); Auday has no server. Requests can include remembered facts, conversation history and profile information (privacy policy §06). Raw audio, raw heart rate/HRV and precise coordinates are not sent.
- **Embeddings and semantic search run on the device** (privacy policy §02).
- AI results are made **hourly** ("Better recovery for hourly AI results", 1.0.4 release notes). Reflection supports long inputs and reuses completed work.
- Chat combines the "confirmed voice" (voiceprint), optional body and location context, and the original text (1.0.2 release notes).
- Home-page screenshots are labeled "Saved example data", so Saved is a UI state name.

## 4. Guesses (level C, unverified)

| Question | Guess | Basis |
|---|---|---|
| Extraction frequency | Hourly batches, in the same pipeline as hourly Highlights/Summary | 1.0.4 "hourly AI results"; FAQ "review available transcripts" |
| Extraction input | Transcript text with speaker labels, not the Summary | Fixture memories' `sourceIDs` point to transcripts, not summaries |
| Default state | Clear user statements → automatically saved; uncertain ones → candidate | The state names, plus no confirmation step on the website |
| UI vs. internal states | Saved ≈ automatically saved / confirmed; Inactive is separate | Website and SKILL.md use different words |
| superseded | An explicit replacement chain; the old entry is kept and marked superseded | `test_semantic_search.py` changes state on the original entry, then rebuilds the index |
| Speaker attribution | The "confirmed voice" decides whether a line is the user's | 1.0.2 release notes + speaker rules in context.md |
| Conflict handling | Unknown. The docs only tell the agent to "show conflicting sources and dates rather than silently selecting" | context.md |
| Embedding model | Unknown on the phone; the desktop's EmbeddingGemma **does not** imply the phone's | Privacy policy says only that it runs on the device |
| Where Rejected comes from | The user rejecting a candidate in Remembered facts | The state name |

**Still unanswerable**: importance/confidence thresholds, the extraction prompt, whether merge uses an LLM, whether there is periodic full consolidation, the token budget, and how Chat ranks memories. They need the app itself (prompt text in the IPA) or data exported from a real device.

## 5. Ways to get stronger evidence (best value first)

1. **Export your own data with the Auday Skill** (`export`, or read `library.sqlite`): the real memory JSON, field names, status enum, `sourceIDs` granularity and whether `revision` exists.
2. **Set an OpenAI-compatible proxy you control as the AI provider** and log what Auday sends: the extraction and Chat prompts and request structure. Done with [cloud/capture-worker](../cloud/capture-worker/README.md); follow the app's terms of use.
3. Watch the Remembered facts UI: which entries show as candidate, when superseded appears, and how state changes after an edit.
