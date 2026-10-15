import Foundation

// Oura API v2 response models. Field names follow Oura's OpenAPI spec and are
// decoded with `.convertFromSnakeCase`. Everything except `id`/`day` is optional
// because Oura returns nulls freely (ring not worn, data not synced yet), and a
// single unexpected null must never make a whole sync fail.

public struct OuraPage<Item: Decodable>: Decodable {
    public let data: [Item]
    public let nextToken: String?
}

public struct OuraDailyReadiness: Decodable, Sendable {
    public let id: String
    public let day: String
    public let score: Double?
    public let temperatureDeviation: Double?
}

public struct OuraDailySleep: Decodable, Sendable {
    public let id: String
    public let day: String
    public let score: Double?
}

/// One sleep period. A day can have several (naps, rests); see `OuraDayAssembler`.
public struct OuraSleepPeriod: Decodable, Sendable {
    public let id: String
    public let day: String
    /// "long_sleep", "sleep", "late_nap", "rest" or "deleted".
    public let type: String?
    public let bedtimeStart: String?
    public let bedtimeEnd: String?
    public let averageHrv: Double?
    public let averageHeartRate: Double?
    public let lowestHeartRate: Double?
    /// Seconds.
    public let totalSleepDuration: Double?
    /// Seconds.
    public let timeInBed: Double?
    public let efficiency: Double?
}

public struct OuraDailyActivity: Decodable, Sendable {
    public let id: String
    public let day: String
    public let score: Double?
    public let steps: Double?
    public let activeCalories: Double?
}

public struct OuraDailyStress: Decodable, Sendable {
    public let id: String
    public let day: String
    /// Seconds of high stress.
    public let stressHigh: Double?
    /// Seconds of high recovery.
    public let recoveryHigh: Double?
    /// "restored", "normal" or "stressful".
    public let daySummary: String?
}

public struct OuraDailyResilience: Decodable, Sendable {
    public let id: String
    public let day: String
    /// "limited", "adequate", "solid", "strong" or "exceptional".
    public let level: String?
}

public struct OuraDailySpO2: Decodable, Sendable {
    public struct Percentage: Decodable, Sendable {
        public let average: Double?
    }
    public let id: String
    public let day: String
    public let spo2Percentage: Percentage?
}

public struct OuraVO2Max: Decodable, Sendable {
    public let id: String
    public let day: String
    public let vo2Max: Double?
}

public struct OuraWorkout: Decodable, Sendable {
    public let id: String
    public let day: String
    public let activity: String?
    public let startDatetime: String?
    public let endDatetime: String?
    public let intensity: String?
    public let calories: Double?
    public let distance: Double?
    public let label: String?
}

/// Oura "Moments": guided or unguided meditation, breathing, rest, etc.
public struct OuraSession: Decodable, Sendable {
    public let id: String
    public let day: String
    /// "breathing", "meditation", "nap", "relaxation", "rest" or "body_status".
    public let type: String?
    public let startDatetime: String?
    public let endDatetime: String?
}

public struct OuraEnhancedTag: Decodable, Sendable {
    public let id: String
    public let tagTypeCode: String?
    public let startTime: String?
    public let endTime: String?
    public let startDay: String
    public let endDay: String?
    public let comment: String?
    public let customName: String?
}

/// Everything a sync pulls for a date range.
public struct OuraBundle: Sendable {
    public var readiness: [OuraDailyReadiness] = []
    public var dailySleep: [OuraDailySleep] = []
    public var sleepPeriods: [OuraSleepPeriod] = []
    public var activity: [OuraDailyActivity] = []
    public var stress: [OuraDailyStress] = []
    public var resilience: [OuraDailyResilience] = []
    public var spo2: [OuraDailySpO2] = []
    public var vo2Max: [OuraVO2Max] = []
    public var workouts: [OuraWorkout] = []
    public var sessions: [OuraSession] = []
    public var tags: [OuraEnhancedTag] = []

    public init() {}
}

public enum OuraJSON {
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    /// Parses Oura timestamps like `2026-10-14T22:12:30-07:00` or `...30.000+00:00`.
    public static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string)
    }

    /// Hour of day as written in a local timestamp (`2026-10-14T15:30:00...` gives 15),
    /// regardless of offset. Used for "was this caffeine after 2pm *where you were*".
    public static func localHour(_ string: String?) -> Int? {
        guard let string, string.count >= 13 else { return nil }
        let start = string.index(string.startIndex, offsetBy: 11)
        let end = string.index(start, offsetBy: 2)
        return Int(string[start..<end])
    }
}
