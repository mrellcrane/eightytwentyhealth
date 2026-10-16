import SwiftUI
import EightyTwentyCore

extension BarKind {
    var color: Color {
        switch self {
        case .physical: return .orange
        case .mental: return .indigo
        }
    }

    var systemImage: String {
        switch self {
        case .physical: return "figure.run"
        case .mental: return "brain.head.profile"
        }
    }
}

/// A horizontal health bar with the score and how it moved.
struct HealthBarView: View {
    let display: BarDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(display.kind.title, systemImage: display.kind.systemImage)
                    .font(.headline)
                Spacer()
                if let value = display.value {
                    Text("\(Int(value.rounded()))")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                } else {
                    Text("--")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(display.kind.color.opacity(0.15))
                    Capsule()
                        .fill(display.kind.color.gradient)
                        .frame(width: proxy.size.width * CGFloat((display.value ?? 0) / 100))
                    // Tick at 75: "your normal".
                    Rectangle()
                        .fill(.primary.opacity(0.35))
                        .frame(width: 2)
                        .offset(x: proxy.size.width * 0.75 - 1)
                }
            }
            .frame(height: 14)
            .accessibilityHidden(true)

            HStack(spacing: 12) {
                DeltaText(label: "vs yesterday", delta: display.changeFromYesterday)
                DeltaText(label: "vs 7-day avg", delta: display.changeFromWeekAverage)
                Spacer()
                if display.today.coverage < 0.999 {
                    Text("\(Int((display.today.coverage * 100).rounded()))% of data")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

struct DeltaText: View {
    let label: String
    let delta: Double?

    var body: some View {
        if let delta {
            let rounded = Int(delta.rounded())
            HStack(spacing: 2) {
                Image(systemName: rounded > 0 ? "arrow.up" : rounded < 0 ? "arrow.down" : "equal")
                Text("\(abs(rounded)) \(label)")
            }
            .font(.caption)
            .foregroundStyle(rounded > 0 ? .green : rounded < 0 ? .red : .secondary)
        }
    }
}

/// Faces for the 7 steps of `MoodScale`, very unpleasant to very pleasant.
enum MoodFaces {
    static let all = ["😣", "🙁", "😕", "😐", "🙂", "😊", "😄"]
}

/// Wrapping row of chips (emotion words, etc).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews: subviews, width: bounds.width)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

struct Chip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

/// Big round start/stop style button used by the timer and run screens.
struct RoundButton: View {
    let title: String
    let systemImage: String
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage).font(.title)
                Text(title).font(.headline)
            }
            .frame(width: 96, height: 96)
            .background(tint.gradient, in: Circle())
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}
