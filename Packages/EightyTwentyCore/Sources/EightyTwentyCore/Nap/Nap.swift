import Foundation

/// A nap with a wake-up alarm, for the Nap screen on Record.
///
/// Wall-clock dates and Codable: the app saves it while you sleep, so a nap whose
/// alarm rang while the app was suspended or closed still logs the right length
/// when you next open it.
public struct Nap: Codable, Equatable, Sendable {
    /// Also the alarm's id, so it can be cancelled.
    public let id: UUID
    public let start: Date
    /// Alarm length, falling asleep included.
    public let minutes: Int
    /// When you got up before the alarm, if you did.
    public private(set) var endedEarlyAt: Date?

    public init(id: UUID = UUID(), start: Date, minutes: Int) {
        self.id = id
        self.start = start
        self.minutes = minutes
    }

    public var alarmAt: Date { start.addingTimeInterval(Double(minutes) * 60) }

    /// Up early, or the alarm has rung.
    public func isOver(at date: Date) -> Bool {
        endedEarlyAt != nil || date >= alarmAt
    }

    public func remaining(at date: Date) -> Double {
        isOver(at: date) ? 0 : alarmAt.timeIntervalSince(date)
    }

    public func progress(at date: Date) -> Double {
        guard minutes > 0 else { return 1 }
        return min(1, max(0, 1 - remaining(at: date) / (Double(minutes) * 60)))
    }

    /// "I'm up" before the alarm. Once the alarm has rung this changes nothing.
    public mutating func wakeUp(at date: Date) {
        guard !isOver(at: date) else { return }
        endedEarlyAt = max(start, date)
    }

    /// Minutes to log once it's over: until you got up early, else until the alarm,
    /// not until whenever you next opened the app. Nil while it's still going, and
    /// under a minute (an accidental start).
    public func loggableMinutes(at date: Date) -> Double? {
        guard isOver(at: date) else { return nil }
        let minutes = (endedEarlyAt ?? alarmAt).timeIntervalSince(start) / 60
        return minutes >= 1 ? minutes : nil
    }
}

/// Lengths and heads-ups for the Nap screen, from the research behind the
/// catalog's 10-minute nap (`power-nap`: Dutheil et al. 2021, Brooks & Lack 2006).
public enum NapGuide {
    public static var intervention: Intervention? { Intervention.find("power-nap") }

    /// Alarm lengths offered, in minutes, falling asleep included.
    public static let lengths = [10, 15, 20, 30, 45, 60, 90]

    /// The catalog's alarm: about 10 minutes of sleep once you drift off.
    public static var defaultMinutes: Int { Int(intervention?.minutes ?? 15) }

    /// What to know about this alarm length, started at `hour` (0-23). Empty when
    /// there's nothing to flag.
    public static func notes(minutes: Int, hour: Int) -> [String] {
        var notes: [String] = []
        if minutes < defaultMinutes {
            notes.append("Once you've drifted off, this leaves less than the 10 minutes of sleep that helped most in Brooks & Lack 2006.")
        }
        if minutes >= 30 {
            notes.append("Naps of 30 minutes or more bring grogginess first: in Brooks & Lack 2006, a 30-minute nap left people less alert right after waking, while 10 minutes helped right away.")
        }
        if let hours = intervention?.hours, hour > hours.upperBound {
            notes.append("This late in the day, a nap can make it harder to fall asleep tonight.")
        }
        return notes
    }
}
