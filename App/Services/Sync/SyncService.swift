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

    /// Per source, for the one line each on Today: the last sync that worked,
    /// and whether the latest try failed (details stay in `lastError`).
    private(set) var ouraSyncedAt: Date? = UserDefaults.standard.object(forKey: "ouraSyncedAt") as? Date
    private(set) var healthSyncedAt: Date? = UserDefaults.standard.object(forKey: "healthSyncedAt") as? Date
    private(set) var ouraFailed = false
    private(set) var healthFailed = false

    private var ouraBackfilled: Bool {
        get { UserDefaults.standard.bool(forKey: "ouraBackfilled") }
        set { UserDefaults.standard.set(newValue, forKey: "ouraBackfilled") }
    }

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
        // Backfill until a full Oura history pull has succeeded. Keyed on Oura, not on
        // any cached data: Apple Health days alone mustn't stop the first Oura backfill.
        let needsBackfill = !repository.hasAnySensorData || (oura.isConnected && !ouraBackfilled)
        let days = needsBackfill ? Self.initialHistoryDays : Self.refreshWindowDays
        let start = today.adding(days: -days)
        let startDate = start.startDate()
        let endDate = today.adding(days: 1).startDate()

        var sensors: [DayKey: SensorDay] = [:]
        var errors: [String] = []
        var ouraOK = false
        var healthOK = healthKit.isAvailable
        var saved = true

        // 1. Oura
        if oura.isConnected {
            do {
                let bundle = try await fetchOura(start: start, end: today)
                sensors = OuraDayAssembler.assemble(bundle)
                if days == Self.initialHistoryDays { ouraBackfilled = true }
                try repository.insertImported(OuraActivityMapper.activities(from: bundle.sessions))
                try repository.insertImported(OuraActivityMapper.activities(from: bundle.tags))
                ouraOK = true
            } catch OuraError.unauthorized, OuraError.notConnected {
                Log.sync.error("Oura auth failed during sync; disconnecting")
                await oura.disconnect()
                errors.append("Oura sign-in expired. Reconnect in Settings.")
            } catch OuraError.missingScope(let endpoint) {
                errors.append("Oura didn't grant access to \(endpoint). Disconnect and reconnect Oura, and allow everything it asks for.")
            } catch {
                Log.sync.warning("Oura fetch failed: \(String(describing: error))")
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
            saved = false
            errors.append("Saving: \(error.localizedDescription)")
        }

        // 3. Moods logged in Apple's Health app
        let moods = await healthKit.externalMoods(from: startDate, to: endDate)
        do {
            try repository.insertImported(moods)
        } catch {
            healthOK = false
            errors.append("Mood import: \(error.localizedDescription)")
        }

        let summary = "Sync done (\(days)-day window): Oura connected=\(oura.isConnected), \(sensors.count) days, \(moods.count) Health moods"
        if errors.isEmpty {
            Log.sync.info(summary)
        } else {
            Log.sync.error("\(summary), errors: \(errors.joined(separator: " | "))")
        }
        lastError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        if errors.isEmpty || !sensors.isEmpty {
            lastSyncedAt = .now
            UserDefaults.standard.set(lastSyncedAt, forKey: "lastSyncedAt")
        }

        let now = Date()
        ouraFailed = oura.isConnected && !(ouraOK && saved)
        if ouraOK && saved {
            ouraSyncedAt = now
            UserDefaults.standard.set(now, forKey: "ouraSyncedAt")
        }
        healthFailed = healthKit.isAvailable && !(healthOK && saved)
        if healthOK && saved {
            healthSyncedAt = now
            UserDefaults.standard.set(now, forKey: "healthSyncedAt")
        }
    }

    /// One retry with a forced token refresh: a 401 usually just means the
    /// access token expired early.
    private func fetchOura(start: DayKey, end: DayKey) async throws -> OuraBundle {
        do {
            return try await oura.client().bundle(start: start, end: end)
        } catch OuraError.unauthorized {
            Log.sync.warning("Oura API said 401; forcing a token refresh")
            _ = try await oura.tokens.accessToken(forceRefresh: true)
            return try await oura.client().bundle(start: start, end: end)
        }
    }
}
