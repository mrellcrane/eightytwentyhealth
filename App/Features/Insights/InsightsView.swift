import SwiftUI
import SwiftData
import Charts
import EightyTwentyCore

/// Phase 1: trends and raw pictures. Phase 3 adds the correlation engine,
/// which needs ~3 weeks of logging before it says anything.
struct InsightsView: View {
    @Query private var snapshots: [DailySnapshot]
    @Query(filter: #Predicate<MoodEntry> { $0.deletedAt == nil }) private var moods: [MoodEntry]
    @Query(filter: #Predicate<GratitudeEntry> { $0.deletedAt == nil }) private var gratitude: [GratitudeEntry]
    @Query(filter: #Predicate<ActivityLog> { $0.deletedAt == nil }) private var activities: [ActivityLog]

    private static let patternDaysNeeded = 21

    var body: some View {
        let input = BarsInput(snapshots: snapshots, moods: moods, gratitude: gratitude, activities: activities)
        let today = DayKey(date: .now)
        let days = DayKey.range(from: today.adding(days: -29), through: today)

        List {
            Section {
                trendChart(input: input, days: days)
                    .frame(height: 220)
                    .padding(.vertical, 8)
            } header: {
                Text("Your bars, last 30 days")
            }

            Section {
                let moodDays = input.moodDays()
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: Double(min(moodDays, Self.patternDaysNeeded)), total: Double(Self.patternDaysNeeded))
                    Text(moodDays >= Self.patternDaysNeeded
                         ? "Enough data. Pattern finding arrives in the next build."
                         : "\(moodDays) of \(Self.patternDaysNeeded) days with a mood check-in. Patterns unlock after that.")
                        .font(.subheadline)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Personal patterns")
            } footer: {
                Text("Fewer days than this and any \"pattern\" is mostly luck.")
            }

            Section {
                bedtimeChart(input: input, days: DayKey.range(from: today.adding(days: -59), through: today))
                    .frame(height: 220)
                    .padding(.vertical, 8)
            } header: {
                Text("Bedtime vs overnight HRV")
            } footer: {
                Text("Just a picture of your last 60 nights, not a finding yet. Each dot is one night.")
            }
        }
        .navigationTitle("Insights")
    }

    private func trendChart(input: BarsInput, days: [DayKey]) -> some View {
        let calculator = input.calculator
        var points: [TrendPoint] = []
        for kind in BarKind.allCases {
            for item in calculator.series(kind, days: days, sensors: input.sensors, reports: input.reports) {
                if let value = item.value {
                    points.append(TrendPoint(kind: kind, date: item.day.startDate(), value: value))
                }
            }
        }
        return Chart(points) { point in
            LineMark(
                x: .value("Day", point.date, unit: .day),
                y: .value("Score", point.value)
            )
            .foregroundStyle(by: .value("Bar", point.kind.title))
            .interpolationMethod(.catmullRom)
        }
        .chartForegroundStyleScale([BarKind.physical.title: BarKind.physical.color, BarKind.mental.title: BarKind.mental.color])
        .chartYScale(domain: 0...100)
        .overlay {
            if points.isEmpty {
                Text("Connect Oura and log a few check-ins to see trends.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func bedtimeChart(input: BarsInput, days: [DayKey]) -> some View {
        let points: [BedtimePoint] = days.compactMap { day in
            guard let sensor = input.sensors[day], let bedtime = sensor.bedtimeStart, let hrv = sensor.averageHRV else { return nil }
            // Hours relative to midnight: 22:30 -> -1.5, 01:02 -> 1.03.
            let c = Calendar.current.dateComponents([.hour, .minute], from: bedtime)
            var hours = Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
            if hours > 12 { hours -= 24 }
            return BedtimePoint(day: day, hoursFromMidnight: hours, hrv: hrv)
        }
        return Chart(points) { point in
            PointMark(
                x: .value("Bedtime", point.hoursFromMidnight),
                y: .value("HRV", point.hrv)
            )
            .foregroundStyle(.indigo)
        }
        .chartXAxis {
            AxisMarks(values: [-3, -2, -1, 0, 1, 2]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let hours = value.as(Double.self) {
                        Text(Self.clockLabel(hours))
                    }
                }
            }
        }
        .chartXAxisLabel("Bedtime")
        .chartYAxisLabel("HRV (ms)")
        .overlay {
            if points.isEmpty {
                Text("Needs Oura sleep data.").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private static func clockLabel(_ hoursFromMidnight: Double) -> String {
        let hour = (Int(hoursFromMidnight.rounded()) + 24) % 24
        switch hour {
        case 0: return "12a"
        case 12: return "12p"
        case 13...23: return "\(hour - 12)p"
        default: return "\(hour)a"
        }
    }
}

private struct TrendPoint: Identifiable {
    let kind: BarKind
    let date: Date
    let value: Double
    var id: String { "\(kind.rawValue)-\(date.timeIntervalSince1970)" }
}

private struct BedtimePoint: Identifiable {
    let day: DayKey
    let hoursFromMidnight: Double
    let hrv: Double
    var id: String { day.rawValue }
}
