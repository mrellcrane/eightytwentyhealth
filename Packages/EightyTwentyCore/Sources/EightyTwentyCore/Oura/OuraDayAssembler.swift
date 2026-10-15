import Foundation

/// Merges Oura's separate endpoint responses into one `SensorDay` per day.
public enum OuraDayAssembler {
    public static func assemble(_ bundle: OuraBundle) -> [DayKey: SensorDay] {
        var days: [DayKey: SensorDay] = [:]

        func update(_ dayString: String, _ apply: (inout SensorDay) -> Void) {
            guard let key = DayKey(dayString) else { return }
            var day = days[key] ?? SensorDay(day: key)
            apply(&day)
            days[key] = day
        }

        for item in bundle.readiness {
            update(item.day) {
                $0.readinessScore = item.score
                $0.temperatureDeviation = item.temperatureDeviation
            }
        }
        for item in bundle.dailySleep {
            update(item.day) { $0.sleepScore = item.score }
        }
        for (day, period) in mainSleepPeriods(bundle.sleepPeriods) {
            update(day) {
                $0.sleepSeconds = period.totalSleepDuration
                $0.sleepEfficiency = period.efficiency
                $0.bedtimeStart = OuraJSON.date(period.bedtimeStart)
                $0.bedtimeEnd = OuraJSON.date(period.bedtimeEnd)
                $0.averageHRV = period.averageHrv
                $0.lowestHeartRate = period.lowestHeartRate
            }
        }
        for item in bundle.activity {
            update(item.day) {
                $0.activityScore = item.score
                $0.ouraSteps = item.steps
                $0.activeCalories = item.activeCalories
            }
        }
        for item in bundle.stress {
            update(item.day) {
                $0.stressHighMinutes = item.stressHigh.map { $0 / 60 }
                $0.recoveryHighMinutes = item.recoveryHigh.map { $0 / 60 }
                $0.stressSummary = item.daySummary
            }
        }
        for item in bundle.resilience {
            update(item.day) { $0.resilienceLevel = item.level }
        }
        for item in bundle.spo2 {
            update(item.day) { $0.spo2Average = item.spo2Percentage?.average }
        }
        for item in bundle.vo2Max where item.vo2Max != nil {
            update(item.day) { $0.vo2Max = item.vo2Max }
        }

        var workoutMinutes: [String: Double] = [:]
        for workout in bundle.workouts {
            guard let start = OuraJSON.date(workout.startDatetime),
                  let end = OuraJSON.date(workout.endDatetime), end > start else { continue }
            workoutMinutes[workout.day, default: 0] += end.timeIntervalSince(start) / 60
        }
        for (day, minutes) in workoutMinutes {
            update(day) { $0.workoutMinutes = minutes }
        }

        return days
    }

    /// The night's main sleep for each day: the "long_sleep" period if there is one,
    /// otherwise the longest real sleep. Naps, rests and deleted periods are ignored.
    static func mainSleepPeriods(_ periods: [OuraSleepPeriod]) -> [String: OuraSleepPeriod] {
        var best: [String: OuraSleepPeriod] = [:]
        for period in periods {
            let type = period.type ?? "sleep"
            guard type == "long_sleep" || type == "sleep" else { continue }
            guard let current = best[period.day] else {
                best[period.day] = period
                continue
            }
            if rank(period) > rank(current) {
                best[period.day] = period
            }
        }
        return best
    }

    private static func rank(_ period: OuraSleepPeriod) -> (Int, Double) {
        (period.type == "long_sleep" ? 1 : 0, period.totalSleepDuration ?? 0)
    }
}
