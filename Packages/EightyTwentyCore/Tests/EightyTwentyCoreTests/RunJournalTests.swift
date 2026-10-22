import XCTest
@testable import EightyTwentyCore

final class RunJournalTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_792_000_000)
    let origin = (latitude: 47.6062, longitude: -122.3321)

    /// A point `meters` due north of the origin, `seconds` after start, with the chip's speed.
    func point(meters: Double, seconds: Double) -> RoutePoint {
        RoutePoint(
            latitude: origin.latitude + meters / 111_195,
            longitude: origin.longitude,
            timestamp: start.addingTimeInterval(seconds),
            altitude: 20,
            horizontalAccuracy: 5,
            speed: 3,
            speedAccuracy: 0.5
        )
    }

    /// Feeds the same calls to a live tracker and a journal, the way the recorder does.
    struct Recorder {
        var tracker = RunTracker(splitDistance: 1609.344)
        var file = Data()

        init(at date: Date) {
            tracker.stopSpeed = 0.9
            write(.start(date, activity: .run, splitDistance: 1609.344, stopSpeed: 0.9))
            tracker.start(at: date)
        }

        mutating func write(_ entry: RunJournal.Entry) { file.append(RunJournal.line(entry)) }

        mutating func run(meters: Double, from: Double = 0, timeOffset: Double, using point: (Double, Double) -> RoutePoint) {
            for s in 0...Int(meters / 3) {
                let fix = point(from + Double(s) * 3, timeOffset + Double(s))
                write(.fix(fix))
                tracker.add(fix)
            }
        }

        mutating func pause(_ date: Date) { write(.pause(date)); tracker.pause(at: date) }
        mutating func resume(_ date: Date) { write(.resume(date)); tracker.resume(at: date) }
        mutating func finish(_ date: Date) { write(.finish(date)); tracker.finish(at: date) }
    }

    func assertSame(_ replayed: RunTracker, _ live: RunTracker, at date: Date, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(replayed.state, live.state, file: file, line: line)
        XCTAssertEqual(replayed.startedAt, live.startedAt, file: file, line: line)
        XCTAssertEqual(replayed.endedAt, live.endedAt, file: file, line: line)
        XCTAssertEqual(replayed.distance, live.distance, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(replayed.movingTime(at: date), live.movingTime(at: date), accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(replayed.splits.map(\.index), live.splits.map(\.index), file: file, line: line)
        XCTAssertEqual(replayed.pauses, live.pauses, file: file, line: line)
        XCTAssertEqual(replayed.segments.map(\.count), live.segments.map(\.count), file: file, line: line)
    }

    func testReplayRebuildsTheRunExactly() throws {
        var recorder = Recorder(at: start)
        recorder.run(meters: 2000, timeOffset: 0, using: point)
        recorder.pause(start.addingTimeInterval(700))
        recorder.resume(start.addingTimeInterval(800))
        recorder.run(meters: 1000, from: 2100, timeOffset: 800, using: point)
        let end = start.addingTimeInterval(1200)
        recorder.finish(end)

        let recording = try XCTUnwrap(RunJournal.replay(RunJournal.entries(in: recorder.file)))
        XCTAssertEqual(recording.activity, .run)
        XCTAssertEqual(recording.lastWritten, end)
        XCTAssertEqual(recorder.tracker.splits.count, 1, "3 km is one full mile split, so the splits are checked too")
        assertSame(recording.tracker, recorder.tracker, at: end)
    }

    func testRoundTripsEveryKindOfEntry() {
        let entries: [RunJournal.Entry] = [
            .start(start, activity: .walk, splitDistance: 1000, stopSpeed: 0.5),
            .fix(point(meters: 3, seconds: 1)),
            .stationary(start.addingTimeInterval(2)),
            .pause(start.addingTimeInterval(3)),
            .resume(start.addingTimeInterval(4)),
            .finish(start.addingTimeInterval(5)),
        ]
        let file = entries.reduce(into: Data()) { $0.append(RunJournal.line($1)) }
        XCTAssertEqual(RunJournal.entries(in: file), entries)
    }

    func testATornLastLineIsSkipped() {
        var recorder = Recorder(at: start)
        recorder.run(meters: 300, timeOffset: 0, using: point)
        var file = recorder.file
        // The app died partway through writing the next fix.
        file.append(RunJournal.line(.fix(point(meters: 303, seconds: 101))).prefix(40))

        let entries = RunJournal.entries(in: file)
        XCTAssertEqual(entries.count, 1 + 101)
        XCTAssertEqual(RunJournal.replay(entries)?.tracker.distance ?? 0, recorder.tracker.distance, accuracy: 0.01)
    }

    func testNothingToRecoverWithoutAStart() {
        XCTAssertNil(RunJournal.recover([], now: start))
        XCTAssertNil(RunJournal.recover(RunJournal.entries(in: Data("garbage\n".utf8)), now: start))
        XCTAssertNil(RunJournal.recover([.fix(point(meters: 0, seconds: 0))], now: start))
    }

    func testCutOffRecentlyComesBackPausedWhereItStopped() throws {
        var recorder = Recorder(at: start)
        recorder.run(meters: 1500, timeOffset: 0, using: point)
        let lastFix = start.addingTimeInterval(500)

        // The app closed; you open it again ten minutes later.
        let recording = try XCTUnwrap(RunJournal.recover(RunJournal.entries(in: recorder.file), now: lastFix.addingTimeInterval(600)))
        XCTAssertEqual(recording.tracker.state, .paused)
        XCTAssertEqual(recording.lastWritten, lastFix)
        XCTAssertEqual(recording.tracker.distance, recorder.tracker.distance, accuracy: 0.01)
        // The clock stopped at the last fix, not when you came back.
        XCTAssertEqual(recording.tracker.movingTime(at: lastFix.addingTimeInterval(600)), 500, accuracy: 0.01)

        // Carrying on adds to it.
        var tracker = recording.tracker
        tracker.resume(at: lastFix.addingTimeInterval(600))
        XCTAssertEqual(tracker.state, .running)
        XCTAssertEqual(tracker.segments.count, 2)
    }

    func testCutOffLongAgoIsFinishedWhereItStopped() throws {
        var recorder = Recorder(at: start)
        recorder.run(meters: 1500, timeOffset: 0, using: point)
        let lastFix = start.addingTimeInterval(500)

        // You don't open the app again until the next morning.
        let recording = try XCTUnwrap(RunJournal.recover(RunJournal.entries(in: recorder.file), now: lastFix.addingTimeInterval(14 * 3600)))
        XCTAssertEqual(recording.tracker.state, .finished)
        XCTAssertEqual(recording.tracker.endedAt, lastFix)
        XCTAssertEqual(recording.tracker.elapsedTime(at: .distantFuture), 500, accuracy: 0.01)
        XCTAssertEqual(recording.tracker.movingTime(at: .distantFuture), 500, accuracy: 0.01)
        XCTAssertEqual(recording.tracker.distance, recorder.tracker.distance, accuracy: 0.01)
    }

    func testPausedLongAgoFinishesWhenYouPaused() throws {
        var recorder = Recorder(at: start)
        recorder.run(meters: 900, timeOffset: 0, using: point)
        let paused = start.addingTimeInterval(400)
        recorder.pause(paused)

        let recording = try XCTUnwrap(RunJournal.recover(RunJournal.entries(in: recorder.file), now: paused.addingTimeInterval(3 * 3600)))
        XCTAssertEqual(recording.tracker.state, .finished)
        XCTAssertEqual(recording.tracker.endedAt, paused)
        XCTAssertEqual(recording.tracker.movingTime(at: .distantFuture), recorder.tracker.movingTime(at: paused), accuracy: 0.01)
    }

    func testFinishedButNotSavedComesBackAsItWas() throws {
        var recorder = Recorder(at: start)
        recorder.run(meters: 900, timeOffset: 0, using: point)
        let end = start.addingTimeInterval(320)
        recorder.finish(end)

        let recording = try XCTUnwrap(RunJournal.recover(RunJournal.entries(in: recorder.file), now: end.addingTimeInterval(60)))
        assertSame(recording.tracker, recorder.tracker, at: end)
    }
}
