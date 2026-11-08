import Foundation
import CoreLocation
import EightyTwentyCore

/// Strava-style run or walk recording: GPS via CoreLocation's live updates, smoothing and
/// math via `RunTracker` and `TrackFilter` (unit tested in the core package).
///
/// `CLBackgroundActivitySession` keeps location flowing with the screen locked,
/// using only "While Using" permission (the blue pill in the status bar). While it
/// records, it shows on the Lock Screen (`RecordingLiveActivity`) and gives distance
/// updates (`DistanceCues`) as a notification, read out loud if you like.
///
/// Everything it feeds the tracker also goes to disk (`RunJournal`), so a recording the
/// app closes in the middle of comes back (`restore`).
@MainActor
@Observable
final class RunRecorder {
    private(set) var tracker: RunTracker
    /// Accepted fixes, for their altitude and accuracy in the Apple Health route.
    private var fixes: [Date: CLLocation] = [:]
    private(set) var lastLocation: CLLocation?
    /// Stored (not computed from the manager) so the UI updates when you answer the prompt.
    private(set) var isLocationDenied = false
    /// Run or walk: the same GPS and math, saved as its own kind and Apple Health workout.
    var activity: ActivityKind = .run
    /// Run or walk is picked from your pace when you finish (`GaitDetector`), not by you
    /// up front. `activity` is set then.
    var autoDetect = false
    /// What auto picked when you finished, so the screen can say so.
    private(set) var pickedFromPace: ActivityKind?
    /// The recording so far as running and walking stretches. Worked out on every fix,
    /// whether or not it's on auto, so the map and the finish screen can show the split.
    private(set) var gaits: [GaitSegment] = []
    /// Your run and walk paces and the line between them, learned from past recordings
    /// and this one so far.
    private(set) var paceProfile = PaceProfile.starting
    /// Past recordings' speeds, which the paces are learned from. Kept on this phone only.
    private var paceHistory: PaceHistory

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
    private let journal = JournalFile()

    init(usesMiles: Bool) {
        tracker = RunTracker(splitDistance: usesMiles ? 1609.344 : 1000)
        self.usesMiles = usesMiles
        liveActivity = RecordingLiveActivity()
        announcer = CueAnnouncer()
        paceHistory = UserDefaults.standard.data(forKey: PrefKey.paceHistory)
            .flatMap { try? JSONDecoder().decode(PaceHistory.self, from: $0) } ?? PaceHistory()
        paceProfile = GaitDetector.profile(from: paceHistory.speeds())
        // Nothing records across launches, so one still showing was left behind.
        liveActivity.end()
    }

    var state: RunTracker.State { tracker.state }

    /// Running or walking right now (or when you stopped). Nil before there's anything to go on.
    var currentGait: Gait? { gaits.last?.gait }

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
        let now = Date.now
        backgroundSession = CLBackgroundActivitySession()
        // A walk is slower, so it takes slower still to count as standing around. On auto it
        // might be a walk.
        tracker.stopSpeed = activity == .walk || autoDetect ? 0.5 : 0.9
        tracker.start(at: now)
        updateGaits()
        journal.replace(with: [.start(now, activity: activity, splitDistance: tracker.splitDistance, stopSpeed: tracker.stopSpeed,
                                      autoDetect: autoDetect ? true : nil)])
        startUpdates()
        latestCue = nil
        updateCues()
        startLiveActivity(at: now)
    }

    func pause() {
        let now = Date.now
        tracker.pause(at: now)
        journal.append(.pause(now))
        liveActivity.update(liveState(at: now), now: true)
    }

    func resume() {
        let now = Date.now
        tracker.resume(at: now)
        journal.append(.resume(now))
        if backgroundSession == nil {
            // Brought back after the app closed mid-recording: GPS and the Lock Screen start again.
            backgroundSession = CLBackgroundActivitySession()
            startUpdates()
            updateCues()
            startLiveActivity(at: now)
        } else {
            liveActivity.update(liveState(at: now), now: true)
        }
    }

    func finish() {
        let now = Date.now
        tracker.finish(at: now)
        journal.append(.finish(now))
        updateGaits()
        pickActivity()
        stopUpdates()
        liveActivity.end()
        logFilter()
    }

    /// Brings back a recording the app closed in the middle of: paused where it stopped
    /// if that was in the last half hour, otherwise finished there, to be saved. Returns
    /// whether there was one.
    func restore() -> Bool {
        guard tracker.state == .idle else { return false }
        let entries = journal.read()
        guard let recording = RunJournal.recover(entries, now: .now) else {
            journal.clear()
            return false
        }
        tracker = recording.tracker
        activity = recording.activity
        autoDetect = recording.autoDetect
        updateGaits()
        if tracker.state == .finished { pickActivity() }
        usesMiles = recording.tracker.splitDistance > 1000
        fixes = [:]
        cues = nil
        latestCue = nil
        // Written back whole, so a line torn when the app closed can't swallow the next one.
        let last = recording.lastWritten
        let closing: RunJournal.Entry = tracker.state == .paused ? .pause(last) : .finish(last)
        journal.replace(with: entries + [closing])
        Log.app.info("Recovered a \(activity.rawValue) the app closed in the middle of: \(tracker.state == .paused ? "paused" : "finished")")
        return true
    }

    /// Once it's saved, the copy on disk isn't needed.
    func clearJournal() {
        journal.clear()
    }

    /// On auto, the finished recording is a run if you ran at least half of it.
    private func pickActivity() {
        guard autoDetect, let kind = GaitDetector.activity(for: gaits) else { return }
        activity = kind
        pickedFromPace = kind
    }

    /// Once it's saved, its speeds go into what your paces are learned from.
    func learnPaces() {
        guard let start = tracker.startedAt else { return }
        paceHistory.record(start: start, samples: tracker.distanceSamples)
        savePaceHistory()
    }

    /// A discarded recording comes back out of what your paces are learned from.
    func forgetPaces(startedAt start: Date) {
        guard paceHistory.contains(start: start) else { return }
        paceHistory.remove(start: start)
        savePaceHistory()
    }

    private func savePaceHistory() {
        if let data = try? JSONEncoder().encode(paceHistory) {
            UserDefaults.standard.set(data, forKey: PrefKey.paceHistory)
        }
        updateGaits()
    }

    /// The paces from past recordings plus this one, and this one split by them.
    private func updateGaits() {
        var speeds = paceHistory.speeds(excluding: tracker.startedAt)
        speeds.add(SpeedHistogram(tracker.distanceSamples))
        paceProfile = GaitDetector.profile(from: speeds)
        gaits = GaitDetector.split(tracker.distanceSamples, threshold: paceProfile.threshold)
    }

    private func startLiveActivity(at date: Date) {
        liveActivity.start(activity, unitMeters: Units.meters(usesMiles: usesMiles), unitLabel: Units.label(usesMiles: usesMiles),
                           state: liveState(at: date))
    }

    /// The smoothed route as CLLocations, for Apple Health: what the map showed, with each
    /// fix's own time, altitude and accuracy.
    var routeLocations: [CLLocation] {
        tracker.route.map { point in
            let fix = fixes[point.timestamp]
            return CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                altitude: fix?.altitude ?? 0,
                horizontalAccuracy: fix?.horizontalAccuracy ?? point.horizontalAccuracy ?? 10,
                verticalAccuracy: fix?.verticalAccuracy ?? -1,
                course: fix?.course ?? -1,
                speed: point.speed ?? -1,
                timestamp: point.timestamp
            )
        }
    }

    /// How the smoothing did, as counts and ratios only, so it can be checked in Sentry.
    private func logFilter() {
        let t = tracker
        guard t.fixCount > 0, t.lineLength > 0, let end = t.endedAt else { return }
        let elapsed = t.elapsedTime(at: end)
        let runStretches = gaits.filter { $0.gait == .run }.count
        Log.app.info("Recorded \(activity.rawValue)\(autoDetect ? " (picked from pace)" : ""): \(gaits.count) run/walk stretches, \(runStretches) of them running; paces \(paceProfile.isLearned ? "learned" : "still the starting guess")")
        Log.app.info("Recorded \(activity.rawValue): \(t.fixCount) fixes, \(t.rejectedCount) thrown out, \(t.stops.count) stops; raw line \(Self.percent(t.rawLength / t.lineLength)) of smoothed, distance \(Self.percent(t.distance / t.lineLength)) of smoothed line, moving \(Self.percent(elapsed > 0 ? t.movingTime(at: end) / elapsed : 1)) of elapsed")
    }

    private static func percent(_ ratio: Double) -> String { "\(Int((ratio * 100).rounded()))%" }

    func reset(usesMiles: Bool) {
        stopUpdates()
        journal.clear()
        tracker = RunTracker(splitDistance: usesMiles ? 1609.344 : 1000)
        fixes = [:]
        updateGaits()
        pickedFromPace = nil
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
                    // iOS holds updates while you stand still; the clock stops with them.
                    if update.stationary, self.tracker.state == .running, !self.tracker.isStopped {
                        let now = Date.now
                        self.tracker.markStationary(at: now)
                        self.journal.append(.stationary(now))
                        self.liveActivity.update(self.liveState(at: now), now: true)
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
            horizontalAccuracy: location.horizontalAccuracy,
            speed: location.speedAccuracy >= 0 ? location.speed : nil,
            speedAccuracy: location.speedAccuracy >= 0 ? location.speedAccuracy : nil,
            course: location.courseAccuracy >= 0 ? location.course : nil,
            courseAccuracy: location.courseAccuracy >= 0 ? location.courseAccuracy : nil
        )
        let wasStopped = tracker.isStopped
        let wasGait = currentGait
        if tracker.state == .running { journal.append(.fix(point)) }
        if tracker.add(point) {
            fixes[location.timestamp] = location
            updateGaits()
            let seconds = tracker.movingTime(at: location.timestamp)
            if let cue = cues?.update(meters: tracker.distance, seconds: seconds), let cues {
                announce(cues.message(cue), number: cue.number)
                liveActivity.update(liveState(at: location.timestamp), now: true)
            } else {
                // Stopping or starting again freezes or restarts the Lock Screen clock right away;
                // on auto, switching between running and walking shows there right away too.
                let gaitChanged = autoDetect && currentGait != wasGait
                liveActivity.update(liveState(at: location.timestamp), now: tracker.isStopped != wasStopped || gaitChanged)
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
                                         isPaused: tracker.state == .paused || tracker.isStopped,
                                         isStopped: tracker.isStopped, meters: tracker.distance, latest: latestCue,
                                         gait: autoDetect ? currentGait?.activity.rawValue : nil)
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

/// `RunJournal` on disk: one file, a line appended for everything the tracker is fed.
@MainActor
private final class JournalFile {
    private let url = URL.applicationSupportDirectory.appending(path: "recording.jsonl")
    private var handle: FileHandle?
    /// Reported once per recording, not once a second.
    private var failed = false

    /// What's there from last time, if anything.
    func read() -> [RunJournal.Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return RunJournal.entries(in: data)
    }

    /// Starts the file over with these entries, then appends after them.
    func replace(with entries: [RunJournal.Entry]) {
        close()
        failed = false
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = entries.reduce(into: Data()) { $0.append(RunJournal.line($1)) }
            // Readable with the phone locked, which is most of a run.
            try data.write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication)
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            self.handle = handle
        } catch {
            report(error)
        }
    }

    func append(_ entry: RunJournal.Entry) {
        guard let handle else { return }
        do {
            try handle.write(contentsOf: RunJournal.line(entry))
        } catch {
            report(error)
        }
    }

    func clear() {
        close()
        try? FileManager.default.removeItem(at: url)
    }

    private func close() {
        try? handle?.close()
        handle = nil
    }

    private func report(_ error: Error) {
        guard !failed else { return }
        failed = true
        Log.app.warning("Couldn't write the recording to disk: \(error.localizedDescription)")
    }
}
