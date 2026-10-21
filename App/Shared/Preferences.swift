import Foundation

/// UserDefaults keys for `@AppStorage`, in one place.
enum PrefKey {
    static let usesMiles = "usesMiles"
    static let meditationMinutes = "meditationMinutes"
    static let meditationBellMinutes = "meditationBellMinutes"
    /// Nap alarm length, and the nap in progress (a JSON `Nap`) while you sleep.
    static let napMinutes = "napMinutes"
    static let napInProgress = "napInProgress"
    static let moodReminderOn = "moodReminderOn"
    static let moodReminderMinutes = "moodReminderMinutes"
    static let gratitudeReminderOn = "gratitudeReminderOn"
    static let gratitudeReminderMinutes = "gratitudeReminderMinutes"
    static let windDownOn = "windDownOn"
    static let bedtimeMinutes = "bedtimeMinutes"
    static let windDownLeadMinutes = "windDownLeadMinutes"
    static let morningBriefOn = "morningBriefOn"
    /// Day (yyyy-MM-dd) the morning brief was last sent or made unnecessary.
    static let morningBriefDay = "morningBriefDay"
    /// Work hours, minutes since midnight. The coach plans around them.
    static let workStartMinutes = "workStartMinutes"
    static let workEndMinutes = "workEndMinutes"
    static let workWeekdaysOnly = "workWeekdaysOnly"
    /// "Energy right now", 1-5 (0 = not rated), and when, as seconds since 1970.
    /// Counts for `RankingSignals.currentEnergyWindow`.
    static let energyNow = "energyNow"
    static let energyNowAt = "energyNowAt"
    /// Running plan: first Monday (yyyy-MM-dd) and that week's miles. Empty until set up.
    static let runPlanStart = "runPlanStart"
    static let runPlanStartMiles = "runPlanStartMiles"
    /// JSON [yyyy-MM-dd: green/yellow/red], one per run day.
    static let runCheckIns = "runCheckIns"
    static let trainingGoal = "trainingGoal"
    /// What the recorder records when you open it: run or walk, as an `ActivityKind` raw value.
    static let recordActivity = "recordActivity"
    /// Distance updates while recording: every this many miles or km (0 = off), and
    /// whether they're read out loud as well as shown.
    static let cueEvery = "cueEvery"
    static let cueSpeak = "cueSpeak"
    /// Run map: whether every path is drawn or just the researched routes, and the route
    /// you picked to run (stays on the map while you record).
    static let showTrails = "showTrails"
    static let followedRoute = "followedRoute"
    /// What you want the coach to know (history, goals). Sent with each chat, never logged.
    static let coachNotes = "coachNotes"
    /// Coach answers read out loud: speed (1, 1.5 or 2) and the ElevenLabs voice.
    static let readAloudSpeed = "readAloudSpeed"
    static let readAloudVoice = "readAloudVoice"
    static let readAloudVoiceName = "readAloudVoiceName"

    /// Registered at launch so `@AppStorage` defaults and direct UserDefaults reads agree.
    static let defaults: [String: Any] = [
        moodReminderOn: false,
        moodReminderMinutes: 13 * 60,
        gratitudeReminderOn: false,
        gratitudeReminderMinutes: 21 * 60,
        // You asked for these two, so they start on.
        windDownOn: true,
        bedtimeMinutes: 22 * 60 + 15,
        windDownLeadMinutes: 45,
        morningBriefOn: true,
        meditationMinutes: 10,
        meditationBellMinutes: 0,
        napMinutes: 15,
        workStartMinutes: 6 * 60,
        workEndMinutes: 16 * 60,
        workWeekdaysOnly: true,
        cueEvery: 1.0,
        cueSpeak: true,
        showTrails: true,
    ]

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: defaults)
    }
}

enum Units {
    static var defaultUsesMiles: Bool {
        Locale.current.measurementSystem == .us || Locale.current.measurementSystem == .uk
    }

    static func meters(usesMiles: Bool) -> Double { usesMiles ? 1609.344 : 1000 }
    static func label(usesMiles: Bool) -> String { usesMiles ? "mi" : "km" }
}

extension Date {
    /// Minutes since midnight <-> a Date today, for time pickers.
    static func todayAt(minutes: Int) -> Date {
        Calendar.current.startOfDay(for: .now).addingTimeInterval(TimeInterval(minutes * 60))
    }

    var minutesSinceMidnight: Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: self)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}

/// "10:15 PM" style, from minutes since midnight.
func clockString(minutes: Int) -> String {
    Date.todayAt(minutes: minutes).formatted(date: .omitted, time: .shortened)
}
