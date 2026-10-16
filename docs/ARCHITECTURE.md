# 80/20 Health: architecture

## Intent

You already collect plenty of data (Oura, Apple Health). What's missing is a **decision engine**: something that looks at all of it and says "here's the smallest thing you can do today that moves the needle most, here's the science, and here's whether it's working *for you*."

The app has three jobs, in this order:

1. **Show where you stand.** Two bars, Physical and Mental. One glance, no dashboard to interpret.
2. **Name the highest-leverage move.** Rank evidence-backed actions by *expected bar gain per minute of effort*. That ratio is the 80/20.
3. **Learn what works for you.** Start from research averages, replace them with your own numbers as data piles up.

Logging is the bottleneck for job 3, so anything that makes logging automatic (meditation timer, run recorder, Oura tag import, Health import) beats a new feature.

### Honest numbers

Research gives effect sizes ("8 weeks of mindfulness: anxiety effect size about 0.38"), not "your health bar +4%". The app converts effect sizes into bar points with an explicit model, labels them **research estimate**, and switches to **your data (n=14)** once you have enough logs. Correlations are shown as patterns with a sample size, never as proof.

## Data flow

```
Oura API v2 ─┐                                   ┌─> Today (bars, next steps)
             ├─> SyncService ─> DailySnapshot ───┤
Apple Health ┘      │           (cache store)    ├─> Insights (trends, scatter)
                    │                            │
                    └─> imports ─> MoodEntry ────┤
                        (tags,     GratitudeEntry│
                         Moments,  ActivityLog ──┘
                         moods)    (synced store)
                                       │
You (Log, Meditate, Run) ──────────────┘──> mirrored to Apple Health
```

`HealthBarsCalculator` (core package) reads both stores' contents and produces the bars. It's pure Swift and unit tested.

## Storage

Two SwiftData configurations in one container (`App/Persistence/Models.swift`):

| Store | Contents | Sync | Can be lost? |
|---|---|---|---|
| UserData | `MoodEntry`, `GratitudeEntry`, `ActivityLog`, `CoachLog`, `SavedStudy` | CloudKit private DB | **No.** Protected 3 ways |
| Cache | `DailySnapshot` (JSON-encoded `SensorDay` per day) | none | Yes, rebuilt by the next sync |

Rules for UserData, because CloudKit enforces them and because this is irreplaceable data:

- Every property optional or defaulted. No `@Attribute(.unique)`. Relationships optional.
- **Schema changes are additive only.** Add optional properties; never rename or remove one.
- **Soft deletes only** (`deletedAt`). Deleted entries stay in backups and block re-import of the same Oura tag or Health mood.
- If the container fails to open, the app shows an error screen and touches nothing.

Oura tokens and the Claude API key live in the Keychain, this device only (services `eightytwenty.oura` and `eightytwenty.claude`). Oura refresh tokens are single-use, so sharing them across devices would break both. A new phone just reconnects and pastes the key again.

### Data safety layers

1. CloudKit sync of UserData.
2. Mirror to Apple Health: mood > State of Mind, meditation > Mindful Minutes, recorded run or walk > running or walking workout + route (only runs count toward the running plan).
3. Daily plain-JSON `BackupDocument` to iCloud Drive and local Documents (30 kept). Restore merges by id, external id and Health UUID; it never overwrites or deletes. The format only grows (new optional fields).

## Sources and dedupe

- **Oura API v2** is the source of truth for sleep, readiness, HRV, resting HR, temperature, stress, resilience, SpO2, workouts, Moments and tags. OAuth2 authorization code flow (personal access tokens are gone). First sync pulls 120 days; later syncs re-pull 10 because Oura revises recent days.
- **Apple Health** for steps (iPhone/Watch), VO2 max (Watch beats the ring's estimate), workouts, mindful minutes, and State of Mind logged in other apps. Queries **exclude the Oura app's source** (we already have that data from the API) and **this app's source** (already in our store).
- Steps: max of ring and phone/watch, since both undercount.
- Oura tags map to activity kinds by keyword (`OuraActivityMapper`). Morning coffee is ignored; caffeine at or after 2pm becomes "late caffeine". Unknown tags are skipped, never guessed.

## The two bars

Each bar is a weighted average of 0-100 component scores. Missing components are left out and the rest re-weighted; below 40% coverage the bar shows `--` instead of a made-up number.

- Oura scores (readiness, sleep) are used as-is.
- Raw metrics (HRV, resting HR, stress balance, VO2 max) are scored against **your own** rolling baseline with a robust z-score (median and MAD, so one freak day can't warp it), mapped so **75 = your normal** and each robust SD is 12.5 points. The spread never goes below 5% of your normal, so on a very steady week a 2 ms HRV wobble stays noise instead of reading as a drop.
- Steps: percent of an 8,000 step goal (the low end of the 8,000-10,000 range where mortality benefit levels off for adults under 60 in Paluch et al. 2022).

| Physical | Weight | Mental | Weight |
|---|---|---|---|
| Readiness | 30% | Mood | 40% |
| Sleep score | 25% | Stress vs recovery (Oura) | 25% |
| HRV vs baseline | 15% | Sleep score | 15% |
| Resting HR vs baseline | 10% | Practices, last 7 days (target 5) | 20% |
| Steps | 15% | | |
| VO2 max trend (90 days) | 5% | | |

Timing for day D, so the bar doesn't sag every morning just because the day hasn't happened yet:

- Sleep, readiness, HRV, resting HR: the night that ended on the morning of D.
- Steps and daytime stress: D-1, the last complete day.
- Mood: D's check-ins, falling back to D-1's.
- Practices: D-6 through D. A day counts with a gratitude entry, a mental practice (meditation, breathwork, yoga, reframe, journaling, self-compassion, relaxation, time in nature, an act of kindness), or anything logged from the catalog or a coach step that matched it.

Displayed value = 60/25/15 weighted average of the last three days' readings, so one bad night dents the bar without cratering it.

## Wind-down and morning brief

- **Wind-down**: a daily notification at target bedtime minus lead time (defaults 10:15pm and 45 min), plus a nudge on Today after 8pm. Sleep regularity predicted mortality better than sleep duration in a UK Biobank study of about 60,000 people (Windred 2024, Sleep).
- **Morning brief** (`MorningBrief` in core, tested): after the background sync finds last night's readiness, one notification with both bars, readiness and HRV, whichever component is furthest below 65 if it's something else, and one rule-based action for that component.
- Background refresh asks iOS for "not before 7:15am". If Oura hasn't uploaded the night yet it retries every ~45 minutes until noon, then gives up for the day. Opening the app in the morning with the night's data in counts as having seen it, so you don't get a duplicate.
- iOS decides when background refresh actually runs, so the brief can be late or skipped. That's a platform limit, not a bug.

## Mental screen and the Claude coach

There are two Claude features, kept apart on purpose: the **coach** on the Mental screen ("What's going on?": structured steps, the checked catalog, study lookup, saved history; `claude-opus-5-5`) and the **chat** behind the sparkles on Today (open-ended, streamed, sees the running plan and patterns; `claude-haiku-5-5`, see the Chat row in the code map). They share one API key (`ClaudeKey`, Keychain, this device only).

Tap the Mental bar on Today. The screen has the bar (tap for its components), a **What's going on?** card that opens the coach, two ranked lists of evidence-backed steps, past conversations, and the 988 line.

### Intervention catalog

`Coach/InterventionCatalog.swift`, 12 entries. Each has an id, title, minutes, timing, steps, `fits` (the needs from today's data it helps with), the activity kind it logs as, the main button's action, sensible hours, and one `Evidence`: citation, DOI, grade (A meta-analysis, B one RCT, C observational), effect size, outcome phrase and a plain-English finding. **Every effect size and DOI was checked against the paper's abstract or results text** (October 2026); entries whose dose or effect couldn't be confirmed were left out (music, and cyclic sighing's own trial, which reports no standardized effect).

- **Feel better now** (`.rightAway`, measured right after one session): brisk walk, time in nature, thought reframe (CBT), 10-minute nap.
- **Build it up** (`.overWeeks`): cyclic sighing, mindfulness meditation, progressive muscle relaxation, three good things, self-compassion, acts of kindness, regular exercise, expressive writing.

Percent shown = effect size × 33, labeled "≈" and "research estimate" (`EffectEstimate`). On the questionnaires these studies use, one SD is about a third of the typical score or more, so d × 33 is a conservative "percent change from the average". Reframe: d = 0.36, so "≈12% less negative emotion".

### Personal results and ranking

Logging a step asks an optional 0-10 "how strong was it" before and after (`ActivityLog.intensityBefore/After`, `interventionID`). Per-intervention averages show once n ≥ 3, and blend into the estimate as `(5 × research + n × yours) / (5 + n)`. Uncontrolled before/after reads high, which the blend tempers.

`InterventionRanker`: expected percent × relevance / minutes, where relevance comes from **today's real data**, not a fixed order. `RankingSignals.build` turns the data into needs, each with the numbers behind it, shown on the Mental screen under "What your data says":

| Need | From | Example reason |
|---|---|---|
| Low sleep | last night vs your 30-night median (0.75 h short), else Oura sleep score < 70 | "Last night: 5.6 h asleep vs your usual 7.0 h" |
| Low energy | your latest energy rating from the last 3 h (≤ 2), else Oura readiness < 70 | "Energy 2 of 5 at 12:40 PM" |
| Sedentary | steps since you woke, under 300 an hour after 2 h up | "1,240 steps since you woke at 5:24 AM" |
| Stressed | a stress word in today's check-in, else the stress component below 65 (vs your baseline) | "You checked in stressed at 11:20 AM" |
| Low mood | today's check-in slightly unpleasant or worse, else the Mood component below 65 | "Your 11:20 AM check-in: Unpleasant" |
| Few practices | the Practices component below 65 | "Practices: 2 of the last 7 days (target 5)" |

Each catalog entry lists the needs its study outcome supports (`fits`). ×3 if it fits one of today's needs (×1.25 per extra one), ×0.6 if there are needs and it fits none, ×0.3 outside its sensible hours (nap 12-16, nature 7-18, three good things 17-23), ×0.3 for the nap when you rate your energy 4-5 and slept fine, ×0.25 if already done today (by intervention or by activity kind). "Energy right now" (1-5) is a quick picker on Today and the Mental screen; ratings from check-ins and the Ask screen count too. Today shows the top 3 not yet done.

### The coach

Ask anything (mood, stress, energy, sleep, aches, focus). Optional mood face (saved as a check-in with the question as its note), energy 1-5 and feelings. Claude answers with a short read of what's going on and 1-3 steps, each with how, why, effect and source.

- **Request** (`CoachRequest`, raw HTTP, unit tested): `POST /v1/messages`, model `claude-opus-5-5`, `max_tokens` 16000, non-streaming, 120 s timeout, thinking omitted (adaptive by default), `output_config: {effort: "medium", format: {type: "json_schema", schema}}`. The schema's `catalogID` and `logAs` enums come from the catalog ids and `ActivityKind`, so a step can name a checked entry.
- **Server-side fallback** is on: `"fallbacks": "default"` with `anthropic-beta: server-side-fallback-2026-07-01`. If Claude's safety classifier declines, Anthropic retries on its recommended fallback model. If the API ever 400s mentioning "fallback", the client retries once without it.
- **Context** (`CoachContext`, rendered as plain text and shown as "What Claude sees"): local time and zone; work hours (setting, default 6:00 AM-4:00 PM weekdays) with "at work, about 3 h left" / day off / done; target bedtime and the **coffee cutoff** 8.8 h before it (Gardiner 2023); both bars with every component; last night (bed and wake times, hours, efficiency, temperature, SpO2); yesterday (active calories, workout minutes, steps, Oura stress); steps so far; activity logs and moods from the last 48 h (no mood notes); today's check-in; things tried in the last 30 days with ratings.
- **System prompt** (`CoachRequest.systemPrompt`): fit the plan to right now and to work hours, protect tonight's sleep, one action per step, cite only real studies, numbers only when sure, checked facts (post-lunch dip, caffeine and sleep, dehydration, nap length, stair walking) and the catalog summary. Tuned against the owner's real 1 PM case with `CoachLiveTests`.
- **Turns are append-only.** `CoachConversation` holds the turns; messages are rebuilt from them, with Claude's exact JSON text replayed as a single text block. Thinking blocks aren't replayed (no tools, so nothing needs them, and dropping all of them keeps the preserved-thinking check happy). Conversations saved before the chat existed can hold JSON follow-ups; they still show and replay.
- **Talking it through** (`CoachChat`, `CoachChatRequest`, `CoachStream`, unit tested): once the answer is in, a bar under it takes questions about it (why, the research, push back). It continues the same conversation (same model, system prompt and effort) without the JSON format, streamed, with `"cache_control": {"type": "ephemeral"}` at the top level since every turn resends the context. Chat instructions and the studies found for the answer ride in the first chat message; answers go back as text only, like the JSON answer. **Not saved**: the `CoachLog` keeps the answer only, and closing the Ask screen ends the chat.
- **Citations**: catalog steps show the checked headline and a DOI link, labeled "checked". A citation of a saved study links to it, labeled "found by search". Anything else is labeled "cited by Claude" with a Google Scholar link to check it. Normal answers have no web search tool (fast, about 5¢).
- **Look up studies** (`StudyLookupRequest`, `StudyLibrary`): a button under each answer. **Library first**: if 2 or more saved studies match the question (keyword and topic match, loose on word endings), they're shown and nothing is searched. Otherwise a separate call with the `web_search_20260209` tool (up to 5 searches, about a minute, sends only the question, never health data) returns 2-5 studies, skipping the ones already saved. A study is marked **found by search** only when its URL or DOI appeared in that call's search results; anything else shows "from Claude's memory, check it". `pause_turn` is resumed by sending the partial turn back. Everything found is saved as `SavedStudy` (synced, backed up, deduped by DOI or page), attached to the answer in the conversation history, browsable under "Saved studies" on the Mental screen, and matching saved studies go into the next coach context so Claude cites them back.
- **Safety**: `crisis: true` puts the 988 call/text card first; `seeADoctor` carries red flags (for a headache: sudden or worst-ever, fever or stiff neck, vision changes, confusion, weakness, after a head injury, getting worse). The Mental screen always shows 988.
- **Did it**: every step has a Did it button, on the Ask screen and in Coach history. It opens the log sheet prefilled from the step (minutes, kind, catalog id; the step title as the note when it isn't in the catalog), with optional before/after ratings. The log lands in the Log tab, counts toward Practices and "done today", feeds personal results, and the step shows "✓ Logged" with the time, saved with the conversation (`Turn.logged`).
- **History**: every question and answer is saved as a `CoachLog` (UserData store, so CloudKit-synced) and as `coach` records in the JSON backup (`CoachRecord`; older backups without the field still import). **Coach history** lists them: the 5 latest under the Ask button (tap to reopen in place), the 3 latest right under "What's going on?" on the Mental screen, a link under the Ask card on Today, and a full searchable list ("See all"). Any past answer can be reopened and talked through.
- **Privacy**: the key is pasted in Settings and kept in the Keychain, never in the binary (public repo). Sentry gets status codes, durations, turn numbers and step counts only (`Log.coach`), never the question, the answer or the context.

## Meditate screen

`Meditation/MeditationGuide` (core, tested) picks a **style and length for right now** from the same `RankingSignals` as the Mental screen, and the screen shows it with steps, the why, the study, and a one-tap start:

| When | Style | Minutes | Evidence |
|---|---|---|---|
| 8 PM to 5 AM | Body scan | 15 | Rusch 2019: sleep quality +0.33 vs attention-matched controls, no better than proven sleep treatments |
| Stressed (check-in or Oura) | Cyclic sighing | 5 | Fincham 2023 (breathwork, stress g 0.35); Balban 2023 (beat mindfulness on mood) |
| Low mood | Self-compassion | 10 | Ferrari 2019 (stress 0.67, depression 0.66) |
| Otherwise | Breath-focused mindfulness | 13 | Basso 2019: 13 min a day helped at 8 weeks, not 4 |

Below it, "How long and how often" (Basso 2019; Parsons 2017: people in 8-week courses actually did about 30 min a day, 6 days a week, practice-outcome r = 0.26; Strohmaier 2020: bigger doses didn't predict bigger effects across 203 trials) and "What the research says" (Goyal 2014, Galante 2021, Hoge 2023, Khoury 2015, Rusch 2019, Goldberg 2018, Schumer 2018, Brown 2021 on HRV, Farias 2020 on side effects, plus the breathwork and self-compassion evidence). Every number was checked against the abstract or results text. A sit logs as its style's kind (meditation, breathwork or self-compassion) with the catalog id, so it counts toward personal results and "done today".

## Recording runs and walks

`RunRecorder` (GPS via `CLLocationUpdate.liveUpdates(.fitness)`, math in `Run/RunTracker`) records a run or a walk; you pick before starting or after finishing. A walk saves as a Walk log and an outdoor walking workout in Apple Health, and walks never count toward the running plan or its weekly limits (`TrainingInput` keeps them apart; the coach's briefing and the Running screen list them separately).

- **Lock Screen and Dynamic Island**: a Live Activity (`RecordingWidgets` extension, `RecordingAttributes` shared with the app) shows time, distance and average pace. The clock ticks on its own; distance updates at most every 5 seconds, right away on pause, resume and each distance update. Ended on finish, and at launch if one was left behind.
- **Distance updates** (`Run/DistanceCues`, tested): every 0.25, 0.5, 1 or 2 mi or km (default 1), a notification like "2 miles in 18:40 / Average 9:20 /mi. Last mile 9:45.", also read out loud by default (`CueAnnouncer`, ducking music; the `audio` background mode lets it speak with the screen locked). The bell on the recorder changes it, mid-recording too.

## Phase 3: correlation engine

- **Daily feature table**: one row per day. Inputs: logged activities, bedtime, mood, gratitude, Oura tags. Outcomes: that night's sleep and HRV, next-day readiness, next-day mood.
- **Lag on purpose**: what you did on day D vs sleep ending the morning of D+1.
- Binary inputs (meditated yes/no): difference in mean outcome with a bootstrap confidence interval. Continuous inputs (bedtime, minutes): Spearman correlation.
- **Guardrails**: 21+ days total and 7+ days in each group; Benjamini-Hochberg correction across all pairs (test 50 pairs and 2 will "work" by luck); test suite includes a no-real-effect dataset that must produce zero findings.
- **Carryover**: HRV, sleep and steps lean on yesterday, so n days are worth fewer independent ones. p-values use an effective sample size from both series' lag-1 autocorrelation (Bretherton et al. 1999). In simulation this takes the false-alarm rate for two drifting, unrelated series from 23% back to 5%.
- **Built** (`Patterns/Stats`, `Patterns/PatternFinder`, shown in Insights): Spearman r for every pair, yes/no inputs also get with/without averages. Experiments and feeding the recommendation blend are still to come.
- **Experiments**: "no caffeine after 2pm for 14 days" with a before/during comparison. Closer to cause and effect than mining correlations.
- Confirmed personal effects feed the recommendation blend.

## Code map

| Area | Core package (tested on Linux) | App (iOS) |
|---|---|---|
| Days | `Day/DayKey` | |
| Bars | `Scoring/Baseline`, `Scoring/HealthBars`, `Scoring/DayInputs` | `Shared/BarsInput`, `Features/Today` |
| Oura | `Oura/OuraModels`, `OuraDayAssembler`, `OuraActivityMapper`, `OuraClient`, `OuraOAuth` | `Services/Oura/OuraAccount` (token actor, login), `Keychain` |
| Health | | `Services/HealthKit/HealthKitService` |
| Sync | | `Services/Sync/SyncService`, `BackgroundRefresh` |
| Backup | `Backup/BackupDocument` (format, merge, pruning) | `Services/Backup/BackupService`, `Persistence/Repository` |
| Run and walk recorder | `Run/RunTracker`, `Run/Polyline`, `Run/DistanceCues` | `Services/Location/RunRecorder`, `RecordingLiveActivity`, `CueAnnouncer`, `Features/Run`, `Widgets/` (Live Activity) |
| Training | `Training/RunningPlan` (weekly miles, green/yellow/red), `Training/TrainingAdvisor` (cardio/strength/both today), `Training/RunScreenshotParser` | `Features/Run/RunningView`, `Shared/TrainingInput`, `Services/ScreenshotReader`, Today's training card |
| Meditation | `Meditation/MeditationTimer`, `Meditation/MeditationGuide` (styles, plan, findings) | `Features/Meditation`, `Services/Notifications` |
| Patterns | `Patterns/Stats`, `Patterns/PatternFinder` | `Features/Insights` |
| Chat | `Coach/CoachBriefing` (system prompt + data snapshot, app links) | `Services/Coach/CoachSession` (Messages API, streamed, `claude-haiku-5-5`), `Features/Coach/CoachView`; notes in Settings |
| Mood | `Mood/MoodScale` | `Features/Log` |
| Morning brief | `Briefing/MorningBrief` | `AppModel` (send/retry), `Services/Notifications` |
| Interventions | `Coach/Intervention` (estimate, personal blend, ranker), `Coach/InterventionCatalog` | `Features/Mental/MentalView`, `InterventionViews` |
| Coach | `Coach/CoachClient` (request, schema, prompt, parse, conversation, record), `Coach/CoachContext`, `Coach/JSONValue` | `Services/Coach/CoachService`, `Features/Mental/AskView` (ask, reply, history, key) |
| Study lookup | `Coach/StudyLookup` (Study, request, search-result check, library matching) | `CoachService.lookUpStudies`, `AskView` (StudyLookupPanel, StudyCard, StudyLibraryView) |
