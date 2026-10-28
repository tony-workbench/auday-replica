# Auday's interface and interactions (iPhone, 1.0.7)

Layout and behavior of each screen of the real Auday iPhone app, the reference for the replica's Mac web interface. Taken from the owner's screen recordings (2026-10-26); no recording content.

## Overall

- **Tab bar:** floating capsule at the bottom with three tabs: **Days**, **Chat**, **Search**.
- **Top bar:** Auday's waveform logo and name on the left. On the right, the recording/Watch status button (with a red dot) and the "…" menu, which holds Settings.
- **Style:** light background, serif headings, sans-serif body, rounded cards, almost no borders.
- **Footer line:** small text saying data is stored on the device and optional services connect directly to the user's own provider.

## Days (home)

Top to bottom:

1. **Date:** large day number with weekday, month and year beside it; "TODAY — 6h 20m" (total recording time) below; calendar button on the right.
2. **Week strip:** a row of dates (25 26 27 … 31); today is a filled circle.
3. **Hourly bar chart:** one bar per hour, 0–24. Height shows information density; hours without recordings are a thin line.
4. **Daily Reflection card:** dark background, dot-matrix illustration on the top half, then "DAILY REFLECTION", the truncated cover sentence, and "5h 22m recorded · 9 Highlights ↗". Tap to open the Reflection page.
5. **"The day's hours"**, with "8 captured" beside the heading, then an hourly timeline. Each item shows:
   - Time (11:00), status (CAPTURED, NO CAPTURE or QUIET), and recording duration on the right (50m, 1h 0m, 4s).
   - Recorded hours: a short AI note on the hour (`shortNote`), then "Low/Medium information · ✦ N highlight(s)", plus "N mark(s)" if any, and ↗ on the right.
   - No recording: "NO CAPTURE". Almost no sound: "QUIET" with "A quiet hour.".

## Your Watch

Opened from the Watch status button. A panel slides up, close button top right:

- Tagline: "The best AI hardware. Maybe you already own it."
- Tip bar: "Hold the Watch screen for 1 second to stop recording."
- Status: "Apple Watch · Waiting for connection" (shows the connection status once connected).
- "Awaiting sync", with the pending duration on the right (e.g. 0s).
- Large "Manually sync now" button; below it, "Automatically syncs every 15 minutes".
- "Open Auday on your Watch to start capturing."
- Links: "Can't connect your Apple Watch? ↗" and "Read the Watch Recording Tips".

**On the Watch:** tap "Tap to start" to record. While recording, a light tap adds a **mark** (the official site says "Tap to start, then tap to mark a moment"). Only **holding the screen for 1 second** stops recording.

## Daily Reflection page

Top bar: back and share.

1. Cover and stats
2. **Summary**
3. **Reflection**
4. **Daily Memory:** "Review and edit today's selected memories.", then numbered cards (01, 02…), one per memory selected that day, each with ↗ top right.
5. **Highlights**, with "9 highlights" on the right. Each card has:
   - Time span after a ✦ (e.g. 21:26:59–21:27:42)
   - Large serif title
   - One-line interpretation, truncated
   - Tags: Conversation, location ("Recorded…" if no name resolves), Elevated heart rate, High stress, Walk, etc.
   - "Open this hour ↗"
6. **Footer:** "Updated Oct 26 · 16:07"; text explaining that the Reflection is regenerated from current records and the saved one stays available meanwhile; a **Generate again** button. Regeneration is manual.

## Chat (Auday AI)

- **Top bar:** "Auday AI" on the left. Three icons on the right: memory (stacked layers), conversation history (clock), new conversation (edit).
- **Empty state:**
  - Small heading "YOUR LIFE IS THE CONTEXT"
  - Large serif heading "Less explaining. More understanding."
  - Text: conversations, memories and daily rhythms help the AI understand you
  - Three suggested questions, each with ↖: recover an idea mentioned recently; where things could have gone better recently; what to watch out for next week
  - Bottom line: "Answers link back to the transcript and original audio."
- **Input:** placeholder "Ask about your days…", round send button on the right, current model name in small text below (e.g. gemini-3.8-flash).
- **Generating:** "Reading your days…"; the send button becomes stop.
- **Failure:** "No answer was saved. You can ask this question again." and "Ask again".
- **History:** a "Conversations" sheet slides up; each item is a question and a time; "Done" top right.

## Search

- **Heading:** "Find it in your day", subtitle "Keyword and semantic search". Scope button top right, "All days" by default.
- **Search box**, then:
  - **Recent searches** ("No recent searches" when empty)
  - **Want to explore further?**: Chat can help you follow leads, with an "Ask Chat ↗" link
- **Scope sheet:**
  - Cancel / Apply at the top
  - Heading "Choose the days to search."
  - Quick ranges: Today, Last 7 days, Last 30 days, All days
  - Modes: One day, Date range, Several days
  - Month calendar

## Your memory (Settings → Your memory)

Heading "What stays with you.", with three segments: Review, Saved, Inactive.

| Segment | Note at top | Each item |
|---|---|---|
| **Review** | Memories not reviewed within 5 days are saved automatically | Time added → text → "This is about me" (black capsule) → Edit → Ignore |
| **Saved** | These memories help Auday AI understand you | Saved time and source date (e.g. "Saved Oct 26, 23:51 · From Oct 26") → text → "Edited by you." (edited ones only) → Edit → Deactivate |
| **Inactive** | These memories are no longer used by the AI | Deactivation time and source date → text. Ignored memories (state `rejected`) also appear here |

## The replica's web interface (`app/static`)

The replica follows the structure above: three bottom tabs, and other pages (hour, Reflection, Your memory, Settings) open on top, with addresses like `#/days/<date>`, `#/hour/<date>/<hour>` and `#/reflection/<date>`. The browser back button works.

Differences from the real phone:

- **Your Watch** controls this Mac's microphone: click the watch face to record, click while recording to mark a moment, hold 1 second to stop. "Manually sync now" ends the current segment and uploads it immediately. Segments upload every 30 seconds, not 15 minutes, so transcription isn't delayed.
- No "Generate again" button. The Daily Reflection is written automatically once a day, after the "Daily Reflection time" set in Settings.
- Hour list: hours with no human voice show QUIET. Hours with saved but not yet transcribed audio show WAITING, which the real phone doesn't have.
- All labels and Settings text are in English, as in Auday.
- Server API additions that the interface needs:
  - `GET /api/chat/conversations` and `GET /api/chat?conversation=…` (conversation list)
  - `from` / `to` / `dates` search parameters (search scope)
  - Per hour: `recordedSeconds`, `quiet`, `pendingAudio`
  - On memories: `savedAt`, `userConfirmedAt`, `inactivatedAt`, `edited`
