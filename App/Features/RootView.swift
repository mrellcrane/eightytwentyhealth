import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            NavigationStack { TodayView() }
                .tabItem { Label("Today", systemImage: "chart.bar.fill") }
            NavigationStack { LogView() }
                .tabItem { Label("Log", systemImage: "square.and.pencil") }
            NavigationStack { RecordView() }
                .tabItem { Label("Record", systemImage: "record.circle") }
            NavigationStack { InsightsView() }
                .tabItem { Label("Insights", systemImage: "chart.xyaxis.line") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                Task { await model.onForeground() }
            }
        }
        .alert("Heads up", isPresented: Binding(
            get: { model.notice != nil },
            set: { if !$0 { model.notice = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.notice ?? "")
        }
    }
}
