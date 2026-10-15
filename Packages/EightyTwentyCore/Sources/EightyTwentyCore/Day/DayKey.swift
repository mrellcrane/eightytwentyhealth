import Foundation

/// A calendar day in the user's local time, stored as `yyyy-MM-dd`.
///
/// Oura keys everything by local day (sleep is keyed by the morning it ended),
/// so the whole app joins data on this type instead of on `Date`.
public struct DayKey: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard (1...12).contains(month), (1...31).contains(day),
              let date = DayKey.utc.date(from: components) else { return nil }
        // Reject things like Feb 30 that Calendar would silently roll over.
        let check = DayKey.utc.dateComponents([.year, .month, .day], from: date)
        guard check.year == year, check.month == month, check.day == day else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses `yyyy-MM-dd`. Anything after the date (e.g. a time) is rejected.
    public init?(_ string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// The local day that contains `date`.
    public init(date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        // Components from a real Date are always valid.
        self.init(year: c.year!, month: c.month!, day: c.day!)!
    }

    public var rawValue: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public var description: String { rawValue }

    public func adding(days: Int) -> DayKey {
        let shifted = DayKey.utc.date(byAdding: .day, value: days, to: utcDate)!
        let c = DayKey.utc.dateComponents([.year, .month, .day], from: shifted)
        return DayKey(year: c.year!, month: c.month!, day: c.day!)!
    }

    /// Whole days from `self` to `other` (positive when `other` is later).
    public func days(until other: DayKey) -> Int {
        DayKey.utc.dateComponents([.day], from: utcDate, to: other.utcDate).day!
    }

    /// Start of this day in the given calendar's time zone.
    public func startDate(in calendar: Calendar = .current) -> Date {
        var c = DateComponents()
        c.year = year
        c.month = month
        c.day = day
        return calendar.date(from: c)!
    }

    /// Inclusive range of days, oldest first.
    public static func range(from start: DayKey, through end: DayKey) -> [DayKey] {
        guard start <= end else { return [] }
        let count = start.days(until: end)
        return (0...count).map { start.adding(days: $0) }
    }

    public static func < (lhs: DayKey, rhs: DayKey) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    // MARK: Codable as a plain "yyyy-MM-dd" string

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let key = DayKey(raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid day: \(raw)")
        }
        self = key
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    // MARK: Private

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private var utcDate: Date {
        var c = DateComponents()
        c.year = year
        c.month = month
        c.day = day
        return DayKey.utc.date(from: c)!
    }
}
