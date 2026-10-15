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

    /// Shown as a toast after something non-fatal goes wrong (e.g. Health write denied).
    var notice: String?

    init(container: ModelContainer) {
        let oura = OuraAccount()
        let healthKit = HealthKitService()
        self.container = container
        self.oura = oura
        self.healthKit = healthKit
        self.backup = BackupService()
        self.notifications = NotificationService.shared
        self.sync = SyncService(oura: oura, healthKit: healthKit)
    }

    var context: ModelContext { container.mainContext }

    // MARK: Lifecycle

    func onForeground() async {
        await sync.syncIfStale(context: context)
        await backup.backupIfDue(context: context)
        BackgroundRefresh.schedule()
    }

    func backgroundRefresh() async {
        await sync.sync(context: context)
        await backup.backupIfDue(context: context)
        BackgroundRefresh.schedule()
    }

    func connectHealth() async {
        do {
            try await healthKit.requestAuthorization()
            await sync.sync(context: context)
        } catch {
            notice = "Apple Health: \(error.localizedDescription)"
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
