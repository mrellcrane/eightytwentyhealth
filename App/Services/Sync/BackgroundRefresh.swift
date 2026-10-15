import Foundation
import BackgroundTasks

/// Morning background sync, so the bars are fresh and the morning brief can go
/// out before you open the app. iOS decides the exact time (it learns from when
/// you use the app); we only say "not before".
enum BackgroundRefresh {
    /// Must match BGTaskSchedulerPermittedIdentifiers in Info.plist.
    static var identifier: String {
        (Bundle.main.bundleIdentifier ?? "eightytwenty") + ".refresh"
    }

    /// Next 7:15am.
    static func schedule(now: Date = .now, calendar: Calendar = .current) {
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = 7
        components.minute = 15
        let todayAtSeven = calendar.date(from: components) ?? now
        let next = todayAtSeven > now
            ? todayAtSeven
            : calendar.date(byAdding: .day, value: 1, to: todayAtSeven) ?? now.addingTimeInterval(86_400)
        schedule(earliest: next)
    }

    /// Replaces any pending request (there's only ever one per identifier).
    static func schedule(earliest: Date) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = earliest
        try? BGTaskScheduler.shared.submit(request)
    }
}
