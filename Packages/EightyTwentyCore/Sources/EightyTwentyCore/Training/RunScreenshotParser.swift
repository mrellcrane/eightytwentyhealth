import Foundation

/// Pulls a run's distance and day out of a screenshot's text (Strava's activity page
/// or share card), since Strava won't share runs with other apps. The text comes
/// from on-device recognition; you confirm the numbers before anything is saved.
public enum RunScreenshotParser {
    public struct Result: Equatable, Sendable {
        public var miles: Double?
        /// Noon on the run's day.
        public var date: Date?
    }

    public static func parse(_ lines: [String], now: Date = .now, calendar: Calendar = .current) -> Result {
        let text = lines.joined(separator: "\n")
        return Result(miles: miles(in: text), date: date(in: text, now: now, calendar: calendar))
    }

    /// The first "4.52 mi" or "7.3 km". Pace ("9:45 /mi") has a slash, so it never matches.
    static func miles(in text: String) -> Double? {
        let pattern = #"(?<![\d:/.,])(\d{1,3}(?:[.,]\d{1,2})?)\s*(mi|km)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let numberRange = Range(match.range(at: 1), in: text),
                  let unitRange = Range(match.range(at: 2), in: text),
                  let number = Double(text[numberRange].replacingOccurrences(of: ",", with: ".")),
                  number > 0 else { continue }
            let isKilometers = text[unitRange].lowercased() == "km"
            return isKilometers ? number * 1000 / RunningPlan.metersPerMile : number
        }
        return nil
    }

    /// "October 14, 2026", "Oct 3" (this year, or last year if that's still to come),
    /// "Yesterday at 6:30 PM" or "Today at 7:02 AM".
    static func date(in text: String, now: Date, calendar: Calendar) -> Date? {
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        // Whole month names only, so "Marathon 26" isn't March 26.
        let names = "january|february|march|april|may|june|july|august|september|october|november|december"
            + "|jan|feb|mar|apr|jun|jul|aug|sept|sep|oct|nov|dec"
        let pattern = #"\b("# + names + #")\.?\s+(\d{1,2})(?:,?\s+(\d{4}))?\b"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let monthRange = Range(match.range(at: 1), in: text),
           let dayRange = Range(match.range(at: 2), in: text),
           let month = months.firstIndex(of: String(text[monthRange].lowercased().prefix(3))),
           let day = Int(text[dayRange]) {
            let yearRange = Range(match.range(at: 3), in: text)
            let explicitYear = yearRange.flatMap { Int(text[$0]) }
            var components = DateComponents()
            components.year = explicitYear ?? calendar.component(.year, from: now)
            components.month = month + 1
            components.day = day
            components.hour = 12
            if var found = calendar.date(from: components) {
                if explicitYear == nil, found > now, let lastYear = calendar.date(byAdding: .year, value: -1, to: found) {
                    found = lastYear
                }
                return found
            }
        }
        let lower = text.lowercased()
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now) ?? now
        if lower.contains("yesterday") { return calendar.date(byAdding: .day, value: -1, to: noon) }
        if lower.contains("today") { return noon }
        return nil
    }
}
