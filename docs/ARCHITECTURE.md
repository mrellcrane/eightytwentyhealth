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
| UserData | `MoodEntry`, `GratitudeEntry`, `ActivityLog` | CloudKit private DB | **No.** Protected 3 ways |
| Cache | `DailySnapshot` (JSON-encoded `SensorDay` per day) | none | Yes, rebuilt by the next sync |

Rules for UserData, because CloudKit enforces them and because this is irreplaceable data:

- Every property optional or defaulted. No `@Attribute(.unique)`. Relationships optional.
- **Schema changes are additive only.** Add optional properties; never rename or remove one.
- **Soft deletes only** (`deletedAt`). Deleted entries stay in backups and block re-import of the same Oura tag or Health mood.
- If the container fails to open, the app shows an error screen and touches nothing.

Oura tokens live in the Keychain, this device only. Oura refresh tokens are single-use, so sharing them across devices would break both. A new phone just reconnects.

### Data safety layers

1. CloudKit sync of UserData.
2. Mirror to Apple Health: mood > State of Mind, meditation > Mindful Minutes, run > Workout + route.
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
- Practices: D-6 through D.

Displayed value = 60/25/15 weighted average of the last three days' readings, so one bad night dents the bar without cratering it.

## Wind-down and morning brief

- **Wind-down**: a daily notification at target bedtime minus lead time (defaults 10:15pm and 45 min), plus a nudge on Today after 8pm. Sleep regularity predicted mortality better than sleep duration in a UK Biobank study of about 60,000 people (Windred 2024, Sleep).
- **Morning brief** (`MorningBrief` in core, tested): after the background sync finds last night's readiness, one notification with both bars, readiness and HRV, whichever component is furthest below 65 if it's something else, and one rule-based action for that component. Phase 2's recommender replaces the rules.
- Background refresh asks iOS for "not before 7:15am". If Oura hasn't uploaded the night yet it retries every ~45 minutes until noon, then gives up for the day. Opening the app in the morning with the night's data in counts as having seen it, so you don't get a duplicate.
- iOS decides when background refresh actually runs, so the brief can be late or skipped. That's a platform limit, not a bug.

## Phase 2: recommendation engine

`interventions.json` in the core package. Each entry: id, title, dose, minutes, target components, effect estimate (effect size or % change), one-line snippet, citation (authors, year, journal, DOI), evidence grade (A meta-analysis of RCTs, B RCT, C observational). Every number and DOI gets verified when the catalog is written.

- **Expected gain** = effect on component x component weight x room to improve (components below your baseline get boosted, so sleep recommendations rise after a bad night).
- **Personal blend**: `estimate = (k * research + n * yours) / (k + n)`. Few logs, mostly research; many logs, mostly you.
- **Rank** by expected gain / minutes, filtered for what's sensible today (no hard workout on a readiness-65 morning).

Starter catalog candidates: mindfulness meditation (Goyal 2014, JAMA Intern Med), cyclic sighing (Balban 2023, Cell Rep Med), walking/strength/yoga for depression (Noetel 2024, BMJ), gratitude writing (Emmons & McCullough 2003; Seligman 2005), sleep regularity (Windred 2024, Sleep), caffeine timing (Drake 2013, JCSM), alcohol and sleep HRV (Pietilä 2018, JMIR Mental Health), 120 min/week in nature (White 2019, Sci Rep), daily steps (Paluch 2022, Lancet Public Health), social connection (Holt-Lunstad 2010, PLOS Med).

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
| Run | `Run/RunTracker`, `Run/Polyline` | `Services/Location/RunRecorder`, `Features/Run` |
| Training | `Training/RunningPlan` (weekly miles, green/yellow/red), `Training/TrainingAdvisor` (cardio/strength/both today), `Training/RunScreenshotParser` | `Features/Run/RunningView`, `Shared/TrainingInput`, `Services/ScreenshotReader`, Today's training card |
| Meditation | `Meditation/MeditationTimer` | `Features/Meditation`, `Services/Notifications` |
| Patterns | `Patterns/Stats`, `Patterns/PatternFinder` | `Features/Insights` |
| Coach | `Coach/CoachBriefing` (system prompt + data snapshot, app links) | `Services/Coach/CoachSession` (Messages API, streamed, `claude-haiku-5-5`), `Features/Coach/CoachView`; key in Keychain, notes in Settings |
| Mood | `Mood/MoodScale` | `Features/Log` |
| Morning brief | `Briefing/MorningBrief` | `AppModel` (send/retry), `Services/Notifications` |
