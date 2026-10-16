# Coach feature: handoff (work in progress)

Delete this file once the feature ships; fold the design into `ARCHITECTURE.md`.

## What the owner asked for

1. Tap the **Mental** bar to open a Mental screen.
2. Say how they're feeling and why, log feelings a bit, and get a **science-based recommendation** from Claude (the API is fine to use).
3. **Anything** they're dealing with, not just mood. Their real test case, verbatim:
   > "i slept well last night after a 4.5 mile run yesterday and felt great this morning (you can see my oura ring) but now at 1pm (you should be able to see the time) i feel like i just hit a wall and am so freaking tired and have a bit of a headache. what should i do? i still have a couple more hours of work to do"
4. Claude must have context: time, Oura data, recent logs, and their **work schedule: 6am to 3/4pm** (make it a setting; default 6:00 AM to 4:00 PM, weekdays).
5. One-tap recommendations they can log without describing a problem, like "Do CBT: improve immediate stress and anxiety by 12%". Numbers must be honest (see ARCHITECTURE "Honest numbers").

## Decisions already made

- **Claude call is raw HTTP** from Swift (no official Swift SDK), built in the core package so it's unit tested. `POST /v1/messages`, model `claude-opus-5-5`, `output_config: {effort: "medium", format: {type: "json_schema", schema}}`, thinking omitted (adaptive by default on Opus 5.5), `max_tokens` 16000, non-streaming, timeout 120 s.
- **Server-side fallback on by default**: body `"fallbacks": "default"` + header `anthropic-beta: server-side-fallback-2026-07-01`. If the API ever 400s mentioning "fallback", the client retries once without it. Tell the owner it's on.
- **Follow-ups are append-only.** Assistant turns are replayed as a single text block with Claude's exact JSON text; thinking blocks are not replayed (no tools, so nothing needs them; dropping all of them keeps preserved-thinking checks happy).
- **No web search tool** (untested combo with structured output). Claude cites from knowledge; the UI labels Claude's citations as "cited by Claude" with a Google Scholar link to check, and labels catalog entries as "checked".
- **API key on the phone**: pasted in Settings, stored in the Keychain (`Keychain` gets a `service` parameter; use service `eightytwenty.claude`). Never baked into the binary (public repo).
- **Key for live tests in cloud sessions**: environment variable `CLAUDE_COACH_API_KEY` (not `ANTHROPIC_API_KEY`, which Claude Code itself may read). Never print it.
- **Percent shown** = effect size × 33 (`EffectEstimate`), labeled "≈" and "research estimate". Conservative ratio-of-means conversion; explained in a footer and in the doc comment.
- **Personal results**: logging a step asks optional 0-10 "how strong was it" before/after. Per-intervention average shown once n ≥ 3; ranking uses `(5 × research + n × yours) / (5 + n)`.
- **Ranking**: expected percent × relevance / minutes. ×1.5 if it targets the weakest Mental component below 65; ×0.3 outside its sensible hours.
- **Crisis**: reply has `crisis: Bool`; if true the app shows 988 call/text first. Also a static 988 footer on the Mental screen. `seeADoctor` for headache red flags etc.
- **Privacy**: never log the user's text, Claude's answer, or health values to Sentry. Log only status codes, durations, step counts. Add `Log.coach` category (update CLAUDE.md's category list).
- CloudKit is pinned to the Development environment, so new optional fields on `ActivityLog` auto-create their schema.

## Done (uncommitted work pushed as WIP, core does NOT compile yet)

- `ActivityKind`: new cases `reframe, journaling, selfCompassion, relaxation, music, kindness, nap, other` (titles, symbols, measures; the first four count as mental practices).
- `ActivityRecord` (backup): optional `interventionID`, `intensityBefore`, `intensityAfter` with nil defaults.
- `Coach/Intervention.swift`: `Intervention`, `Evidence`, `EffectEstimate`, `InterventionLog`, `PersonalEffect`, `RankedIntervention`, `InterventionRanker`. Refers to `Intervention.catalog`, which doesn't exist yet: that's the compile error.
- `Coach/JSONValue.swift`: Codable JSON value with literals.
- `Coach/CoachClient.swift`: `CoachReply` (summary, steps[title, minutes, how, why, effect, source, catalogID, logAs], avoid, seeADoctor, crisis), `CoachError` + user messages, `CoachConversation` (append-only), `CoachRequest` (body, headers, JSON schema with enums from catalog ids and ActivityKind, system prompt incl. catalog summary), `CoachClient` (send, parse, refusal/max_tokens handling, fallback retry).

## To do

### Core (`Packages/EightyTwentyCore`)
1. `Coach/InterventionCatalog.swift`: `extension Intervention { public static let catalog: [Intervention] }`. Every effect size and DOI must be verified against the paper (web search) before it goes in. Candidates and what to verify:
   - Cyclic sighing 5 min (Balban 2023, Cell Rep Med, 10.1016/j.xcrm.2022.100895) and/or breathwork meta-analysis (Fincham 2023, Sci Rep) for stress/anxiety. logsAs breathwork.
   - Thought reframe, the CBT skill (Webb, Miles & Sheeran 2012, Psych Bull, reappraisal d+ ~0.36). logsAs reframe.
   - Brisk walk / stair climbing for energy (Reed & Ones 2006; Puetz 2006 Psych Bull; Randolph & O'Connor 2017). logsAs walk.
   - Time in nature (McMahan & Estes 2015, J Posit Psychol). logsAs nature.
   - Music for stress (de Witte 2020, Health Psychol Rev). logsAs music.
   - Progressive muscle relaxation (Manzoni 2008, BMC Psychiatry). logsAs relaxation.
   - Mindfulness meditation (Goyal 2014, JAMA IM). action .meditationTimer.
   - Three good things / gratitude (Seligman 2005; Cregg & Cheavens 2021). action .gratitude.
   - Self-compassion (Ferrari 2019, Mindfulness). Acts of kindness (Curry 2018, JESP).
   - Short afternoon nap (Brooks & Lack 2006, Sleep; 10-min best). logsAs nap, hours ~12...16.
   - Also useful for Claude's context, not necessarily catalog: caffeine 6 h before bed (Drake 2013, JCSM), mild dehydration and headache/fatigue (Armstrong 2012, J Nutr).
   Each entry: id, title, minutes, timing (.rightAway if measured after one session), summary, numbered steps, Evidence(citation, doi, grade, effectSize, outcome phrase, finding), targets (ComponentID: mood, stressBalance, mentalSleep, practice), logsAs, action, hours.
2. `Coach/CoachContext.swift`: renders the context block. Inputs: now + time zone, work hours (start/end minutes, weekdays only) with status ("at work, about 2 h 56 min left" / day off / done), target bedtime and time until it, both bars with component details (they already read as plain English), extras from `SensorDay` (bed/wake times, temperature deviation, SpO2, yesterday's active calories and workout minutes, steps so far today), activity logs from the last 48 h ("Thu 5:40 PM: Run, 38 min, 4.5 mi"), moods from the last 48 h (label, energy, emotions; not notes), today's check-in (mood, energy, emotions), and things tried in the last 30 days with before/after ratings. Use DateFormatter with en_US_POSIX and an explicit time zone so tests are deterministic.
3. Tests: catalog integrity (unique ids, DOI shape, positive effects, steps non-empty), `EffectEstimate`, `PersonalEffect`, ranker (weakest-component boost, off-hours sink), request body (model, fallbacks, schema enums, append-only follow-ups, no thinking replayed), parse (success, refusal, max_tokens, 401/429/529, 400 fallback retry via MockTransport in `OuraTests.swift`), context rendering for the 1pm scenario, backup round trip with the new fields plus an old backup without them.
4. **Live test** `CoachLiveTests`: `XCTSkip` unless `CLAUDE_COACH_API_KEY` is set. Builds the owner's 1pm scenario (good sleep, 4.5-mile run yesterday evening, weekday 1:00 PM, work until 4 PM, bedtime 10:15 PM) and the verbatim question above, prints the reply, asserts it decodes, has 1-3 steps, crisis false. Then a follow-up "I can't nap at work" and checks the plan changes. Needs a small URLSession transport in the test file (FoundationNetworking on Linux). Run it, read the answers, and tune the system prompt until the advice is genuinely good (likely: post-lunch circadian dip, rehydrate with electrolytes after the run, 10-min nap or caffeine before ~2 PM given a 10:15 PM bedtime, brisk walk outside, eat something with protein, headache red flags).

### App (`App/`, compiles only in CI)
- `Persistence/Models.swift`: `ActivityLog` gets optional `interventionID`, `intensityBefore`, `intensityAfter`. `Repository` maps them in backup and restore.
- `Shared/Log.swift`: `Log.coach`. `Shared/Preferences.swift`: `workStartMinutes` (360), `workEndMinutes` (960), `workWeekdaysOnly` (true).
- `Services/Oura/Keychain.swift`: add a `service` parameter (default stays `eightytwenty.oura`).
- `Services/Coach/CoachService.swift` (@MainActor @Observable): key save/remove/has, builds `CoachContext` from SwiftData + prefs, holds the current `CoachConversation`, `ask`/`followUp`, `isThinking`, `error`. Uses `URLSessionTransport` from `OuraAccount.swift`.
- `AppModel`: owns `coach`; `logActivity` gains `interventionID`, `intensityBefore`, `intensityAfter` (mirrors mindful kinds to Health as today).
- `Features/Mental/MentalView.swift`: Mental bar (tap for `BarDetailView`), "What's going on?" card opening `AskView`, "Feel better now" (ranked `.rightAway`) and "Build it up" (`.overWeeks`) lists with headline, minutes, grade, your result when n ≥ 3, footer explaining the ≈ numbers, 988 footer.
- `Features/Mental/AskView.swift`: big text field first; optional 7-face row (tap to select, tap again to clear; selecting means it's saved as a mood check-in with the text as the note), optional energy 1-5 and emotion chips; "Ask" button; "What Claude sees" disclosure showing the exact context; reply cards (summary, crisis card first if set, steps with effect/how/why/source, "Did it" to log, "Details" if catalogID); seeADoctor and avoid lines; follow-up field. Missing key: inline prompt linking to Settings.
- `Features/Mental/InterventionViews.swift`: detail (steps, the science with DOI link, grade, your results, main button per action) and the log sheet (minutes, optional before/after 0-10 menu pickers, note).
- `TodayView`: Mental bar pushes `MentalView`; Physical keeps the sheet. Add a "What's going on?" card that opens `AskView`.
- `SettingsView`: "Claude" section (SecureField + save, saved state, remove; footer: what's sent and when, where the key lives) and "Work hours" (start, end, weekdays only).
- `LogView.RecentRow`: show the intervention title (or the note for `.other`) and "7 → 4" when rated.
- Share the mood faces array between `MoodCheckInView` and `AskView`.

### Ship
- `docs/ARCHITECTURE.md`: replace the Phase 2 placeholder with the coach and catalog; code map rows. `CLAUDE.md`: `coach` log category, the `CLAUDE_COACH_API_KEY` live test.
- Local tests: Swift isn't installed and swift.org downloads are blocked, but Docker Hub works:
  ```sh
  (dockerd > /tmp/dockerd.log 2>&1 &); sleep 5; docker pull swift:6.1
  docker run --rm -e CLAUDE_COACH_API_KEY -v "$PWD/Packages/EightyTwentyCore":/pkg -w /pkg swift:6.1 swift test --scratch-path /tmp/build
  ```
- Push (no `[skip ci]`), watch the run per CLAUDE.md until green, tell the owner the TestFlight build number (100 + run number).
