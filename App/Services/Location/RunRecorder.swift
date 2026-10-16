import Foundation
import CoreLocation
import EightyTwentyCore

/// Strava-style run or walk recording: GPS via CoreLocation's live updates, math via
/// `RunTracker` (unit tested in the core package).
///
/// `CLBackgroundActivitySession` keeps location flowing with the screen locked,
/// using only "While Using" permission (the blue pill in the status bar).
@MainActor
@Observable
final class RunRecorder {
    private(set) var tracker: RunTracker
    /// Accepted fixes, kept as CLLocations for the Apple Health route.
    private(set) var routeLocations: [CLLocation] = []
    private(set) var lastLocation: CLLocation?
    /// Stored (not computed from the manager) so the UI updates when you answer the prompt.
    private(set) var isLocationDenied = false
    /// Run or walk: the same GPS and math, saved as its own kind and Apple Health workout.
    var activity: ActivityKind = .run

    static let activities: [ActivityKind] = [.run, .walk]

    private let manager = CLLocationManager()
    private var updatesTask: Task<Void, Never>?
    private var backgroundSession: CLBackgroundActivitySession?

    init(usesMiles: Bool) {
        tracker = RunTracker(splitDistance: usesMiles ? 1609.344 : 1000)
    }

    var state: RunTracker.State { tracker.state }

    /// Ask for permission and warm up GPS so the first fix is ready when you hit Start.
    func prepare() {
        let status = manager.authorizationStatus
        isLocationDenied = status == .denied || status == .restricted
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        startUpdates()
    }

    func start() {
        guard tracker.state == .idle else { return }
        backgroundSession = CLBackgroundActivitySession()
        tracker.start(at: .now)
        startUpdates()
    }

    func pause() { tracker.pause(at: .now) }
    func resume() { tracker.resume(at: .now) }

    func finish() {
        tracker.finish(at: .now)
        stopUpdates()
    }

    func reset(usesMiles: Bool) {
        stopUpdates()
        tracker = RunTracker(splitDistance: usesMiles ? 1609.344 : 1000)
        routeLocations = []
    }

    func stopUpdates() {
        updatesTask?.cancel()
        updatesTask = nil
        backgroundSession?.invalidate()
        backgroundSession = nil
    }

    private func startUpdates() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(.fitness) {
                    guard let self, !Task.isCancelled else { return }
                    if update.authorizationDenied {
                        self.isLocationDenied = true
                    }
                    if let location = update.location {
                        self.isLocationDenied = false
                        self.handle(location)
                    }
                }
            } catch {
                // Updates end on cancellation or a location error; the UI shows GPS state.
            }
        }
    }

    private func handle(_ location: CLLocation) {
        lastLocation = location
        let point = RoutePoint(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            timestamp: location.timestamp,
            altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
            horizontalAccuracy: location.horizontalAccuracy
        )
        if tracker.add(point) {
            routeLocations.append(location)
        }
    }

    /// GPS quality for the little indicator before you start.
    var gpsQuality: String {
        guard let accuracy = lastLocation?.horizontalAccuracy, accuracy >= 0 else { return "Searching for GPS..." }
        switch accuracy {
        case ..<10: return "GPS: strong"
        case ..<30: return "GPS: OK"
        default: return "GPS: weak"
        }
    }
}
