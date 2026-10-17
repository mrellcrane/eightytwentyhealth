import Foundation

/// Keeps one thing from counting twice when two sources saw it: an Oura Moment or
/// tag for a sit you also timed here, or a run that this app and a watch (or Oura,
/// through Apple Health) both saved.
public enum Overlap {
    /// Oura tags are often added a little after the fact.
    public static let slack: TimeInterval = 15 * 60

    public struct Span: Equatable, Sendable {
        public var start: Date
        public var end: Date

        public init(start: Date, end: Date) {
            self.start = start
            self.end = max(start, end)
        }

        /// No minutes is a moment, not a stretch of time.
        public init(start: Date, minutes: Double?) {
            self.init(start: start, end: start.addingTimeInterval(max(0, minutes ?? 0) * 60))
        }

        public func overlaps(_ other: Span, slack: TimeInterval = 0) -> Bool {
            start <= other.end.addingTimeInterval(slack) && other.start <= end.addingTimeInterval(slack)
        }
    }

    /// Something already logged: what it was and when.
    public struct Entry: Equatable, Sendable {
        public var kind: ActivityKind
        public var span: Span

        public init(kind: ActivityKind, span: Span) {
            self.kind = kind
            self.span = span
        }
    }

    /// The imports that aren't logged yet: drops one of the same kind within `slack`
    /// of a log you already have, or of an earlier import in the same batch.
    public static func newImports(_ items: [ImportedActivity], existing: [Entry]) -> [ImportedActivity] {
        var taken = existing
        var fresh: [ImportedActivity] = []
        for item in items {
            let entry = Entry(kind: item.kind, span: Span(start: item.timestamp, minutes: item.minutes))
            guard !taken.contains(where: { $0.kind == entry.kind && $0.span.overlaps(entry.span, slack: slack) }) else { continue }
            taken.append(entry)
            fresh.append(item)
        }
        return fresh
    }

    /// One item from each group whose times overlap, the biggest by `size`: you can't
    /// do two runs at once, so overlapping runs are one run saved twice. Back-to-back
    /// ones stay apart. Sorted by start.
    public static func distinct<T>(_ items: [T], span: (T) -> Span, size: (T) -> Double) -> [T] {
        var result: [T] = []
        var groupEnd: Date?
        for item in items.sorted(by: { span($0).start < span($1).start }) {
            let itemSpan = span(item)
            if let end = groupEnd, itemSpan.start < end, let kept = result.last {
                if size(item) > size(kept) { result[result.count - 1] = item }
                groupEnd = max(end, itemSpan.end)
            } else {
                result.append(item)
                groupEnd = itemSpan.end
            }
        }
        return result
    }
}
