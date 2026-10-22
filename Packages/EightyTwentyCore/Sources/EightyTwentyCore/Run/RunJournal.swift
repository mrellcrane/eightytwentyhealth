import Foundation

/// Everything fed to a `RunTracker`, in order, written to disk as you go so a recording
/// survives the app closing mid-run (a crash, iOS reclaiming memory, an update installing).
/// The tracker is a plain state machine, so replaying the same calls rebuilds it exactly.
///
/// Stored as JSON lines, one entry each: a write is a cheap append, and a line torn by the
/// app dying mid-write costs only that line.
public enum RunJournal {
    public enum Entry: Codable, Equatable, Sendable {
        /// Always first: the settings that shape everything after it.
        case start(Date, activity: ActivityKind, splitDistance: Double, stopSpeed: Double)
        case fix(RoutePoint)
        case stationary(Date)
        case pause(Date)
        case resume(Date)
        case finish(Date)

        public var date: Date {
            switch self {
            case .start(let date, _, _, _), .stationary(let date), .pause(let date), .resume(let date), .finish(let date):
                return date
            case .fix(let point):
                return point.timestamp
            }
        }
    }

    /// A recording rebuilt from its journal.
    public struct Recording: Sendable {
        public var tracker: RunTracker
        public var activity: ActivityKind
        /// The last thing written: where a recording cut off by the app closing ends.
        public var lastWritten: Date
    }

    /// One entry, ready to append to the file.
    public static func line(_ entry: Entry) -> Data {
        // Only numbers, dates and strings, so encoding can't fail; a blank line would be skipped anyway.
        var data = (try? JSONEncoder().encode(entry)) ?? Data()
        data.append(0x0A)
        return data
    }

    /// The entries in a journal file. A torn or unreadable line is skipped.
    public static func entries(in data: Data) -> [Entry] {
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(Entry.self, from: Data($0)) }
    }

    /// Replays the entries into a fresh tracker. Nil if the recording never started.
    public static func replay(_ entries: [Entry]) -> Recording? {
        guard case let .start(startedAt, activity, splitDistance, stopSpeed)? = entries.first else { return nil }
        var tracker = RunTracker(splitDistance: splitDistance)
        tracker.stopSpeed = stopSpeed
        tracker.start(at: startedAt)
        var last = startedAt
        for entry in entries.dropFirst() {
            switch entry {
            case .start: continue
            case .fix(let point): tracker.add(point)
            case .stationary(let date): tracker.markStationary(at: date)
            case .pause(let date): tracker.pause(at: date)
            case .resume(let date): tracker.resume(at: date)
            case .finish(let date): tracker.finish(at: date)
            }
            last = max(last, entry.date)
        }
        return Recording(tracker: tracker, activity: activity, lastWritten: last)
    }

    /// A recording found on disk when the app opens. One cut off within `resumeWithin`
    /// comes back paused where it stopped, so you can carry on; an older one is finished
    /// there, ready to save. One you'd already finished comes back as it was.
    public static func recover(_ entries: [Entry], now: Date, resumeWithin: TimeInterval = 30 * 60) -> Recording? {
        guard var recording = replay(entries) else { return nil }
        switch recording.tracker.state {
        case .idle, .finished:
            break
        case .running, .paused:
            if now.timeIntervalSince(recording.lastWritten) <= resumeWithin {
                recording.tracker.pause(at: recording.lastWritten)
            } else {
                recording.tracker.finish(at: recording.lastWritten)
            }
        }
        return recording
    }
}
