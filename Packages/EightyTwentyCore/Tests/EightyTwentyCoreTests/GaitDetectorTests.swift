import XCTest
@testable import EightyTwentyCore

final class GaitDetectorTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_792_000_000)

    /// Seeded, so every run of the tests sees the same "random" paces.
    struct Noise {
        var state: UInt64
        mutating func uniform() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return (Double(z >> 11) + 0.5) / Double(1 << 53)
        }
        mutating func normal(_ mean: Double, _ sd: Double) -> Double {
            mean + sd * (-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform())
        }
    }

    /// `minutes` of 10-second samples around `speed`, starting `at` seconds in.
    func samples(minutes: Double, speed: Double, sd: Double = 0, at offset: Double, noise: inout Noise) -> [DistanceSample] {
        (0..<Int(minutes * 6)).map { i in
            let from = start.addingTimeInterval(offset + Double(i) * 10)
            let v = sd > 0 ? noise.normal(speed, sd) : speed
            return DistanceSample(start: from, end: from.addingTimeInterval(10), meters: max(0, v) * 10)
        }
    }

    /// Back-to-back stretches of (minutes, m/s).
    func recording(_ stretches: [(Double, Double)], sd: Double = 0, seed: UInt64 = 1) -> [DistanceSample] {
        var noise = Noise(state: seed)
        var offset = 0.0
        var all: [DistanceSample] = []
        for (minutes, speed) in stretches {
            all += samples(minutes: minutes, speed: speed, sd: sd, at: offset, noise: &noise)
            offset += minutes * 60
        }
        return all
    }

    func profile(walk: (Double, Double)? = nil, run: (Double, Double)? = nil, hours: Double = 10) -> PaceProfile {
        var noise = Noise(state: 7)
        var speeds = Histogram(binWidth: Histogram.speedBin)
        if let walk { speeds.add(Histogram.speeds(samples(minutes: hours * 60, speed: walk.0, sd: walk.1, at: 0, noise: &noise))) }
        if let run { speeds.add(Histogram.speeds(samples(minutes: hours * 60, speed: run.0, sd: run.1, at: 0, noise: &noise))) }
        return GaitDetector.profile(speeds: speeds)
    }

    // MARK: Learning

    func testStartsAtTheResearchTransitionSpeed() {
        let starting = PaceProfile.starting
        XCTAssertEqual(starting.threshold, 2.05, accuracy: 0.01, "about 13:05 /mi")
        XCTAssertFalse(starting.isLearned)
    }

    func testLearnsBothPacesAndPutsTheLineBetween() {
        // A brisk walker who jogs slowly: closer together than the averages.
        let close = profile(walk: (1.7, 0.12), run: (2.5, 0.2))
        XCTAssertEqual(close.walkSpeed, 1.7, accuracy: 0.05)
        XCTAssertEqual(close.runSpeed, 2.5, accuracy: 0.05)
        XCTAssertTrue(close.isLearned)
        XCTAssertEqual(close.threshold, 2.1, accuracy: 0.05)

        // A slow walker who runs fast: the line moves up, out of the slow end of the runs.
        let apart = profile(walk: (1.3, 0.15), run: (3.4, 0.35))
        XCTAssertEqual(apart.walkSpeed, 1.3, accuracy: 0.05)
        XCTAssertEqual(apart.runSpeed, 3.4, accuracy: 0.05)
        XCTAssertEqual(apart.threshold, 2.35, accuracy: 0.05)
    }

    func testOnlyEverWalkingDoesNotTurnFastWalkingIntoRunning() {
        let walker = profile(walk: (1.45, 0.15))
        XCTAssertEqual(walker.walkSpeed, 1.45, accuracy: 0.05)
        XCTAssertGreaterThanOrEqual(walker.threshold, 1.9)
        XCTAssertLessThan(walker.runSeconds, 300, "no running to learn from")
        XCTAssertGreaterThan(walker.threshold, 1.45 + 3 * 0.15, "brisk walking stays walking")
        XCTAssertFalse(walker.isLearned)
    }

    func testOnlyEverRunningDoesNotTurnSlowRunningIntoWalking() {
        let runner = profile(run: (2.8, 0.3))
        XCTAssertEqual(runner.runSpeed, 2.8, accuracy: 0.05)
        XCTAssertLessThanOrEqual(runner.threshold, 2.8 - 2 * 0.3, "slow running stays running")
        XCTAssertLessThan(runner.walkSeconds, 300)
    }

    func testOneMixedRecordingIsEnoughToLearnFrom() {
        // Day one, no history: walk, run, walk, run, at this person's own paces.
        let samples = recording([(5, 1.6), (12, 2.6), (3, 1.55), (10, 2.7)], sd: 0.1)
        let learned = GaitDetector.profile(speeds: Histogram.speeds(samples))
        XCTAssertFalse(learned.isLearned, "8 minutes of walking is less than the starting guess counts for")
        XCTAssertGreaterThan(learned.walkSpeed, 1.47, "already moving from 1.4 toward this person's 1.6")
        XCTAssertEqual(learned.runSpeed, 2.65, accuracy: 0.05)
        let segments = GaitDetector.split(samples, threshold: learned.threshold)
        XCTAssertEqual(segments.map(\.gait), [.walk, .run, .walk, .run])
    }

    // MARK: Splitting a recording

    func testSplitsWalkRunWalkRun() throws {
        let samples = recording([(5, 1.5), (10, 2.8), (2, 1.4), (5, 3.0)], sd: 0.08)
        let segments = GaitDetector.split(samples, threshold: 2.0)
        XCTAssertEqual(segments.map(\.gait), [.walk, .run, .walk, .run])
        XCTAssertEqual(segments.map(\.seconds), [300, 600, 120, 300])
        XCTAssertEqual(segments[1].meters, 600 * 2.8, accuracy: 60)
        XCTAssertEqual(segments[1].start, start.addingTimeInterval(300))
        XCTAssertEqual(try XCTUnwrap(segments[1].pace), 1 / 2.8, accuracy: 0.02)
        XCTAssertEqual(GaitDetector.activity(for: segments), .run)
        let totals = GaitDetector.totals(segments)
        XCTAssertEqual(totals[.run]?.seconds, 900)
        XCTAssertEqual(totals[.walk]?.seconds, 420)
    }

    func testABriefSlowdownIsNotAWalkBreak() {
        // A 10-second slowdown at a crossing, in the middle of a run.
        let samples = recording([(5, 2.8), (10.0 / 60, 1.2), (5, 2.8)])
        let segments = GaitDetector.split(samples, threshold: 2.0)
        XCTAssertEqual(segments.map(\.gait), [.run])
        XCTAssertEqual(segments.first?.seconds ?? 0, 610)
    }

    func testAThirtySecondWalkBreakCounts() {
        let samples = recording([(4, 2.8), (0.5, 1.4), (4, 2.8)])
        XCTAssertEqual(GaitDetector.split(samples, threshold: 2.0).map(\.gait), [.run, .walk, .run])
    }

    func testTheCurrentGaitChangesOnceTheNewPaceHolds() {
        // Live, the last stretch is what you're doing now: 10 seconds of walking after a
        // run is still the run; 30 seconds is a walk.
        let briefly = recording([(5, 2.8), (10.0 / 60, 1.4)])
        XCTAssertEqual(GaitDetector.split(briefly, threshold: 2.0).last?.gait, .run)
        let holding = recording([(5, 2.8), (0.5, 1.4)])
        XCTAssertEqual(GaitDetector.split(holding, threshold: 2.0).last?.gait, .walk)
    }

    func testMostlyWalkingIsAWalkEvenWithAJogInIt() {
        let samples = recording([(20, 1.5), (3, 2.6), (10, 1.5)])
        let segments = GaitDetector.split(samples, threshold: 2.0)
        XCTAssertEqual(segments.map(\.gait), [.walk, .run, .walk])
        XCTAssertEqual(GaitDetector.activity(for: segments), .walk)
        XCTAssertNil(GaitDetector.activity(for: []))
    }

    func testFromRealFixesThroughTheTracker() {
        // Walk 2 minutes, run 5, walk 2, at one fix a second with the chip's speed.
        let origin = (latitude: 47.6062, longitude: -122.3321)
        var tracker = RunTracker()
        tracker.stopSpeed = 0.5
        tracker.start(at: start)
        var meters = 0.0
        var second = 0.0
        for (seconds, speed) in [(120.0, 1.4), (300.0, 3.0), (120.0, 1.4)] {
            for _ in 0..<Int(seconds) {
                second += 1
                meters += speed
                tracker.add(RoutePoint(latitude: origin.latitude + meters / 111_195, longitude: origin.longitude,
                                       timestamp: start.addingTimeInterval(second), horizontalAccuracy: 5,
                                       speed: speed, speedAccuracy: 0.3))
            }
        }
        tracker.finish(at: start.addingTimeInterval(second))
        let segments = GaitDetector.split(tracker.distanceSamples, threshold: PaceProfile.starting.threshold)
        XCTAssertEqual(segments.map(\.gait), [.walk, .run, .walk])
        XCTAssertEqual(segments[1].seconds, 300, accuracy: 15)
        XCTAssertEqual(segments[1].meters, 900, accuracy: 40)
        XCTAssertEqual(GaitDetector.activity(for: segments), .run)
    }

    // MARK: Map lines

    func testRouteLinesChangeColorWhereTheGaitDoesAndStayJoined() {
        func point(_ s: Double) -> RoutePoint {
            RoutePoint(latitude: 47 + s / 100_000, longitude: -122, timestamp: start.addingTimeInterval(s))
        }
        let gaits = [
            GaitSegment(gait: .walk, start: start, end: start.addingTimeInterval(10), seconds: 10, meters: 14),
            GaitSegment(gait: .run, start: start.addingTimeInterval(10), end: start.addingTimeInterval(30), seconds: 20, meters: 56),
        ]
        // Two tracks: a pause between 20 and 25 seconds.
        let tracks = [(0...20).map { point(Double($0)) }, (25...30).map { point(Double($0)) }]
        let lines = GaitDetector.lines(tracks, gaits: gaits, otherwise: .run)
        XCTAssertEqual(lines.map(\.gait), [.walk, .run, .run])
        XCTAssertEqual(lines[0].points.last, lines[1].points.first, "joined where the gait changes")
        XCTAssertEqual(lines[1].points.last?.timestamp, start.addingTimeInterval(20))
        XCTAssertEqual(lines[2].points.first?.timestamp, start.addingTimeInterval(25), "not joined across the pause")

        let plain = GaitDetector.lines(tracks, gaits: [], otherwise: .walk)
        XCTAssertEqual(plain.map(\.gait), [.walk, .walk])
        XCTAssertEqual(plain.map(\.points.count), [21, 6])
    }

    // MARK: History

    func testHistoryKeepsRecentRecordingsAndForgetsDiscardedOnes() throws {
        var history = PaceHistory()
        let walk = recording([(10, 1.5)])
        history.record(start: start, samples: walk)
        history.record(start: start, samples: walk)
        XCTAssertEqual(history.recordings.count, 1, "the same recording saved again replaces itself")
        XCTAssertEqual(history.speeds().totalSeconds, 600)
        XCTAssertEqual(history.speeds(excluding: start).totalSeconds, 0)

        for i in 1...50 { history.record(start: start.addingTimeInterval(Double(i) * 86_400), samples: walk) }
        XCTAssertEqual(history.recordings.count, PaceHistory.kept)
        XCTAssertFalse(history.contains(start: start), "the oldest fall off")

        let latest = start.addingTimeInterval(50 * 86_400)
        history.remove(start: latest)
        XCTAssertFalse(history.contains(start: latest))

        let decoded = try JSONDecoder().decode(PaceHistory.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(decoded, history)
    }

    func testJournalRemembersAutoAndReadsOldJournals() throws {
        let entry = RunJournal.Entry.start(start, activity: .run, splitDistance: 1000, stopSpeed: 0.5, autoDetect: true)
        let auto = try XCTUnwrap(RunJournal.replay(RunJournal.entries(in: RunJournal.line(entry))))
        XCTAssertTrue(auto.autoDetect)

        // Written before auto existed.
        let old = Data(#"{"start":{"_0":\#(start.timeIntervalSinceReferenceDate),"activity":"walk","splitDistance":1000,"stopSpeed":0.5}}"#.utf8)
            + Data([0x0A])
        let replayed = try XCTUnwrap(RunJournal.replay(RunJournal.entries(in: old)))
        XCTAssertEqual(replayed.activity, .walk)
        XCTAssertFalse(replayed.autoDetect)
    }

    // MARK: Steps per minute

    /// A step count every 2 seconds from the start, at `stretches` of (minutes, steps a minute).
    func steps(_ stretches: [(Double, Double)]) -> StepTrack {
        var track = StepTrack(start: start)
        var t = 0.0, total = 0.0
        for (minutes, cadence) in stretches {
            for _ in 0..<Int(minutes * 30) {
                t += 2
                total += cadence / 30
                track.add(at: start.addingTimeInterval(t), steps: Int(total.rounded()))
            }
        }
        return track
    }

    func testStepsPerMinuteFromRunningTotals() throws {
        var track = StepTrack(start: start)
        track.add(at: start.addingTimeInterval(10), steps: 20)
        track.add(at: start.addingTimeInterval(20), steps: 50)
        track.add(at: start.addingTimeInterval(15), steps: 99) // out of order: ignored
        XCTAssertEqual(try XCTUnwrap(track.stepsPerMinute(from: start, to: start.addingTimeInterval(10))), 120, accuracy: 0.01)
        // Halfway between counts, by straight line: 35 at 15 s.
        XCTAssertEqual(try XCTUnwrap(track.stepsPerMinute(from: start.addingTimeInterval(15), to: start.addingTimeInterval(20))),
                       180, accuracy: 0.01)
        // Just past the last count, the latest rate carries on; well past it, nothing.
        XCTAssertEqual(try XCTUnwrap(track.stepsPerMinute(from: start.addingTimeInterval(20), to: start.addingTimeInterval(30))),
                       180, accuracy: 0.01)
        XCTAssertNil(track.stepsPerMinute(from: start.addingTimeInterval(30), to: start.addingTimeInterval(40)))
        XCTAssertNil(track.stepsPerMinute(from: start.addingTimeInterval(-10), to: start), "before the start")
        XCTAssertNil(StepTrack().stepsPerMinute(from: start, to: start.addingTimeInterval(10)))
    }

    func testStepsDecideWherePaceCannot() {
        // A slow jog up a hill at 1.9 m/s, then a fast walk at 2.1 m/s: by pace alone these
        // come out backwards. By steps per minute they're right.
        let samples = recording([(5, 1.9), (5, 2.1)])
        let track = steps([(5, 160), (5, 125)])
        XCTAssertEqual(GaitDetector.split(samples, threshold: 2.0).map(\.gait), [.walk, .run], "pace alone")
        XCTAssertEqual(GaitDetector.split(samples, threshold: 2.0, steps: track).map(\.gait), [.run, .walk])
    }

    func testPaceFillsInWhereThereAreNoSteps() {
        // Step counts stop after 5 minutes (motion access turned off, say): pace takes over.
        let samples = recording([(5, 1.5), (5, 2.8)])
        let track = steps([(5, 110)])
        XCTAssertEqual(GaitDetector.split(samples, threshold: 2.0, steps: track).map(\.gait), [.walk, .run])
    }

    func testLearnsYourCadences() {
        var noise = Noise(state: 3)
        var cadences = Histogram(binWidth: Histogram.cadenceBin)
        for _ in 0..<3000 { cadences.add(noise.normal(118, 5), seconds: 10) }
        for _ in 0..<3000 { cadences.add(noise.normal(158, 6), seconds: 10) }
        let learned = GaitDetector.profile(speeds: Histogram(binWidth: Histogram.speedBin), cadences: cadences)
        XCTAssertTrue(learned.isCadenceLearned)
        XCTAssertEqual(learned.walkCadence, 118, accuracy: 1)
        XCTAssertEqual(learned.runCadence, 158, accuracy: 1)
        XCTAssertEqual(learned.cadenceThreshold, 138, accuracy: 1)

        let starting = PaceProfile.starting
        XCTAssertEqual(starting.cadenceThreshold, 138.5, accuracy: 0.5, "the walk-run switch is around 140 a minute")
        XCTAssertFalse(starting.isCadenceLearned)
    }

    func testHistoryKeepsStepsAndSkipsWholeRunAverages() {
        var history = PaceHistory()
        let samples = recording([(10, 1.5)])
        history.record(start: start, samples: samples, steps: steps([(10, 115)]))
        XCTAssertEqual(history.cadences().totalSeconds, 600, accuracy: 10)
        // Older runs went to Health as one sample from start to finish: one average over every
        // pace in it, so it's left out.
        let lump = [DistanceSample(start: start, end: start.addingTimeInterval(1800), meters: 4000)]
        history.record(start: start.addingTimeInterval(86_400), samples: lump)
        XCTAssertEqual(history.recordings.count, 1)
    }

    func testJournalReplaysStepCounts() throws {
        let entries: [RunJournal.Entry] = [
            .start(start, activity: .run, splitDistance: 1000, stopSpeed: 0.5, autoDetect: true),
            .steps(start.addingTimeInterval(10), 27),
            .steps(start.addingTimeInterval(20), 55),
        ]
        let file = entries.reduce(into: Data()) { $0.append(RunJournal.line($1)) }
        let recording = try XCTUnwrap(RunJournal.replay(RunJournal.entries(in: file)))
        XCTAssertEqual(recording.steps.counts.map(\.steps), [0, 27, 55])
        XCTAssertEqual(try XCTUnwrap(recording.steps.stepsPerMinute(from: start, to: start.addingTimeInterval(20))), 165, accuracy: 0.01)
    }
}
