import Foundation
import HealthKit
import CoreLocation
import EightyTwentyCore

struct HealthKitMood: Sendable {
    let uuid: UUID
    let date: Date
    let valence: Double
    let labels: [String]
}

/// A running workout from any app (Apple Fitness, this app's recorder).
struct HealthKitRun: Sendable {
    let uuid: UUID
    let start: Date
    let end: Date
    let meters: Double
}

struct HealthKitDailyExtras {
    var steps: [DayKey: Double] = [:]
    var vo2Max: [DayKey: Double] = [:]
    var mindfulMinutes: [DayKey: Double] = [:]
    var workoutMinutes: [DayKey: Double] = [:]
}

/// Reads from and writes to Apple Health.
///
/// Reading skips two kinds of source: the Oura app (we get Oura data straight
/// from its API, so counting its Health copy would double it) and this app
/// (those entries are already in our own store).
@MainActor
final class HealthKitService {
    let store = HKHealthStore()

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var readTypes: Set<HKObjectType> {
        [
            HKQuantityType(.stepCount),
            HKQuantityType(.vo2Max),
            HKCategoryType(.mindfulSession),
            HKObjectType.workoutType(),
            HKQuantityType(.distanceWalkingRunning),
            HKSampleType.stateOfMindType(),
        ]
    }

    private var shareTypes: Set<HKSampleType> {
        [
            HKSampleType.stateOfMindType(),
            HKCategoryType(.mindfulSession),
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
            HKQuantityType(.distanceWalkingRunning),
        ]
    }

    /// True once iOS has shown the permission sheet for everything we use. After that,
    /// asking again shows nothing; changes happen in the Health app. (Whether you
    /// allowed *reading* is private by design, so "asked" is all we can know.)
    func hasAskedForAuthorization() async -> Bool {
        guard isAvailable else { return false }
        let status = try? await store.statusForAuthorizationRequest(toShare: shareTypes, read: readTypes)
        return status == .unnecessary
    }

    func requestAuthorization() async throws {
        guard isAvailable else { return }
        try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
        Log.health.info("Authorization request finished")
    }

    // MARK: Reading

    func dailyExtras(from start: Date, to end: Date) async -> HealthKitDailyExtras {
        guard isAvailable else { return HealthKitDailyExtras() }
        var extras = HealthKitDailyExtras()
        // Each metric is best-effort: a denied permission just leaves that metric empty.
        extras.steps = (try? await dailySteps(from: start, to: end)) ?? [:]
        extras.vo2Max = (try? await dailyVO2Max(from: start, to: end)) ?? [:]
        extras.mindfulMinutes = (try? await dailyDurationMinutes(of: HKCategoryType(.mindfulSession), from: start, to: end)) ?? [:]
        extras.workoutMinutes = (try? await dailyDurationMinutes(of: HKObjectType.workoutType(), from: start, to: end)) ?? [:]
        return extras
    }

    /// Running workouts with their distance, from every app including this one: the
    /// running plan dedupes against our own log by Health UUID, and counts runs that
    /// overlap in time (a watch and this app on the same run) once (`TrainingInput`).
    func runs(from start: Date, to end: Date) async -> [HealthKitRun] {
        guard isAvailable else { return [] }
        let workouts = (try? await samples(of: HKObjectType.workoutType(), from: start, to: end)) ?? []
        let distance = HKQuantityType(.distanceWalkingRunning)
        return workouts.compactMap { sample in
            guard let workout = sample as? HKWorkout, workout.workoutActivityType == .running else { return nil }
            let meters = workout.statistics(for: distance)?.sumQuantity()?.doubleValue(for: .meter())
                ?? workout.totalDistance?.doubleValue(for: .meter())
            guard let meters, meters > 0 else { return nil }
            return HealthKitRun(uuid: workout.uuid, start: workout.startDate, end: workout.endDate, meters: meters)
        }
    }

    /// Moods you logged in Apple's Health app (or another app), for import.
    func externalMoods(from start: Date, to end: Date) async -> [HealthKitMood] {
        guard isAvailable else { return [] }
        let samples = (try? await samples(of: HKSampleType.stateOfMindType(), from: start, to: end)) ?? []
        let own = HKSource.default().bundleIdentifier
        return samples.compactMap { sample in
            guard let mind = sample as? HKStateOfMind, mind.sourceRevision.source.bundleIdentifier != own else { return nil }
            return HealthKitMood(
                uuid: mind.uuid,
                date: mind.startDate,
                valence: mind.valence,
                labels: mind.labels.compactMap { MoodLabels.name(for: $0) }
            )
        }
    }

    private func dailySteps(from start: Date, to end: Date) async throws -> [DayKey: Double] {
        let type = HKQuantityType(.stepCount)
        let sources = try await independentSources(for: type)
        guard !sources.isEmpty else { return [:] }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: start, end: end),
            HKQuery.predicateForObjects(from: sources),
        ])
        let calendar = Calendar.current
        let anchor = calendar.startOfDay(for: start)

        return try await withCheckedThrowingContinuation { continuation in
            // A statistics query (not a raw sum) so iPhone + Watch overlap is de-duplicated.
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: anchor,
                intervalComponents: DateComponents(day: 1)
            )
            query.initialResultsHandler = { _, collection, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                var result: [DayKey: Double] = [:]
                collection?.enumerateStatistics(from: start, to: end) { statistics, _ in
                    if let sum = statistics.sumQuantity()?.doubleValue(for: .count()) {
                        result[DayKey(date: statistics.startDate, calendar: calendar)] = sum
                    }
                }
                continuation.resume(returning: result)
            }
            store.execute(query)
        }
    }

    private func dailyVO2Max(from start: Date, to end: Date) async throws -> [DayKey: Double] {
        let type = HKQuantityType(.vo2Max)
        let sources = try await independentSources(for: type)
        guard !sources.isEmpty else { return [:] }
        let unit = HKUnit(from: "ml/kg*min")
        var result: [DayKey: Double] = [:]
        // Sorted oldest first, so the latest reading of a day wins.
        for case let sample as HKQuantitySample in try await samples(of: type, from: start, to: end, sources: sources) {
            result[DayKey(date: sample.startDate)] = sample.quantity.doubleValue(for: unit)
        }
        return result
    }

    private func dailyDurationMinutes(of type: HKSampleType, from start: Date, to end: Date) async throws -> [DayKey: Double] {
        let sources = try await independentSources(for: type)
        guard !sources.isEmpty else { return [:] }
        var result: [DayKey: Double] = [:]
        for sample in try await samples(of: type, from: start, to: end, sources: sources) {
            result[DayKey(date: sample.startDate), default: 0] += sample.endDate.timeIntervalSince(sample.startDate) / 60
        }
        return result
    }

    private func independentSources(for type: HKSampleType) async throws -> Set<HKSource> {
        let own = HKSource.default().bundleIdentifier
        let all: Set<HKSource> = try await withCheckedThrowingContinuation { continuation in
            let query = HKSourceQuery(sampleType: type, samplePredicate: nil) { _, sources, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: sources ?? [])
                }
            }
            store.execute(query)
        }
        return all.filter { source in
            !source.bundleIdentifier.lowercased().contains("ouraring") && source.bundleIdentifier != own
        }
    }

    private func samples(of type: HKSampleType, from start: Date, to end: Date, sources: Set<HKSource>? = nil) async throws -> [HKSample] {
        var predicates = [HKQuery.predicateForSamples(withStart: start, end: end)]
        if let sources { predicates.append(HKQuery.predicateForObjects(from: sources)) }
        return try await samples(of: type, matching: NSCompoundPredicate(andPredicateWithSubpredicates: predicates))
    }

    private func samples(of type: HKSampleType, matching predicate: NSPredicate) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            store.execute(query)
        }
    }

    // MARK: Writing (the second copy of your data)

    func saveMood(valence: Double, emotions: [String], date: Date) async throws -> UUID {
        let sample = HKStateOfMind(
            date: date,
            kind: .momentaryEmotion,
            valence: valence,
            labels: emotions.compactMap { MoodLabels.label(for: $0) },
            associations: []
        )
        _ = try await store.save(sample)
        return sample.uuid
    }

    func saveMindfulSession(start: Date, end: Date) async throws -> UUID {
        let sample = HKCategorySample(
            type: HKCategoryType(.mindfulSession),
            value: HKCategoryValue.notApplicable.rawValue,
            start: start,
            end: end
        )
        _ = try await store.save(sample)
        return sample.uuid
    }

    /// Saves a recorded run or walk as an outdoor running or walking workout with its
    /// GPS route, so it shows up in Apple Fitness/Health (and anything that syncs from Health).
    /// Only running workouts count toward the running plan (`runs(from:to:)`).
    func saveWorkout(_ kind: ActivityKind, start: Date, end: Date, distances: [DistanceSample], pauses: [PauseInterval],
                     route: [CLLocation]) async throws -> UUID? {
        let events = pauses.flatMap { pause in
            [
                HKWorkoutEvent(type: .pause, dateInterval: DateInterval(start: pause.start, duration: 0), metadata: nil),
                HKWorkoutEvent(type: .resume, dateInterval: DateInterval(start: pause.end, duration: 0), metadata: nil),
            ]
        }
        return try await saveWorkout(kind, start: start, end: end, distances: distances, events: events, route: route)?.uuid
    }

    /// Saves a recorded workout again as `kind` (run or walk), with the same times, distance
    /// samples, pauses and route, then deletes the original and the distance and route saved with it.
    /// Health can't change a workout's type in place. Returns the new workout's UUID, or nil
    /// if the original isn't in Health anymore.
    func resaveWorkout(_ uuid: UUID, as kind: ActivityKind) async throws -> UUID? {
        guard isAvailable,
              let original = try await samples(of: HKObjectType.workoutType(), matching: HKQuery.predicateForObject(with: uuid))
                .first as? HKWorkout else { return nil }
        let routes = try await samples(of: HKSeriesType.workoutRoute(), matching: HKQuery.predicateForObjects(from: original))
        var locations: [CLLocation] = []
        for case let route as HKWorkoutRoute in routes {
            locations += try await self.locations(in: route)
        }
        let distances = try await samples(of: HKQuantityType(.distanceWalkingRunning), matching: HKQuery.predicateForObjects(from: original))
        let copies = distances.compactMap { $0 as? HKQuantitySample }.map {
            DistanceSample(start: $0.startDate, end: $0.endDate, meters: $0.quantity.doubleValue(for: .meter()))
        }
        let events = (original.workoutEvents ?? []).filter { $0.type == .pause || $0.type == .resume }

        // The new one first, so a failure leaves the original as it was.
        guard let replacement = try await saveWorkout(kind, start: original.startDate, end: original.endDate,
                                                      distances: copies, events: events, route: locations) else { return nil }
        let doomed: [HKObject] = [original] + (routes as [HKObject]) + (distances as [HKObject])
        do {
            try await store.delete(doomed)
        } catch {
            // Don't leave it in Health twice.
            try? await store.delete(replacement)
            throw error
        }
        return replacement.uuid
    }

    /// Deletes a workout this app saved, with the distance and route saved with it.
    func deleteWorkout(_ uuid: UUID) async throws {
        guard isAvailable,
              let workout = try await samples(of: HKObjectType.workoutType(), matching: HKQuery.predicateForObject(with: uuid))
                .first as? HKWorkout else { return }
        let routes = try await samples(of: HKSeriesType.workoutRoute(), matching: HKQuery.predicateForObjects(from: workout))
        let distances = try await samples(of: HKQuantityType(.distanceWalkingRunning), matching: HKQuery.predicateForObjects(from: workout))
        let doomed: [HKObject] = [workout] + (routes as [HKObject]) + (distances as [HKObject])
        try await store.delete(doomed)
    }

    private func locations(in route: HKWorkoutRoute) async throws -> [CLLocation] {
        let batches = RouteBatches()
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    batches.locations += locations ?? []
                    if done { continuation.resume(returning: batches.locations) }
                }
            }
            store.execute(query)
        }
    }

    private func saveWorkout(_ kind: ActivityKind, start: Date, end: Date, distances: [DistanceSample], events: [HKWorkoutEvent],
                             route: [CLLocation]) async throws -> HKWorkout? {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = kind == .walk ? .walking : .running
        configuration.locationType = .outdoor

        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
        _ = try await builder.beginCollection(at: start)
        // Many short samples, none over a pause: Health drops the part of a sample that
        // falls in one, so a single sample over the whole workout lost the distance there.
        let samples = distances.filter { $0.meters > 0 }.map { sample in
            HKQuantitySample(
                type: HKQuantityType(.distanceWalkingRunning),
                quantity: HKQuantity(unit: .meter(), doubleValue: sample.meters),
                start: sample.start,
                end: sample.end
            )
        }
        if !samples.isEmpty {
            _ = try await builder.addSamples(samples)
        }
        if !events.isEmpty {
            _ = try await builder.addWorkoutEvents(events)
        }
        _ = try await builder.endCollection(at: end)
        // Annotated so it compiles whether the SDK returns HKWorkout or HKWorkout?.
        let finished: HKWorkout? = try await builder.finishWorkout()
        guard let workout = finished else { return nil }

        if !route.isEmpty {
            let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: .local())
            _ = try await routeBuilder.insertRouteData(route)
            _ = try await routeBuilder.finishRoute(with: workout, metadata: nil)
        }
        return workout
    }
}

/// A route's points as HealthKit hands them over, a batch at a time on its own queue.
private final class RouteBatches: @unchecked Sendable {
    var locations: [CLLocation] = []
}

/// Our emotion words <-> HealthKit State of Mind labels.
enum MoodLabels {
    static let map: [String: HKStateOfMind.Label] = [
        "calm": .calm, "content": .content, "grateful": .grateful, "happy": .happy,
        "hopeful": .hopeful, "joyful": .joyful, "peaceful": .peaceful, "proud": .proud,
        "relieved": .relieved, "confident": .confident, "excited": .excited, "satisfied": .satisfied,
        "anxious": .anxious, "stressed": .stressed, "overwhelmed": .overwhelmed, "irritated": .irritated,
        "frustrated": .frustrated, "sad": .sad, "lonely": .lonely, "drained": .drained,
        "worried": .worried, "disappointed": .disappointed, "angry": .angry, "indifferent": .indifferent,
    ]

    static func label(for name: String) -> HKStateOfMind.Label? { map[name] }

    static func name(for label: HKStateOfMind.Label) -> String? {
        map.first { $0.value == label }?.key
    }
}
