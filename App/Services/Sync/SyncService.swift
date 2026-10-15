import Foundation
import SwiftData
import EightyTwentyCore

/// Pulls Oura + Apple Health into the local cache and imports anything you
/// logged elsewhere (Oura tags and Moments, moods from Apple's Health app).
@MainActor
@Observable
final class SyncService {
    /// First sync pulls this much history so baselines exist from day one.
    static let initialHistoryDays = 120
    /// Later syncs re-pull this window, because Oura revises recent days.
    static let refreshWindowDays = 10

    private(set) var isSyncing = false
    private(set) var lastError: String?

    private(set) var lastSyncedAt: Date? = UserDefaults.standard.object(forKey: "lastSyncedAt") as? Date

    private let oura: OuraAccount
    private let healthKit: HealthKitService

    init(oura: OuraAccount, healthKit: HealthKitService) {
        self.oura = oura
        self.healthKit = healthKit
    }

    func syncIfStale(context: ModelContext, maxAge: TimeInterval = 30 * 60) async {
        if let lastSyncedAt, Date().timeIntervalSince(lastSyncedAt) < maxAge { return }
        await sync(context: context)
    }

    func sync(context: ModelContext) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let repository = Repository(context: context)
        let today = DayKey(date: .now)
        let days = repository.hasAnySensorData ? Self.refreshWindowDays : Self.initialHistoryDays
        let start = today.adding(days: -days)
        let startDate = start.startDate()
        let endDate = today.adding(days: 1).startDate()

        var sensors: [DayKey: SensorDay] = [:]
        var errors: [String] = []

        // 1. Oura
        if oura.isConnected {
            do {
                let bundle = try await fetchOura(start: start, end: today)
                sensors = OuraDayAssembler.assemble(bundle)
                try repository.insertImported(OuraActivityMapper.activities(from: bundle.sessions))
                try repository.insertImported(OuraActivityMapper.activities(from: bundle.tags))
            } catch OuraError.unauthorized, OuraError.notConnected {
                oura.markDisconnected()
                errors.append("Oura sign-in expired. Reconnect in Settings.")
            } catch {
                errors.append("Oura: \(error.localizedDescription)")
            }
        }

        // 2. Apple Health extras, merged onto the same days
        let extras = await healthKit.dailyExtras(from: startDate, to: endDate)
        let existing = repository.sensorDays(since: start)
        let touched = Set(sensors.keys)
            .union(extras.steps.keys).union(extras.vo2Max.keys)
            .union(extras.mindfulMinutes.keys).union(extras.workoutMinutes.keys)
        for day in touched {
            // Start from fresh Oura data if we got it, else keep what's cached.
            var sensor = sensors[day] ?? existing[day] ?? SensorDay(day: day)
            sensor.healthKitSteps = extras.steps[day]
            if let vo2 = extras.vo2Max[day] { sensor.vo2Max = vo2 } // Watch beats ring estimate
            sensor.externalMindfulMinutes = extras.mindfulMinutes[day]
            if let minutes = extras.workoutMinutes[day] {
                sensor.workoutMinutes = max(sensor.workoutMinutes ?? 0, minutes)
            }
            sensors[day] = sensor
        }

        do {
            try repository.upsert(sensors)
        } catch {
            errors.append("Saving: \(error.localizedDescription)")
        }

        // 3. Moods logged in Apple's Health app
        let moods = await healthKit.externalMoods(from: startDate, to: endDate)
        do {
            try repository.insertImported(moods)
        } catch {
            errors.append("Mood import: \(error.localizedDescription)")
        }

        lastError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        if errors.isEmpty || !sensors.isEmpty {
            lastSyncedAt = .now
            UserDefaults.standard.set(lastSyncedAt, forKey: "lastSyncedAt")
        }
    }

    /// One retry with a forced token refresh: a 401 usually just means the
    /// access token expired early.
    private func fetchOura(start: DayKey, end: DayKey) async throws -> OuraBundle {
        do {
            return try await oura.client().bundle(start: start, end: end)
        } catch OuraError.unauthorized {
            _ = try await oura.tokens.accessToken(forceRefresh: true)
            return try await oura.client().bundle(start: start, end: end)
        }
    }
}
