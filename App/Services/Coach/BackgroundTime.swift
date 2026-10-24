import UIKit

/// Asks iOS for a little more time (about 30 s) to finish `work` if you switch apps
/// meanwhile. Without it iOS pauses the app within seconds, which drops the
/// connection, and a Claude answer in flight fails with "The network connection was lost".
@MainActor
final class BackgroundTime {
    private var id = UIBackgroundTaskIdentifier.invalid

    private init() {}

    static func keepAlive<T>(_ name: String, _ work: () async throws -> T) async rethrows -> T {
        let time = BackgroundTime()
        // Called when the time runs out; the work may still finish once you're back.
        time.id = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated { time.end() }
        }
        defer { time.end() }
        return try await work()
    }

    private func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
