# 80/20 Health

A personal iOS app that turns Oura + Apple Health data into two numbers (a **Physical** bar and a **Mental** bar) and, over time, tells you the smallest actions that move them most, with the research behind each one and proof from your own data of whether it works for *you*.

The mood tracker, gratitude journal, meditation timer and run recorder do double duty: they're useful on their own, and they're the input data the app needs to find what actually helps you. Oura can't see your mood or whether you meditated.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full design.

## What works now (Phase 1)

- **Today:** Physical and Mental bars (75 = your normal), change vs yesterday and vs your 7-day average, tap a bar to see exactly what built it.
- **Log:** 10-second mood check-in (mirrored to Apple Health State of Mind), three-good-things gratitude, quick-log grid (meditation, breathwork, sunlight, alcohol, late caffeine, etc).
- **Record:** meditation timer with interval bells that ring with the phone locked; Strava-style run recorder (time, distance, pace, splits, GPS route, works with the screen locked) that saves a workout + route to Apple Health.
- **Insights:** 30-day bar trends, bedtime vs HRV scatter, progress toward the 21 days of check-ins needed before pattern finding.
- **Sync:** Oura API v2 (readiness, sleep, HRV, stress, resilience, SpO2, VO2 max, workouts, Moments, tags) + Apple Health (steps, workouts, VO2 max, mindful minutes, moods you log in the Health app). Oura tags like alcohol or late caffeine become activity logs automatically.
- **Your data is safe:** see [Not losing data](#not-losing-data) below.

## Setup (on your Mac)

You need Xcode 16 or newer and an iPhone on iOS 18+.

1. **Apple Developer Program** ($99/yr, developer.apple.com/programs). Needed for iCloud sync. Without it, see step 3's no-iCloud option, and know that free-signed apps stop launching after 7 days until you rebuild.
2. **Register an Oura app** at <https://cloud.ouraring.com/oauth/applications>:
   - Redirect URI: `eightytwenty://oauth-callback`
   - Note the client ID and client secret.
3. **Create your secrets file:**
   ```sh
   cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
   ```
   Fill in `DEVELOPMENT_TEAM`, `BUNDLE_ID_PREFIX` (e.g. `com.yourname`), `OURA_CLIENT_ID`, `OURA_CLIENT_SECRET`. This file is gitignored.
4. **Generate the Xcode project and open it:**
   ```sh
   brew install xcodegen
   xcodegen generate
   open EightyTwenty.xcodeproj
   ```
5. In Xcode, select the **EightyTwenty** target > **Signing & Capabilities**. Automatic signing should pick up HealthKit and iCloud from the entitlements file. If the iCloud section shows a red container, click the refresh button or `+` to create `iCloud.<your bundle id>`.
6. Plug in your phone, pick it as the run destination, hit Run.
7. In the app: **Settings > Connect Oura**, then **Allow Apple Health access**. The first sync pulls 120 days of history so your baselines exist on day one.

If something doesn't compile, it's most likely an Apple API detail (this was written without access to Xcode). Paste the error into Claude and it'll fix it.

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

The scoring math, Oura parsing, OAuth, backup/restore, run tracking and meditation timer live in a pure-Swift package with 60 unit tests (they run on Linux too):

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

1. **Foundation** (done): bars, logging, meditation timer, run recorder, Oura + Health sync, backups.
2. **Recommendations:** evidence catalog with verified citations, "Your 80/20 today" ranked by expected bar gain per minute.
3. **Insights:** correlation engine over your own data (needs ~3 weeks of check-ins), personal effect sizes replacing research averages, experiments ("no caffeine after 2pm for 14 days").
4. **Extras:** widgets, one-tap mood from the lock screen, wind-down reminder, morning brief, weekly review written by Claude.
