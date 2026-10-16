import SwiftUI

/// The "do the thing" tab: the two trackers that log themselves.
struct RecordView: View {
    var body: some View {
        List {
            NavigationLink {
                MeditationView()
            } label: {
                RecordRow(
                    title: "Meditate",
                    subtitle: "Timer with optional interval bells. Logs itself and saves Mindful Minutes to Apple Health.",
                    systemImage: "figure.mind.and.body",
                    tint: .indigo
                )
            }
            NavigationLink {
                RunView()
            } label: {
                RecordRow(
                    title: "Run or walk",
                    subtitle: "GPS time, distance, pace and route. Keeps going with the screen locked. Saves a workout to Apple Health; only runs count toward your running plan.",
                    systemImage: "figure.run",
                    tint: .orange
                )
            }
        }
        .navigationTitle("Record")
    }
}

private struct RecordRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.title)
                .frame(width: 56, height: 56)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }
}
