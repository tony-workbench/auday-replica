# iPhone app vs. real Auday: item-by-item checklist

**Method:** real Auday 1.0.7 and the replica side by side on the same iPhone, screenshots over USB
(`xcrun devicectl device capture screenshot`). Screenshots hold personal data and stay outside the repo.
A row is done only when the replica matches on the phone.

**Columns:** "Replica" is what the replica had when compared; "fixed" rows have since been changed.

**Status:** **same**; **diff** (exists but differs); **missing**; **fixed, check on phone** (changed, not yet seen on the phone); **—** (not compared).

## Settings (… › Settings)

| Item | Auday | Replica | Status |
|---|---|---|---|
| Header card | Logo, "Auday", "Local Privacy Edition" tag, crown "LIFETIME MEMBER" badge | "REPLICA" badge | fixed, check on phone |
| Appearance / Language rows | Label on one line, value with ⌃⌄ below; both rows the same size | System inline pickers, different sizes | fixed, check on phone |
| Language options | 简体中文, English, 日本語, 한국어 (app and AI output language) | 5 transcription languages plus "Second language" | fixed, check on phone |
| Intelligence rows | Transcription, My voice recognition, AI settings, Body & location data, Connect to your workflow, Your memory | Same (was "Connect to your Mac") | same |
| Your archive | Audio stored, Keep original audio Forever, Batch export | Extra "Days" and "Waiting to sync" rows | fixed, check on phone |
| About | Version, Privacy Policy, Terms of Service, Contact us, FAQ | Same | same |

## My voice recognition

| Item | Auday | Replica | Status |
|---|---|---|---|
| Enrolled state | Waveform art, serif "Your voice is ready", "Highlight your words."; card with Voice recognition toggle ("Uses extra processing and memory when enabled."), Record again, Delete voice profile | "Voice recognized" card, Record again, Remove my voice; no toggle | fixed, check on phone |
| Enrolment | Three readings, about 45 s | Three readings with meter | same (flow) |

## AI settings

| Item | Auday | Replica | Status |
|---|---|---|---|
| Intro card | "An AI of your choosing." + text | Same text | same |
| Providers | DeepSeek, OpenAI, Claude, Gemini, Grok, MiniMax, Kimi, GLM, Qwen, Custom | OpenAI, Gemini, Custom | fixed, check on phone |
| Model Name / Base URL rows | Label and value on one line | Stacked | fixed, check on phone |
| How Auday remembers | Automatic Highlights & Summaries, Daily Reflection, Reflection Time | Same | same |

## Transcription

| Item | Auday | Replica | Status |
|---|---|---|---|
| Local efficient | SenseVoice; Mandarin, Cantonese, English, Japanese, Korean; Automatic transcription | SenseVoice Small int8 on the iPhone (ONNX Runtime), Silero VAD, ≤15 s snippets; same front end as the Mac, tested against it; model downloaded once (about 240 MB, on Wi-Fi when automatic) | fixed, check on phone |
| Local accurate | Whisper; 10+ languages listed | Whisper small (compressed, about 216 MB) via WhisperKit, downloaded when chosen; uses your first language (or the second when it fits better), same five languages as Local efficient; load and transcribe progress bars, delete option, slow-device note | fixed, check on phone |
| Cloud & self-hosted | Text, Deepgram / Qwen tips, Configure service ›, Automatic transcription toggle and note | Listed, with the note "Not in the replica yet." | diff |

## Body & location data

| Item | Auday | Replica | Status |
|---|---|---|---|
| Apple Health | Body data toggle, "Available"; reads Health directly, no import | Toggle; status text after a read | fixed, check on phone |
| Recording places | Location data toggle | Same | same |

## Connect to your workflow

| Item | Auday | Replica | Status |
|---|---|---|---|
| Top | Phone + laptop picture, "Bring what Auday knows / Connect to your workflow", "Let memories inform your thinking and recordings offer more" | Different title and layout | fixed, check on phone |
| Steps | 01 Install Auday Skill (link, View installation guide); 02 Connect to the same Wi-Fi; 03 Communication password (Copy password, New password); 04 Access scope, Read only (All text / Text and audio) | Prerequisites list, password, scope | fixed, check on phone |
| Bottom | Fixed "Enable access" button, "Keep this page open after enabling access" | — | same |

## Days (home)

| Item | Auday | Replica | Status |
|---|---|---|---|
| Top, week strip, hour chart | As built | Close | same |
| "The day's hours · N captured" | One line | Wraps to two lines | fixed, check on phone |
| Hour row | Serif AI short summary; "Medium information · N mark · N highlight" | Raw transcript text; marks only | fixed, check on phone |
| Footer | "Stored on your device. Optional services connect directly to your provider." | — | fixed, check on phone |

## Hour page

| Item | Auday | Replica | Status |
|---|---|---|---|
| Header | "ONE HOUR OF YOUR DAY", serif "01:00–02:00", "2m · Audio preserved" | "05:00 – 06:00 · CAPTURED · 1M", mark times | fixed, check on phone |
| Tabs | Transcript / Highlights / Summary | Single transcript card | fixed, check on phone |
| Transcript lines | mm:ss, serif text, Me / Me* tag, place chip; no "No speech." lines | hh:mm:ss; "No speech." rows shown | fixed, check on phone |
| Saved audio bar | Title and range on one line | Wraps | fixed, check on phone |
| Transcript place | "📍 Place · Street" line above the transcript | — | fixed, check on phone (iPhone now keeps places) |
| Highlight chips | Body signals, "Marked", then "📍 place"; never "Conversation" | "Conversation" chip, no place | fixed, check on phone |
| Highlight card | "Show more ⌄", "Original transcript ›" | Same; Original transcript opens the lines it covers | fixed, check on phone |
| Summary tab | Title, text, density, "Things to note", "Updated Oct 27 · 02:03", "Daily memory candidates ›", grey ✦ "Highlights & Summary r…" button (label cut off in Auday), "AI features use your chosen provider. These AI features use text, not audio.", "Use your current transcription model to replace this hour's transcript…", "Transcribe again" | "Worth noting"; Transcribe again in the Transcript tab | fixed, check on phone (button reads "Refresh Highlights & Summary") |
| Unreadable recordings | Not shown | "This recording cannot be read…" line | fixed, check on phone |
| Local accurate noise | Speech only | "[MUSIC]", "(footsteps)", Sinhala/Georgian guesses | fixed, check on phone |

## Chat

| Item | Auday | Replica | Status |
|---|---|---|---|
| Empty state | "YOUR LIFE IS THE CONTEXT", "Less explaining. More understanding.", text, suggestions with ↖ | Not yet checked | — |
| Header | "Auday AI"; memory, history and new chat icons | Not yet checked | — |
| Input | "Ask about your days…", model name below | Not yet checked | — |

## Search

| Item | Auday | Replica | Status |
|---|---|---|---|
| Page | "Find it in your day", "Keyword and semantic search", All days button, field, Recent searches, "Want to explore further?" + Ask Chat ↗ | Not yet checked | — |

## Still open

- Local efficient uses Apple's speech model until SenseVoice has downloaded.
- Cloud & self-hosted transcription is listed but not built.
- App text is English only. The Language setting changes the AI's language, not the app's.
- Hour rows on Days show the AI summary only once AI settings are filled in (as in Auday).

## Replica improvements

A parity pass restyles these extras to Auday's look but must not remove them.

- Settings › Make it yours: **Second language** (None or another language you speak). Transcription retries in it; everything the AI writes stays in your first language.
- Settings › Your archive: **Days** count and **Waiting to sync to your Mac**.
- Transcription: **Recent transcriptions** (engine, detected language, lines, time taken, errors; stored in Application Support/transcriptions.json); "Transcribed 16:20 · 9 lines" after each run; **Languages** row; **Waiting** count and **Transcribe now**. Local accurate shows model size, download progress and **Delete the model**.
- My voice recognition: **Since <date> · tuned to your recordings (Me at …)** under "Your voice is ready".
- AI settings: **N models from <provider>** once the live list loads; a model from another provider is never kept.
- Hour page: **👉 marked moments** above the transcript; **Transcribe again** shows which mode it will use (Local accurate / Local efficient).
- Connect to your workflow: two **Mac commands** to copy: `./scripts/start.sh --host 0.0.0.0` and `.venv/bin/python -m app.pair_iphone`.

## Differences chosen by the owner

- Daily reflection is written once a day, only after the Reflection Time, never on demand (iPhone and Mac web app). Auday has "Generate now" and "Generate again" buttons; the replica has neither, and the day's memory candidates are made only once.
