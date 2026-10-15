import Foundation
import BackgroundTasks

/// Morning background sync, so the bars are fresh before you open the app.
/// iOS decides the exact time; we just ask for "after 7am".
enum BackgroundRefresh {
    /// Must match BGTaskSchedulerPermittedIdentifiers in Info.plist.
    static var identifier: String {
        (Bundle.main.bundleIdentifier ?? "eightytwenty") + ".refresh"
    }

    static func schedule(now: Date = .now, calendar: Calendar = .current) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = 7
        components.minute = 15
        let todayAtSeven = calendar.date(from: components) ?? now
        request.earliestBeginDate = todayAtSeven > now
            ? todayAtSeven
            : calendar.date(byAdding: .day, value: 1, to: todayAtSeven)
        try? BGTaskScheduler.shared.submit(request)
    }
}
