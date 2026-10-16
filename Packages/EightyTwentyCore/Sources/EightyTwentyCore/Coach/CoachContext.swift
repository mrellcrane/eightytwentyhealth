import Foundation

/// The block of facts Claude reads before the question: the time, work hours,
/// bedtime, both bars, last night and yesterday from the sensors, and recent logs.
/// Plain text, so the app can show you exactly what gets sent ("What Claude sees").
///
/// Mood notes are never included; activity titles are.
public struct CoachContext: Equatable, Sendable {
    public struct WorkHours: Equatable, Sendable {
        /// Minutes since midnight.
        public var startMinutes: Int
        public var endMinutes: Int
        /// Monday to Friday only.
        public var weekdaysOnly: Bool

        public init(startMinutes: Int, endMinutes: Int, weekdaysOnly: Bool) {
            self.startMinutes = startMinutes
            self.endMinutes = endMinutes
            self.weekdaysOnly = weekdaysOnly
        }
    }

    public struct Activity: Equatable, Sendable {
        public var timestamp: Date
        /// "Run", or the step's title for coach steps.
        public var title: String
        public var minutes: Double?
        public var distanceMeters: Double?
        /// Drinks and the like, with the unit: "2 drinks".
        public var amount: String?

        public init(timestamp: Date, title: String, minutes: Double? = nil, distanceMeters: Double? = nil,
                    amount: String? = nil) {
            self.timestamp = timestamp
            self.title = title
            self.minutes = minutes
            self.distanceMeters = distanceMeters
            self.amount = amount
        }
    }

    public struct Mood: Equatable, Sendable {
        public var timestamp: Date
        public var valence: Double
        /// 1-5.
        public var energy: Int?
        public var emotions: [String]

        public init(timestamp: Date, valence: Double, energy: Int? = nil, emotions: [String] = []) {
            self.timestamp = timestamp
            self.valence = valence
            self.energy = energy
            self.emotions = emotions
        }
    }

    /// What they picked on the Ask screen alongside the question. All optional.
    public struct CheckIn: Equatable, Sendable {
        public var valence: Double?
        public var energy: Int?
        public var emotions: [String]

        public init(valence: Double? = nil, energy: Int? = nil, emotions: [String] = []) {
            self.valence = valence
            self.energy = energy
            self.emotions = emotions
        }

        public var isEmpty: Bool { valence == nil && energy == nil && emotions.isEmpty }
    }

    public var now: Date
    public var timeZone: TimeZone
    public var work: WorkHours?
    /// Minutes since midnight.
    public var bedtimeMinutes: Int?
    public var physical: BarDisplay?
    public var mental: BarDisplay?
    /// Today's sensor day: last night's sleep, steps so far.
    public var today: SensorDay?
    public var yesterday: SensorDay?
    /// Last 48 hours.
    public var activities: [Activity]
    /// Last 48 hours.
    public var moods: [Mood]
    public var checkIn: CheckIn?
    /// Last 30 days, logged from the Mental screen or a coach step.
    public var tried: [InterventionLog]
    /// Saved studies that match the question, found by an earlier lookup.
    public var studies: [Study]
    public var usesMiles: Bool

    public init(now: Date, timeZone: TimeZone, work: WorkHours?, bedtimeMinutes: Int?, physical: BarDisplay?,
                mental: BarDisplay?, today: SensorDay?, yesterday: SensorDay?, activities: [Activity] = [],
                moods: [Mood] = [], checkIn: CheckIn? = nil, tried: [InterventionLog] = [], studies: [Study] = [],
                usesMiles: Bool = true) {
        self.now = now
        self.timeZone = timeZone
        self.work = work
        self.bedtimeMinutes = bedtimeMinutes
        self.physical = physical
        self.mental = mental
        self.today = today
        self.yesterday = yesterday
        self.activities = activities
        self.moods = moods
        self.checkIn = checkIn
        self.tried = tried
        self.studies = studies
        self.usesMiles = usesMiles
    }

    public static let recentWindow: TimeInterval = 48 * 3600
    public static let triedWindow: TimeInterval = 30 * 86400

    public func render() -> String {
        var sections: [String] = []

        var clock = ["Now: \(format(now, "EEEE, MMMM d, yyyy, h:mm a")) (\(timeZone.identifier))"]
        if let work {
            clock.append("Work: \(clockString(work.startMinutes)) to \(clockString(work.endMinutes))"
                + (work.weekdaysOnly ? " on weekdays" : " every day") + ". " + workStatus(work))
        }
        if let bedtimeMinutes {
            clock.append("Target bedtime: \(clockString(bedtimeMinutes)), \(bedtimeStatus(bedtimeMinutes)).")
            clock.append(coffeeCutoffLine(bedtimeMinutes))
        }
        sections.append(clock.joined(separator: "\n"))

        let bars = [physical, mental].compactMap { $0 }
        if !bars.isEmpty {
            var lines = ["Health bars (0-100; 75 is their own normal, below 65 is low; Oura scores are Oura's own):"]
            for bar in bars {
                lines.append(barLine(bar))
                for component in bar.today.components {
                    lines.append("- \(component.id.title): \(component.detail) (score \(Int(component.score.rounded())))")
                }
                if !bar.today.missing.isEmpty {
                    lines.append("- No data: " + bar.today.missing.map(\.title).joined(separator: ", "))
                }
            }
            sections.append(lines.joined(separator: "\n"))
        }

        sections.append(sensorLines().joined(separator: "\n"))

        let recentActivities = activities
            .filter { $0.timestamp <= now && now.timeIntervalSince($0.timestamp) <= Self.recentWindow }
            .sorted { $0.timestamp < $1.timestamp }
        sections.append(
            "Logged in the last 48 hours:\n"
                + (recentActivities.isEmpty ? "- Nothing" : recentActivities.map { "- " + activityLine($0) }.joined(separator: "\n"))
        )

        let recentMoods = moods
            .filter { $0.timestamp <= now && now.timeIntervalSince($0.timestamp) <= Self.recentWindow }
            .sorted { $0.timestamp < $1.timestamp }
        sections.append(
            "Mood check-ins in the last 48 hours:\n"
                + (recentMoods.isEmpty ? "- None" : recentMoods.map { mood in
                    "- \(format(mood.timestamp, "EEE h:mm a")): "
                        + feeling(valence: mood.valence, energy: mood.energy, emotions: mood.emotions)
                }.joined(separator: "\n"))
        )

        if let checkIn, !checkIn.isEmpty {
            sections.append("Right now they report: "
                + feeling(valence: checkIn.valence, energy: checkIn.energy, emotions: checkIn.emotions))
        }

        let recentTries = tried
            .filter { $0.timestamp <= now && now.timeIntervalSince($0.timestamp) <= Self.triedWindow }
            .sorted { $0.timestamp < $1.timestamp }
        if !recentTries.isEmpty {
            sections.append(
                "Tried in the last 30 days (how strong the problem felt, 0-10, before → after; lower is better):\n"
                    + recentTries.map { log in
                        var line = "- \(format(log.timestamp, "MMM d")): \(log.title)"
                        if let before = log.intensityBefore, let after = log.intensityAfter {
                            line += ", \(before) → \(after)"
                        } else {
                            line += ", not rated"
                        }
                        return line
                    }.joined(separator: "\n")
            )
        }

        let saved = studies.filter { $0.foundBySearch && $0.deletedAt == nil }
        if !saved.isEmpty {
            sections.append(
                "Studies from their library that may fit (found by web search earlier):\n"
                    + saved.map { "- \($0.citation): \($0.design). \($0.finding)" }.joined(separator: "\n")
            )
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: Pieces

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    var nowMinutes: Int {
        let c = calendar.dateComponents([.hour, .minute], from: now)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    func workStatus(_ work: WorkHours) -> String {
        let weekday = calendar.component(.weekday, from: now)
        if work.weekdaysOnly, weekday == 1 || weekday == 7 {
            return "Today is a day off."
        }
        let minute = nowMinutes
        if minute < work.startMinutes {
            return "Work starts in \(duration(work.startMinutes - minute))."
        }
        if minute < work.endMinutes {
            return "At work now, about \(duration(work.endMinutes - minute)) left."
        }
        return "Done with work for today."
    }

    /// A regular coffee needs to be this long before bed to leave sleep alone
    /// (Gardiner et al. 2023, Sleep Medicine Reviews: 8.8 h for 107 mg).
    public static let coffeeCutoffMinutes = 528

    /// Minutes until tonight's bedtime, negative once it has passed. Late at night
    /// (or in the small hours) a passed bedtime reads as "ago", not "in 20 hours".
    func minutesUntilBedtime(_ bedtime: Int) -> Int {
        var delta = bedtime - nowMinutes
        if delta > 18 * 60 { delta -= 24 * 60 }
        if delta <= -6 * 60 { delta += 24 * 60 }
        return delta
    }

    func bedtimeStatus(_ bedtime: Int) -> String {
        let delta = minutesUntilBedtime(bedtime)
        return delta >= 0 ? "in \(duration(delta))" : "\(duration(-delta)) ago"
    }

    func coffeeCutoffLine(_ bedtime: Int) -> String {
        let cutoff = (bedtime - Self.coffeeCutoffMinutes + 24 * 60) % (24 * 60)
        let delta = minutesUntilBedtime(bedtime) - Self.coffeeCutoffMinutes
        return "Coffee cutoff for that bedtime (8.8 h before): \(clockString(cutoff)), "
            + (delta >= 0 ? "in \(duration(delta))." : "already passed.")
    }

    func barLine(_ bar: BarDisplay) -> String {
        guard let value = bar.value else { return "\(bar.kind.title) bar: not enough data" }
        var line = "\(bar.kind.title) bar: \(Int(value.rounded()))"
        if let change = bar.changeFromWeekAverage {
            line += " (\(signed(change)) vs their 7-day average)"
        }
        return line
    }

    func sensorLines() -> [String] {
        var night: [String] = []
        if let today {
            if let start = today.bedtimeStart, let end = today.bedtimeEnd {
                night.append("in bed \(format(start, "h:mm a")) to \(format(end, "h:mm a"))")
            }
            if let hours = today.sleepHours {
                night.append(String(format: "%.1f h asleep", hours))
            }
            if let efficiency = today.sleepEfficiency {
                night.append("efficiency \(Int(efficiency.rounded()))%")
            }
            if let temperature = today.temperatureDeviation {
                night.append(String(format: "temperature %@%.1f °C vs usual", temperature >= 0 ? "+" : "", temperature))
            }
            if let spo2 = today.spo2Average {
                night.append("SpO2 \(Int(spo2.rounded()))%")
            }
        }

        var day: [String] = []
        if let yesterday {
            if let calories = yesterday.activeCalories {
                day.append("\(Int(calories.rounded())) active calories")
            }
            if let minutes = yesterday.workoutMinutes, minutes > 0 {
                day.append("\(Int(minutes.rounded())) min of workouts")
            }
            if let steps = yesterday.steps {
                day.append("\(grouped(steps)) steps")
            }
            if let summary = yesterday.stressSummary {
                day.append("Oura daytime stress: \(summary)")
            }
        }

        var lines = [
            night.isEmpty ? "Last night (Oura): no data" : "Last night (Oura): " + night.joined(separator: ", ") + ".",
            day.isEmpty ? "Yesterday: no activity data" : "Yesterday: " + day.joined(separator: ", ") + ".",
        ]
        if let resilience = today?.resilienceLevel ?? yesterday?.resilienceLevel {
            lines.append("Oura resilience: \(resilience).")
        }
        if let steps = today?.steps {
            lines.append("Steps so far today: \(grouped(steps)).")
        }
        return lines
    }

    func activityLine(_ activity: Activity) -> String {
        var parts = [activity.title]
        if let minutes = activity.minutes, minutes > 0 {
            parts.append("\(Int(minutes.rounded())) min")
        }
        if let meters = activity.distanceMeters, meters > 0 {
            let perUnit = usesMiles ? 1609.344 : 1000
            parts.append(String(format: "%.1f %@", meters / perUnit, usesMiles ? "mi" : "km"))
        }
        if let amount = activity.amount {
            parts.append(amount)
        }
        return "\(format(activity.timestamp, "EEE h:mm a")): " + parts.joined(separator: ", ")
    }

    func feeling(valence: Double?, energy: Int?, emotions: [String]) -> String {
        var parts: [String] = []
        if let valence { parts.append(MoodScale.label(forValence: valence)) }
        if let energy { parts.append("energy \(energy) of 5") }
        if !emotions.isEmpty { parts.append(emotions.joined(separator: ", ")) }
        return parts.joined(separator: ", ")
    }

    func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    func clockString(_ minutes: Int) -> String {
        let hour = (minutes / 60) % 24
        let minute = minutes % 60
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d %@", twelve, minute, hour < 12 ? "AM" : "PM")
    }

    func duration(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        switch (h, m) {
        case (0, _): return "\(m) min"
        case (_, 0): return "\(h) h"
        default: return "\(h) h \(m) min"
        }
    }

    func signed(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return rounded > 0 ? "+\(rounded)" : "\(rounded)"
    }

    func grouped(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value))"
    }
}
