import SwiftUI
import SwiftData
import Charts
import EightyTwentyCore

/// Trends, raw pictures, and personal patterns (`PatternFinder`), which need
/// 3 weeks of data for a pair before they say anything.
struct InsightsView: View {
    @Query private var snapshots: [DailySnapshot]
    @Query(filter: #Predicate<MoodEntry> { $0.deletedAt == nil }) private var moods: [MoodEntry]
    @Query(filter: #Predicate<GratitudeEntry> { $0.deletedAt == nil }) private var gratitude: [GratitudeEntry]
    @Query(filter: #Predicate<ActivityLog> { $0.deletedAt == nil }) private var activities: [ActivityLog]

    private static let patternWindowDays = 120
    private static let patternsShown = 5

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

            let patterns = PatternFinder.find(
                in: patternData(input: input),
                days: DayKey.range(from: today.adding(days: -Self.patternWindowDays), through: today)
            )
            Section {
                let moodDays = input.moodDays()
                if moodDays < PatternFinder.minimumDays {
                    Text("Mood pairs need \(PatternFinder.minimumDays) days with a check-in: \(moodDays) so far.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if patterns.isEmpty {
                    Text("A pair shows up here once it has \(PatternFinder.minimumDays) days of data.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(patterns.prefix(Self.patternsShown)) { PatternRow(pattern: $0) }
                    if patterns.count > Self.patternsShown {
                        DisclosureGroup("\(patterns.count - Self.patternsShown) more pairs") {
                            ForEach(patterns.dropFirst(Self.patternsShown)) { PatternRow(pattern: $0) }
                        }
                    }
                }
            } header: {
                Text("Personal patterns")
            } footer: {
                Text("r is Spearman's correlation, from -1 to 1. p allows for days running into each other; adjusted p also corrects for testing \(patterns.count) pairs at once. \"Holds up\" means adjusted p under 0.05. A pattern, not proof of cause.")
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
            guard let sensor = input.sensors[day], let hours = sensor.bedtimeHoursFromMidnight(), let hrv = sensor.averageHRV else { return nil }
            return BedtimePoint(day: day, hoursFromMidnight: hours, hrv: hrv)
        }
        // Fit the axis to your actual bedtimes (at least 9p-2a), one label per hour.
        let hours = points.map(\.hoursFromMidnight)
        let lower = min(-3, (hours.min() ?? -3).rounded(.down))
        let upper = max(2, (hours.max() ?? 2).rounded(.up))
        return Chart(points) { point in
            PointMark(
                x: .value("Bedtime", point.hoursFromMidnight),
                y: .value("HRV", point.hrv)
            )
            .foregroundStyle(.indigo)
        }
        .chartXScale(domain: lower...upper)
        .chartXAxis {
            AxisMarks(values: Array(stride(from: lower, through: upper, by: 1))) { value in
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

    private func patternData(input: BarsInput) -> PatternData {
        var logged: [DayKey: Set<ActivityKind>] = [:]
        for log in activities {
            if let kind = log.activityKind { logged[DayKey(date: log.timestamp), default: []].insert(kind) }
        }
        let firstLog = (activities.map(\.timestamp) + gratitude.map(\.date)).min()
        return PatternData(
            sensors: input.sensors,
            reports: input.reports,
            activities: logged,
            loggingStart: firstLog.map { DayKey(date: $0) }
        )
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

private struct PatternRow: View {
    let pattern: PersonalPattern

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(pattern.input.title) → \(pattern.outcome.title)")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(String(format: "r %+.2f", pattern.r))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            }
            .foregroundStyle(pattern.holdsUp ? HierarchicalShapeStyle.primary : .secondary)
            Text(pattern.summary)
                .font(.caption)
            HStack(spacing: 4) {
                if pattern.holdsUp {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("Holds up ·")
                }
                Text("p \(PersonalPattern.formatP(pattern.p)) · adj. \(PersonalPattern.formatP(pattern.adjustedP)) · \(daysText)")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var daysText: String {
        let independent = Int(pattern.effectiveDays.rounded())
        return independent < pattern.days ? "\(pattern.days) days, worth \(independent)" : "\(pattern.days) days"
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
