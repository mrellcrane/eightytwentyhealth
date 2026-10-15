import Foundation

/// UserDefaults keys for `@AppStorage`, in one place.
enum PrefKey {
    static let usesMiles = "usesMiles"
    static let meditationMinutes = "meditationMinutes"
    static let meditationBellMinutes = "meditationBellMinutes"
    static let moodReminderOn = "moodReminderOn"
    static let moodReminderMinutes = "moodReminderMinutes"
    static let gratitudeReminderOn = "gratitudeReminderOn"
    static let gratitudeReminderMinutes = "gratitudeReminderMinutes"
}

enum Units {
    static var defaultUsesMiles: Bool {
        Locale.current.measurementSystem == .us || Locale.current.measurementSystem == .uk
    }

    static func meters(usesMiles: Bool) -> Double { usesMiles ? 1609.344 : 1000 }
    static func label(usesMiles: Bool) -> String { usesMiles ? "mi" : "km" }
}

extension Date {
    /// Minutes since midnight <-> a Date today, for reminder time pickers.
    static func todayAt(minutes: Int) -> Date {
        Calendar.current.startOfDay(for: .now).addingTimeInterval(TimeInterval(minutes * 60))
    }

    var minutesSinceMidnight: Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: self)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}
