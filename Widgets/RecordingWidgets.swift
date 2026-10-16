import ActivityKit
import SwiftUI
import WidgetKit
import EightyTwentyCore

@main
struct RecordingWidgets: WidgetBundle {
    var body: some Widget {
        RecordingActivityWidget()
    }
}

/// The run or walk you're recording, on the Lock Screen and in the Dynamic Island:
/// time, distance and average pace. The app keeps it current (`RunRecorder`).
struct RecordingActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.activity.title, systemImage: context.attributes.activity.systemImage)
                        .font(.headline)
                        .foregroundStyle(context.attributes.tint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ClockText(state: context.state)
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .multilineTextAlignment(.trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Stat(label: context.attributes.unitLabel) { Text(context.attributes.distance(context.state)) }
                        Stat(label: "avg /\(context.attributes.unitLabel)") { Text(context.attributes.pace(context.state)) }
                    }
                }
            } compactLeading: {
                Image(systemName: context.attributes.activity.systemImage)
                    .foregroundStyle(context.attributes.tint)
            } compactTrailing: {
                Text("\(context.attributes.distance(context.state)) \(context.attributes.unitLabel)")
                    .monospacedDigit()
            } minimal: {
                Image(systemName: context.attributes.activity.systemImage)
                    .foregroundStyle(context.attributes.tint)
            }
            .keylineTint(context.attributes.tint)
        }
    }
}

private struct LockScreenView: View {
    let attributes: RecordingAttributes
    let state: RecordingAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(attributes.activity.title, systemImage: attributes.activity.systemImage)
                    .font(.headline)
                    .foregroundStyle(attributes.tint)
                Spacer()
                if state.isPaused {
                    Text("Paused").font(.subheadline.bold()).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top) {
                Stat(label: "Time") { ClockText(state: state) }
                Stat(label: attributes.unitLabel) { Text(attributes.distance(state)) }
                Stat(label: "avg /\(attributes.unitLabel)") { Text(attributes.pace(state)) }
            }
            if let latest = state.latest {
                Text(latest).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}

/// Moving time. Ticks by itself while you move; stands still while paused.
private struct ClockText: View {
    let state: RecordingAttributes.ContentState

    var body: some View {
        if state.isPaused {
            Text(PaceFormat.duration(state.movingSeconds))
        } else {
            Text(state.clockStart, style: .timer)
        }
    }
}

private struct Stat<Value: View>: View {
    let label: String
    @ViewBuilder let value: Value

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            value
                .font(.title2.monospacedDigit().weight(.semibold))
                .lineLimit(1)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension RecordingAttributes {
    var tint: Color { activity == .walk ? .green : .orange }

    func distance(_ state: ContentState) -> String {
        PaceFormat.distance(state.meters, unitMeters: unitMeters)
    }

    func pace(_ state: ContentState) -> String {
        PaceFormat.pace(state.averagePace, unitMeters: unitMeters)
    }
}
