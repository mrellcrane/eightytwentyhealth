import Foundation
import SwiftData
import EightyTwentyCore

/// App-wide services and the logging actions views call.
///
/// Every log goes into our own store first (the source of truth), then gets
/// mirrored to Apple Health best-effort. A Health failure never loses an entry.
@MainActor
@Observable
final class AppModel {
    let container: ModelContainer
    let oura: OuraAccount
    let healthKit: HealthKitService
    let backup: BackupService
    let notifications: NotificationService
    let sync: SyncService
    /// Owned here (not by the screens) so a run, a sit or a nap keeps going if you
    /// navigate away, and there's only ever one GPS session.
    let runRecorder: RunRecorder
    let meditation: MeditationSession
    let nap: NapSession
    /// The Mental screen's coach: structured steps, checked research, study lookup.
    let coach: CoachService
    /// Open-ended chat with Claude Haiku about your data (the sparkles button on Today).
    let chat: CoachSession
    /// Coach and chat answers read out loud (ElevenLabs), at 1×, 1.5× or 2×.
    let readAloud: ReadAloudPlayer

    /// Shown as an alert after something non-fatal goes wrong (e.g. Health write denied).
    var notice: String? {
        didSet { if let notice { Log.app.warning("Notice shown: \(notice)") } }
    }
    /// Whether iOS has already shown the Health permission sheet. Nil until checked.
    private(set) var healthAsked: Bool?
    /// Running workouts from Apple Health over the last 120 days. Refreshed on foreground.
    private(set) var healthRuns: [HealthKitRun] = []
    /// The run or walk saved when you last finished recording, for Discard and the run/walk picker.
    private(set) var recorded: ActivityLog?
    /// While the one just recorded is going into Apple Health.
    private(set) var savingToHealth = false
    private var checkedForRecording = false

    init(container: ModelContainer) {
        let oura = OuraAccount()
        let healthKit = HealthKitService()
        self.container = container
        self.oura = oura
        self.healthKit = healthKit
        self.backup = BackupService()
        self.notifications = NotificationService.shared
        self.sync = SyncService(oura: oura, healthKit: healthKit)
        self.runRecorder = RunRecorder(usesMiles: Units.defaultUsesMiles)
        self.meditation = MeditationSession()
        self.nap = NapSession()
        self.coach = CoachService()
        self.chat = CoachSession()
        self.readAloud = ReadAloudPlayer()
    }

    var context: ModelContext { container.mainContext }

    // MARK: Lifecycle

    func onForeground() async {
        await recoverRecording()
        // A nap whose alarm rang while the app was in the background or closed.
        nap.logIfOver(using: self)
        await applyReminderSettings()
        await refreshHealthStatus()
        await sync.syncIfStale(context: context)
        await refreshRuns()
        markMorningBriefSeenIfLooking()
        await backup.backupIfDue(context: context)
        BackgroundRefresh.schedule()
    }

    func backgroundRefresh() async {
        await sync.sync(context: context)
        await backup.backupIfDue(context: context)
        if await sendMorningBriefIfReady() {
            BackgroundRefresh.schedule()
        } else {
            // Oura usually hasn't uploaded last night until you open its app; try again soon.
            BackgroundRefresh.schedule(earliest: .now.addingTimeInterval(45 * 60))
        }
    }

    func refreshHealthStatus() async {
        healthAsked = await healthKit.hasAskedForAuthorization()
    }

    func connectHealth() async {
        do {
            try await healthKit.requestAuthorization()
            await refreshHealthStatus()
            await sync.sync(context: context)
        } catch {
            notice = "Apple Health: \(error.localizedDescription)"
        }
    }

    // MARK: Running

    func refreshRuns() async {
        let end = Date.now
        let start = Calendar.current.date(byAdding: .day, value: -120, to: end) ?? end
        healthRuns = await healthKit.runs(from: start, to: end)
        Log.health.info("Runs from Health: \(healthRuns.count)")
    }

    /// A run Apple Health doesn't have: a Strava screenshot, treadmill miles.
    func logManualRun(miles: Double, on date: Date) {
        context.insert(ActivityLog(timestamp: date, kind: .run, distanceMeters: miles * RunningPlan.metersPerMile, source: .manual))
        save()
        Log.app.info("Run added by hand")
    }

    // MARK: Coach

    /// Everything the coach gets told about you, read fresh when a chat starts.
    func coachSnapshot() -> CoachBriefing.Snapshot {
        let snapshots = (try? context.fetch(FetchDescriptor<DailySnapshot>())) ?? []
        let moods = (try? context.fetch(FetchDescriptor<MoodEntry>())) ?? []
        let gratitude = ((try? context.fetch(FetchDescriptor<GratitudeEntry>())) ?? []).filter { $0.deletedAt == nil }
        let activities = ((try? context.fetch(FetchDescriptor<ActivityLog>())) ?? []).filter { $0.deletedAt == nil }
        let input = BarsInput(snapshots: snapshots, moods: moods, gratitude: gratitude, activities: activities)
        let training = TrainingInput(healthRuns: healthRuns, activities: activities)

        var logged: [DayKey: Set<ActivityKind>] = [:]
        for log in activities {
            if let kind = log.activityKind { logged[DayKey(date: log.timestamp), default: []].insert(kind) }
        }
        let today = DayKey(date: .now)
        let firstLog = (activities.map(\.timestamp) + gratitude.map(\.date)).min()
        let patterns = PatternFinder.find(
            in: PatternData(sensors: input.sensors, reports: input.reports, activities: logged,
                            loggingStart: firstLog.map { DayKey(date: $0) }),
            days: DayKey.range(from: today.adding(days: -120), through: today)
        )

        let defaults = UserDefaults.standard
        return CoachBriefing.Snapshot(
            now: .now,
            bars: [input.display(.physical), input.display(.mental)],
            sensors: input.sensors,
            reports: input.reports,
            activities: logged,
            runs: training.runs,
            walks: training.walks,
            checkIns: RunCheckIns.decode(defaults.string(forKey: PrefKey.runCheckIns) ?? ""),
            plan: RunPlanSettings.plan(start: defaults.string(forKey: PrefKey.runPlanStart) ?? "",
                                       miles: defaults.double(forKey: PrefKey.runPlanStartMiles)),
            strengthDays: training.strengthDays,
            patterns: patterns,
            notes: defaults.string(forKey: PrefKey.coachNotes) ?? ""
        )
    }

    // MARK: Bars

    func barsInput() -> BarsInput {
        BarsInput(
            snapshots: (try? context.fetch(FetchDescriptor<DailySnapshot>())) ?? [],
            moods: (try? context.fetch(FetchDescriptor<MoodEntry>())) ?? [],
            gratitude: (try? context.fetch(FetchDescriptor<GratitudeEntry>())) ?? [],
            activities: (try? context.fetch(FetchDescriptor<ActivityLog>())) ?? []
        )
    }

    // MARK: Reminders, wind-down, morning brief

    var bedtimeString: String {
        clockString(minutes: UserDefaults.standard.integer(forKey: PrefKey.bedtimeMinutes))
    }

    /// Re-applies every reminder from settings. Idempotent, so it runs on each launch too.
    func applyReminderSettings() async {
        let defaults = UserDefaults.standard

        let mood = defaults.integer(forKey: PrefKey.moodReminderMinutes)
        await notifications.setReminder(
            .mood, enabled: defaults.bool(forKey: PrefKey.moodReminderOn), hour: mood / 60, minute: mood % 60,
            title: "How are you feeling?",
            body: "10-second check-in. It's the data your Mental bar runs on."
        )

        let gratitude = defaults.integer(forKey: PrefKey.gratitudeReminderMinutes)
        await notifications.setReminder(
            .gratitude, enabled: defaults.bool(forKey: PrefKey.gratitudeReminderOn), hour: gratitude / 60, minute: gratitude % 60,
            title: "Three good things",
            body: "Write down three things that went well today, and why."
        )

        let bedtime = defaults.integer(forKey: PrefKey.bedtimeMinutes)
        let lead = defaults.integer(forKey: PrefKey.windDownLeadMinutes)
        let windDown = (bedtime - lead + 24 * 60) % (24 * 60)
        await notifications.setReminder(
            .windDown, enabled: defaults.bool(forKey: PrefKey.windDownOn), hour: windDown / 60, minute: windDown % 60,
            title: "Start winding down",
            body: "Lights out by \(clockString(minutes: bedtime)). A regular bedtime beats extra hours: in a 60,000-person study, sleep regularity predicted mortality better than sleep length."
        )
    }

    /// Returns true when today's brief is handled (sent, turned off, or too late to matter),
    /// false when it should be retried later this morning.
    func sendMorningBriefIfReady(now: Date = .now) async -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: PrefKey.morningBriefOn) else { return true }
        let today = DayKey(date: now)
        if defaults.string(forKey: PrefKey.morningBriefDay) == today.rawValue { return true }

        let hour = Calendar.current.component(.hour, from: now)
        if hour >= 12 { return true }   // A "morning" brief at 3pm is just noise.
        guard hour >= 5 else { return false }

        let input = barsInput()
        // No readiness yet means Oura hasn't uploaded last night.
        guard input.sensors[today]?.readinessScore != nil,
              let brief = MorningBrief.compose(
                  physical: input.display(.physical, on: today),
                  mental: input.display(.mental, on: today),
                  bedtime: bedtimeString
              ) else { return false }

        await notifications.post(id: NotificationService.morningBriefID, title: brief.title, body: brief.body)
        defaults.set(today.rawValue, forKey: PrefKey.morningBriefDay)
        return true
    }

    /// If you open the app in the morning and last night's data is in, you've
    /// seen the brief already on the Today screen; don't send it again.
    private func markMorningBriefSeenIfLooking(now: Date = .now) {
        let hour = Calendar.current.component(.hour, from: now)
        guard (5..<12).contains(hour) else { return }
        let today = DayKey(date: now)
        if barsInput().sensors[today]?.readinessScore != nil {
            UserDefaults.standard.set(today.rawValue, forKey: PrefKey.morningBriefDay)
        }
    }

    // MARK: Logging

    func logMood(step: Int, energy: Int?, emotions: [String], note: String?, at date: Date = .now) async {
        let valence = MoodScale.valence(forStep: step)
        let entry = MoodEntry(timestamp: date, valence: valence, energy: energy, emotions: emotions, note: note.nilIfBlank)
        context.insert(entry)
        save()
        do {
            entry.healthKitUUID = try await healthKit.saveMood(valence: valence, emotions: emotions, date: date)
            save()
        } catch {
            notice = "Saved here, but not to Apple Health (\(error.localizedDescription))."
        }
    }

    func logGratitude(items: [String], note: String?) {
        let cleaned = items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        context.insert(GratitudeEntry(items: cleaned, note: note.nilIfBlank))
        save()
    }

    func logActivity(_ kind: ActivityKind, minutes: Double?, amount: Double?, at date: Date, note: String?,
                     interventionID: String? = nil, intensityBefore: Int? = nil, intensityAfter: Int? = nil) async {
        let entry = ActivityLog(timestamp: date, kind: kind, minutes: minutes, amount: amount, note: note.nilIfBlank)
        entry.interventionID = interventionID
        entry.intensityBefore = intensityBefore
        entry.intensityAfter = intensityAfter
        context.insert(entry)
        save()
        if kind.isMindful, let minutes, minutes > 0 {
            entry.healthKitUUID = try? await healthKit.saveMindfulSession(start: date, end: date.addingTimeInterval(minutes * 60))
            save()
        }
    }

    func logMeditation(start: Date, end: Date, minutes: Double, kind: ActivityKind = .meditation,
                       interventionID: String? = nil) async {
        let entry = ActivityLog(timestamp: start, kind: kind, minutes: minutes, source: .meditationTimer)
        entry.interventionID = interventionID
        context.insert(entry)
        save()
        do {
            entry.healthKitUUID = try await healthKit.saveMindfulSession(start: start, end: end)
            save()
        } catch {
            notice = "Logged here, but not to Apple Health (\(error.localizedDescription))."
        }
    }

    /// A nap from the Nap screen. Kept here only: in Apple Health a nap is sleep,
    /// which needs another permission, and the ring already records your sleep.
    func logNap(start: Date, minutes: Double) {
        context.insert(ActivityLog(timestamp: start, kind: .nap, minutes: minutes, source: .napTimer))
        save()
        Log.app.info("Nap logged")
    }

    /// Finish stops the clock and saves the run or walk straight away: to the log, then
    /// Apple Health. Discard takes it back out (`discardRecording`).
    func finishRecording() async {
        // A second tap that lands before the screen changes mustn't save it twice.
        guard runRecorder.state == .running || runRecorder.state == .paused else { return }
        runRecorder.finish()
        await saveRecording()
    }

    private func saveRecording() async {
        let recorder = runRecorder
        let tracker = recorder.tracker
        guard let start = tracker.startedAt, let end = tracker.endedAt else { return }
        let kind = recorder.activity
        let moving = tracker.movingTime(at: end)
        let polyline = Polyline.encode(tracker.route.map { (latitude: $0.latitude, longitude: $0.longitude) })

        let entry = ActivityLog(
            timestamp: start,
            kind: kind,
            minutes: moving / 60,
            distanceMeters: tracker.distance,
            source: .runRecorder,
            routePolyline: polyline.isEmpty ? nil : polyline
        )
        context.insert(entry)
        save()
        recorded = entry
        recorder.clearJournal()
        Log.app.info("Recorded \(kind.rawValue) saved to the log")

        // The run/walk picker and Discard wait for this, so Health ends up matching the log.
        savingToHealth = true
        do {
            entry.healthKitUUID = try await healthKit.saveWorkout(
                kind,
                start: start,
                end: end,
                distances: tracker.distanceSamples,
                kilograms: Units.bodyKilograms,
                // Stops too, so Health's duration is moving time, like the log's.
                pauses: (tracker.pauses + tracker.stops).sorted { $0.start < $1.start },
                route: recorder.routeLocations
            )
            save()
            let calories = Units.bodyKilograms == nil ? "no weight set"
                : healthKit.canWriteActiveEnergy ? "with calories" : "Active Energy not allowed"
            Log.health.info("Recorded \(kind.rawValue) saved to Apple Health, \(calories)")
        } catch {
            notice = "\(kind.title) saved here, but not to Apple Health (\(error.localizedDescription))."
            Log.health.warning("Recorded \(kind.rawValue) not saved to Apple Health: \(error.localizedDescription)")
        }
        savingToHealth = false
        await refreshRuns()
    }

    /// Discard, after finishing: the run or walk comes back out of the log and Apple Health.
    func discardRecording() async {
        guard let log = recorded else { return }
        recorded = nil
        delete(log)
        Log.app.info("Recorded \(log.kind) discarded")
        if let uuid = log.healthKitUUID {
            do {
                try await healthKit.deleteWorkout(uuid)
            } catch {
                notice = "Discarded here, but it's still in Apple Health (\(error.localizedDescription)). You can delete it in the Health app."
                Log.health.warning("Couldn't delete the workout from Health: \(error.localizedDescription)")
            }
        }
        await refreshRuns()
    }

    /// A run or walk the app closed in the middle of (a crash, an update installing) comes
    /// back from disk once per launch: paused where it stopped if that was in the last half
    /// hour, so you can carry on, otherwise saved as it was.
    private func recoverRecording() async {
        guard !checkedForRecording else { return }
        checkedForRecording = true
        guard runRecorder.restore() else { return }
        let noun = runRecorder.activity.title.lowercased()
        if runRecorder.state == .finished {
            // The same start already in the log means it was saved and only the copy on disk was left.
            let start = runRecorder.tracker.startedAt
            let logs = (try? context.fetch(FetchDescriptor<ActivityLog>())) ?? []
            if logs.contains(where: { $0.deletedAt == nil && $0.source == ActivitySource.runRecorder.rawValue && $0.timestamp == start }) {
                runRecorder.reset(usesMiles: runRecorder.tracker.splitDistance > 1000)
                return
            }
            await saveRecording()
            notice = "The app closed in the middle of your \(noun), so it was saved where it stopped."
        } else {
            notice = "The app closed in the middle of your \(noun). It's paused where it stopped. To carry on or finish, open Running, then Record a run here."
        }
    }

    /// Turns a logged run into a walk, or a walk into a run: here, and in Apple Health,
    /// where it's saved again as the other kind (a workout's type can't be edited).
    func change(_ log: ActivityLog, to kind: ActivityKind) async {
        guard let was = log.activityKind, was != kind else { return }
        log.kind = kind.rawValue
        save()
        Log.app.info("Changed a logged \(was.rawValue) to a \(kind.rawValue)")
        if let uuid = log.healthKitUUID {
            do {
                if let replacement = try await healthKit.resaveWorkout(uuid, as: kind, kilograms: Units.bodyKilograms) {
                    log.healthKitUUID = replacement
                    save()
                    Log.health.info("Workout saved again as a \(kind.rawValue)")
                } else {
                    Log.health.info("No workout in Health to change")
                }
            } catch {
                notice = "Changed here, but Apple Health still has it as a \(was.title.lowercased()) (\(error.localizedDescription)). You can delete it in the Health app."
                Log.health.warning("Couldn't change the workout in Health: \(error.localizedDescription)")
            }
        }
        // Runs from Health feed the running plan.
        await refreshRuns()
    }

    /// Soft delete: hidden everywhere, kept in backups, never re-imported.
    func delete(_ mood: MoodEntry) { mood.deletedAt = .now; save() }
    func delete(_ entry: GratitudeEntry) { entry.deletedAt = .now; save() }
    func delete(_ log: ActivityLog) { log.deletedAt = .now; save() }
    func delete(_ log: CoachLog) { log.deletedAt = .now; save() }
    func delete(_ study: SavedStudy) { study.deletedAt = .now; save() }

    private func save() {
        do {
            try context.save()
        } catch {
            notice = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

extension Optional where Wrapped == String {
    var nilIfBlank: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
