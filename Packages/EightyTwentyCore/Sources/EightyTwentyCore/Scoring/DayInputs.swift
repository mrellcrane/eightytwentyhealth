import Foundation

/// Everything the sensors (Oura ring, iPhone, Apple Watch) said about one day.
///
/// Sleep fields describe the night that *ended* on the morning of `day`,
/// matching Oura's convention. Activity and stress describe the day itself.
public struct SensorDay: Codable, Equatable, Sendable {
    public var day: DayKey

    // Oura
    public var readinessScore: Double?
    public var sleepScore: Double?
    public var sleepSeconds: Double?
    public var sleepEfficiency: Double?
    public var bedtimeStart: Date?
    public var bedtimeEnd: Date?
    public var averageHRV: Double?
    public var lowestHeartRate: Double?
    public var temperatureDeviation: Double?
    public var activityScore: Double?
    public var ouraSteps: Double?
    public var activeCalories: Double?
    public var stressHighMinutes: Double?
    public var recoveryHighMinutes: Double?
    public var stressSummary: String?
    public var resilienceLevel: String?
    public var spo2Average: Double?

    // Apple Health (non-Oura sources only, to avoid double counting)
    public var healthKitSteps: Double?
    public var vo2Max: Double?
    public var workoutMinutes: Double?
    public var externalMindfulMinutes: Double?

    public init(day: DayKey) {
        self.day = day
    }

    /// Phone/watch and ring both undercount (phone left on a desk, ring on the charger),
    /// so the larger of the two is the better guess at steps actually taken.
    public var steps: Double? {
        switch (ouraSteps, healthKitSteps) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }

    public var sleepHours: Double? { sleepSeconds.map { $0 / 3600 } }
}

/// What the user told us about one day.
public struct SelfReportDay: Codable, Equatable, Sendable {
    public var day: DayKey
    /// Valence of each mood check-in, -1 (very unpleasant) to 1 (very pleasant).
    public var moodValences: [Double]
    /// Did a mental practice happen (gratitude entry, meditation, breathwork)?
    public var practiced: Bool

    public init(day: DayKey, moodValences: [Double] = [], practiced: Bool = false) {
        self.day = day
        self.moodValences = moodValences
        self.practiced = practiced
    }

    public var averageValence: Double? {
        guard !moodValences.isEmpty else { return nil }
        return moodValences.reduce(0, +) / Double(moodValences.count)
    }
}

/// Builds per-day self reports from raw log entries.
public enum SelfReportBuilder {
    public struct Mood: Sendable {
        public var timestamp: Date
        public var valence: Double
        public init(timestamp: Date, valence: Double) {
            self.timestamp = timestamp
            self.valence = valence
        }
    }

    public static func build(
        moods: [Mood],
        practiceTimestamps: [Date],
        calendar: Calendar = .current
    ) -> [DayKey: SelfReportDay] {
        var result: [DayKey: SelfReportDay] = [:]
        for mood in moods {
            let key = DayKey(date: mood.timestamp, calendar: calendar)
            result[key, default: SelfReportDay(day: key)].moodValences.append(mood.valence)
        }
        for timestamp in practiceTimestamps {
            let key = DayKey(date: timestamp, calendar: calendar)
            result[key, default: SelfReportDay(day: key)].practiced = true
        }
        return result
    }
}
