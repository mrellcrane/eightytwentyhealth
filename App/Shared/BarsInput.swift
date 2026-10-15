import Foundation
import EightyTwentyCore

/// Turns SwiftData query results into the inputs `HealthBarsCalculator` wants.
struct BarsInput {
    let sensors: [DayKey: SensorDay]
    let reports: [DayKey: SelfReportDay]

    init(snapshots: [DailySnapshot], moods: [MoodEntry], gratitude: [GratitudeEntry], activities: [ActivityLog]) {
        var sensors: [DayKey: SensorDay] = [:]
        for snapshot in snapshots {
            if let sensor = snapshot.sensor { sensors[sensor.day] = sensor }
        }
        self.sensors = sensors

        let liveMoods = moods.filter { $0.deletedAt == nil }
            .map { SelfReportBuilder.Mood(timestamp: $0.timestamp, valence: $0.valence) }
        let practices = gratitude.filter { $0.deletedAt == nil }.map(\.date)
            + activities.filter { $0.deletedAt == nil && $0.activityKind?.isMentalPractice == true }.map(\.timestamp)
        self.reports = SelfReportBuilder.build(moods: liveMoods, practiceTimestamps: practices)
    }

    var calculator: HealthBarsCalculator { HealthBarsCalculator() }

    func display(_ kind: BarKind, on day: DayKey = DayKey(date: .now)) -> BarDisplay {
        calculator.display(kind, on: day, sensors: sensors, reports: reports)
    }

    /// Days in the last `window` with at least one mood check-in (the correlation engine's fuel).
    func moodDays(window: Int = 60, today: DayKey = DayKey(date: .now)) -> Int {
        let start = today.adding(days: -window)
        return reports.values.filter { $0.day > start && !$0.moodValences.isEmpty }.count
    }
}
