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
    /// Owned here (not by the screens) so a run or a sit keeps going if you
    /// navigate away, and there's only ever one GPS session.
    let runRecorder: RunRecorder
    let meditation: MeditationSession

    /// Shown as an alert after something non-fatal goes wrong (e.g. Health write denied).
    var notice: String?
    /// Whether iOS has already shown the Health permission sheet. Nil until checked.
    private(set) var healthAsked: Bool?

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
    }

    var context: ModelContext { container.mainContext }

    // MARK: Lifecycle

    func onForeground() async {
        await applyReminderSettings()
        await sync.syncIfStale(context: context)
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

    func logActivity(_ kind: ActivityKind, minutes: Double?, amount: Double?, at date: Date, note: String?) async {
        let entry = ActivityLog(timestamp: date, kind: kind, minutes: minutes, amount: amount, note: note.nilIfBlank)
        context.insert(entry)
        save()
        if kind.isMindful, let minutes, minutes > 0 {
            entry.healthKitUUID = try? await healthKit.saveMindfulSession(start: date, end: date.addingTimeInterval(minutes * 60))
            save()
        }
    }

    func logMeditation(start: Date, end: Date, minutes: Double) async {
        let entry = ActivityLog(timestamp: start, kind: .meditation, minutes: minutes, source: .meditationTimer)
        context.insert(entry)
        save()
        do {
            entry.healthKitUUID = try await healthKit.saveMindfulSession(start: start, end: end)
            save()
        } catch {
            notice = "Logged here, but not to Apple Health (\(error.localizedDescription))."
        }
    }

    /// Saves a finished run. Returns false only if nothing could be saved.
    func logRun(_ recorder: RunRecorder) async -> Bool {
        let tracker = recorder.tracker
        guard let start = tracker.startedAt, let end = tracker.endedAt else { return false }
        let moving = tracker.movingTime(at: end)
        let polyline = Polyline.encode(tracker.route.map { (latitude: $0.latitude, longitude: $0.longitude) })

        let entry = ActivityLog(
            timestamp: start,
            kind: .run,
            minutes: moving / 60,
            distanceMeters: tracker.distance,
            source: .runRecorder,
            routePolyline: polyline.isEmpty ? nil : polyline
        )
        context.insert(entry)
        save()

        do {
            entry.healthKitUUID = try await healthKit.saveRun(
                start: start,
                end: end,
                distanceMeters: tracker.distance,
                pauses: tracker.pauses,
                route: recorder.routeLocations
            )
            save()
        } catch {
            notice = "Run saved here, but not to Apple Health (\(error.localizedDescription))."
        }
        return true
    }

    /// Soft delete: hidden everywhere, kept in backups, never re-imported.
    func delete(_ mood: MoodEntry) { mood.deletedAt = .now; save() }
    func delete(_ entry: GratitudeEntry) { entry.deletedAt = .now; save() }
    func delete(_ log: ActivityLog) { log.deletedAt = .now; save() }

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
