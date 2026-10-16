import Foundation
@testable import EightyTwentyCore

/// The owner's real test case: slept well after a 4.5-mile run the evening
/// before, felt great in the morning, and hit a wall at 1 PM on a workday.
enum CoachScenario {
    static let timeZone = TimeZone(identifier: "America/Los_Angeles")!
    static let today = DayKey("2026-10-15")! // a Thursday
    static let question = "i slept well last night after a 4.5 mile run yesterday and felt great this morning but now at 1pm i feel like i just hit a wall and am so freaking tired and have a bit of a headache. what should i do? i still have a couple more hours of work to do"

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func at(_ day: DayKey, _ hour: Int, _ minute: Int) -> Date {
        day.startDate(in: calendar).addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
    }

    static var now: Date { at(today, 13, 0) }

    static func sensors() -> [DayKey: SensorDay] {
        var result: [DayKey: SensorDay] = [:]
        for offset in 0..<40 {
            let key = today.adding(days: -offset)
            var day = SensorDay(day: key)
            let wobble = Double(offset % 5) - 2
            day.readinessScore = 80
            day.sleepScore = 80
            day.sleepSeconds = 7 * 3600
            day.averageHRV = 58 + wobble
            day.lowestHeartRate = 52 - wobble / 2
            day.ouraSteps = 9000
            day.stressHighMinutes = 90 + wobble * 10
            day.recoveryHighMinutes = 60
            result[key] = day
        }
        // Last night: a good one.
        var last = result[today]!
        last.readinessScore = 84
        last.sleepScore = 86
        last.sleepSeconds = 7.3 * 3600
        last.sleepEfficiency = 91
        last.averageHRV = 63
        last.lowestHeartRate = 50
        last.bedtimeStart = at(today.adding(days: -1), 21, 52)
        last.bedtimeEnd = at(today, 5, 24)
        last.temperatureDeviation = 0.1
        last.spo2Average = 97
        last.ouraSteps = 3900 // so far, at a desk since 6
        result[today] = last
        // Yesterday: the run.
        var yesterday = result[today.adding(days: -1)]!
        yesterday.ouraSteps = 13_800
        yesterday.activeCalories = 780
        yesterday.workoutMinutes = 41
        yesterday.stressHighMinutes = 95
        yesterday.recoveryHighMinutes = 70
        result[today.adding(days: -1)] = yesterday
        return result
    }

    static var moods: [CoachContext.Mood] {
        [
            CoachContext.Mood(timestamp: at(today.adding(days: -1), 18, 50), valence: 1, energy: 4, emotions: ["proud", "happy"]),
            CoachContext.Mood(timestamp: at(today, 6, 45), valence: 2.0 / 3, energy: 4, emotions: ["calm", "hopeful"]),
        ]
    }

    static func reports() -> [DayKey: SelfReportDay] {
        var result: [DayKey: SelfReportDay] = [:]
        for mood in moods {
            let key = DayKey(date: mood.timestamp, calendar: calendar)
            result[key, default: SelfReportDay(day: key)].moodValences.append(mood.valence)
        }
        for offset in [1, 3, 5] {
            let key = today.adding(days: -offset)
            result[key, default: SelfReportDay(day: key)].practiced = true
        }
        return result
    }

    static func context() -> CoachContext {
        let sensors = sensors()
        let reports = reports()
        let calculator = HealthBarsCalculator()
        return CoachContext(
            now: now,
            timeZone: timeZone,
            work: CoachContext.WorkHours(startMinutes: 6 * 60, endMinutes: 16 * 60, weekdaysOnly: true),
            bedtimeMinutes: 22 * 60 + 15,
            physical: calculator.display(.physical, on: today, sensors: sensors, reports: reports),
            mental: calculator.display(.mental, on: today, sensors: sensors, reports: reports),
            today: sensors[today],
            yesterday: sensors[today.adding(days: -1)],
            activities: [
                CoachContext.Activity(timestamp: at(today.adding(days: -1), 17, 40), title: "Run", minutes: 38,
                                      distanceMeters: 4.5 * 1609.344),
                CoachContext.Activity(timestamp: at(today.adding(days: -3), 12, 10), title: "Walk", minutes: 20),
            ],
            moods: moods,
            usesMiles: true
        )
    }
}
