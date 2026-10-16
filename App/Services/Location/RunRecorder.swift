import Foundation
import CoreLocation
import EightyTwentyCore

/// Strava-style run or walk recording: GPS via CoreLocation's live updates, math via
/// `RunTracker` (unit tested in the core package).
///
/// `CLBackgroundActivitySession` keeps location flowing with the screen locked,
/// using only "While Using" permission (the blue pill in the status bar). While it
/// records, it shows on the Lock Screen (`RecordingLiveActivity`) and gives distance
/// updates (`DistanceCues`) as a notification, read out loud if you like.
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
    private var usesMiles: Bool
    /// Nil when distance updates are off.
    private var cues: DistanceCues?
    /// The latest update's title, for the Lock Screen.
    private var latestCue: String?
    private let liveActivity: RecordingLiveActivity
    private let announcer: CueAnnouncer

    init(usesMiles: Bool) {
        tracker = RunTracker(splitDistance: usesMiles ? 1609.344 : 1000)
        self.usesMiles = usesMiles
        liveActivity = RecordingLiveActivity()
        announcer = CueAnnouncer()
        // Nothing records across launches, so one still showing was left behind.
        liveActivity.end()
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
        latestCue = nil
        updateCues()
        liveActivity.start(activity, unitMeters: Units.meters(usesMiles: usesMiles), unitLabel: Units.label(usesMiles: usesMiles),
                           state: liveState(at: .now))
    }

    func pause() {
        tracker.pause(at: .now)
        liveActivity.update(liveState(at: .now), now: true)
    }

    func resume() {
        tracker.resume(at: .now)
        liveActivity.update(liveState(at: .now), now: true)
    }

    func finish() {
        tracker.finish(at: .now)
        stopUpdates()
        liveActivity.end()
    }

    func reset(usesMiles: Bool) {
        stopUpdates()
        tracker = RunTracker(splitDistance: usesMiles ? 1609.344 : 1000)
        routeLocations = []
        self.usesMiles = usesMiles
        cues = nil
        latestCue = nil
        liveActivity.end()
    }

    /// Reads the distance update setting. At the start, and again if you change it mid-recording.
    func updateCues() {
        guard tracker.state == .running || tracker.state == .paused else { return }
        let every = UserDefaults.standard.double(forKey: PrefKey.cueEvery)
        guard every > 0 else {
            cues = nil
            return
        }
        guard cues?.units != every else { return }
        cues = DistanceCues(every: every, usesMiles: usesMiles, meters: tracker.distance, seconds: tracker.movingTime(at: .now))
        Task { await NotificationService.shared.requestAuthorization() }
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
            let seconds = tracker.movingTime(at: location.timestamp)
            if let cue = cues?.update(meters: tracker.distance, seconds: seconds), let cues {
                announce(cues.message(cue), number: cue.number)
                liveActivity.update(liveState(at: location.timestamp), now: true)
            } else {
                liveActivity.update(liveState(at: location.timestamp))
            }
        }
    }

    private func announce(_ message: DistanceCues.Message, number: Int) {
        latestCue = message.title
        let speak = UserDefaults.standard.bool(forKey: PrefKey.cueSpeak)
        if speak { announcer.say(message.spoken) }
        // Silent when it's read out loud, so it doesn't ding over the voice.
        Task {
            await NotificationService.shared.post(id: NotificationService.cueID, title: message.title, body: message.body,
                                                  sound: !speak)
        }
        Log.app.info("Distance update \(number) for a \(activity.rawValue)\(speak ? ", read out loud" : "")")
    }

    private func liveState(at date: Date) -> RecordingAttributes.ContentState {
        RecordingAttributes.ContentState(movingSeconds: tracker.movingTime(at: date), at: date,
                                         isPaused: tracker.state == .paused, meters: tracker.distance, latest: latestCue)
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
