# 80/20 Health

A personal iOS app that turns Oura + Apple Health data into two numbers (a **Physical** bar and a **Mental** bar) and, over time, tells you the smallest actions that move them most, with the research behind each one and proof from your own data of whether it works for *you*.

The mood tracker, gratitude journal, meditation timer and run recorder do double duty: they're useful on their own, and they're the input data the app needs to find what actually helps you. Oura can't see your mood or whether you meditated.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full design.

## What works now (Phase 1)

- **Today:** Physical and Mental bars (75 = your normal), change vs yesterday and vs your 7-day average, tap a bar to see exactly what built it.
- **Log:** 10-second mood check-in (mirrored to Apple Health State of Mind), three-good-things gratitude, quick-log grid (meditation, breathwork, sunlight, alcohol, late caffeine, etc).
- **Record:** meditation timer with interval bells that ring with the phone locked; Strava-style run recorder (time, distance, pace, splits, GPS route, works with the screen locked) that saves a workout + route to Apple Health.
- **Sleep and mornings:** wind-down reminder before your target bedtime (default 10:15pm, 45 min ahead); morning brief notification once Oura has your night: both bars, the number dragging them, one action for the day.
- **Insights:** 30-day bar trends, bedtime vs HRV scatter, progress toward the 21 days of check-ins needed before pattern finding.
- **Sync:** Oura API v2 (readiness, sleep, HRV, stress, resilience, SpO2, VO2 max, workouts, Moments, tags) + Apple Health (steps, workouts, VO2 max, mindful minutes, moods you log in the Health app). Oura tags like alcohol or late caffeine become activity logs automatically.
- **Your data is safe:** see [Not losing data](#not-losing-data) below.

## Setup

Xcode 16+, iOS 18+, paid developer account (for CloudKit).

1. **Oura app** (one time, about 2 minutes). The Oura connector in Claude uses its own registration, which this app can't reuse, and Oura retired personal tokens. At <https://cloud.ouraring.com/oauth/applications> create a new application: any name and description, Redirect URI `eightytwenty://oauth-callback`. Copy the client ID and secret.
2. **Secrets:**
   ```sh
   cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
   ```
   Fill in `DEVELOPMENT_TEAM`, `BUNDLE_ID_PREFIX`, `OURA_CLIENT_ID`, `OURA_CLIENT_SECRET` (gitignored). xcconfig treats `//` as a comment, so if the secret contains `//`, write it as `/$()/`.
3. **Build:**
   ```sh
   brew install xcodegen
   xcodegen generate && open EightyTwenty.xcodeproj
   ```
   Entitlements cover HealthKit, iCloud (CloudKit + Documents) and push. If the iCloud container shows red under Signing & Capabilities, hit refresh to create `iCloud.<bundle id>`.
4. **In the app:** Settings > Connect Oura, then Allow Apple Health access. First sync pulls 120 days so baselines exist on day one.

Written without access to Xcode, so expect a compile nit or two around Apple API signatures. Paste errors to Claude.

## Not losing data

Only what you create in the app is irreplaceable (moods, gratitude, activity logs). Oura and Apple Health data live in their own clouds and are re-downloaded any time. Your entries are protected three ways:

1. **iCloud sync** (SwiftData + CloudKit, private database). Install on a new phone, sign in to the same Apple ID, entries come back.
2. **Apple Health copy.** Moods go to State of Mind, meditations to Mindful Minutes, runs to Workouts. Apple Health syncs through iCloud separately.
3. **Daily JSON backup** to iCloud Drive and to Files > On My iPhone > 80/20 (30 kept). Plain JSON you can read without the app. **Settings > Restore from a backup file** adds anything missing and never overwrites.

Deletes are soft: a deleted entry is hidden but kept in backups.

### Switching phones checklist

- On the old phone: iOS Settings > [your name] > iCloud > make sure **Health** and **iCloud Drive** are on. In the app: **Settings > Back up now**.
- Set up the new phone from your iCloud backup (or Quick Start).
- Build the app onto the new phone from Xcode (apps installed from Xcode aren't restored by iPhone migration). Same bundle ID, same Apple ID.
- Open the app, give it a minute to pull from iCloud, check the Log tab. Reconnect Oura (tokens stay on the old device on purpose) and allow Apple Health access.
- If anything is missing: **Settings > Restore from a backup file** and pick the newest file in iCloud Drive.

Until the app is on your phone: log moods in Apple's Health app (Health > Browse > Mental Wellbeing > State of Mind) and use Oura tags for things like meditation, alcohol or late caffeine. The app imports both on first sync.

## Tests

The scoring math, Oura parsing, OAuth, backup/restore, run tracking and meditation timer live in a pure-Swift package with 66 unit tests (they run on Linux too):

```sh
cd Packages/EightyTwentyCore
swift test
```

## Layout

```
project.yml                 XcodeGen spec (source of truth for the Xcode project)
Config/                     Base.xcconfig, Secrets.example.xcconfig
App/                        The iOS app (SwiftUI, SwiftData, HealthKit, CoreLocation)
  Features/                 Today, Log, Record (Meditation, Run), Insights, Settings
  Services/                 Oura, HealthKit, Sync, Backup, Notifications, Location
  Persistence/              SwiftData models + repository
Packages/EightyTwentyCore/  Pure-Swift logic + tests
docs/ARCHITECTURE.md        Design and roadmap
```

## Roadmap

1. **Foundation** (done): bars, logging, meditation timer, run recorder, Oura + Health sync, backups, wind-down reminder, morning brief.
2. **Recommendations:** evidence catalog with verified citations, "Your 80/20 today" ranked by expected bar gain per minute.
3. **Insights:** correlation engine over your own data (needs ~3 weeks of check-ins), personal effect sizes replacing research averages, experiments ("no caffeine after 2pm for 14 days").
4. **Extras:** widgets, one-tap mood from the lock screen, weekly review written by Claude.
