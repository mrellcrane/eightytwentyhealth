import SwiftUI
import SwiftData

@main
struct EightyTwentyApp: App {
    private let model: AppModel?
    private let launchError: String?

    init() {
        NotificationService.shared.configure()
        do {
            let container = try Stores.makeContainer()
            model = AppModel(container: container)
            launchError = nil
        } catch {
            model = nil
            launchError = String(describing: error)
        }
    }

    var body: some Scene {
        WindowGroup {
            if let model {
                RootView()
                    .environment(model)
                    .modelContainer(model.container)
            } else {
                StoreErrorView(message: launchError ?? "Unknown error")
            }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) { [model] in
            await model?.backgroundRefresh()
        }
    }
}

/// Shown if the database can't open. Deliberately does nothing destructive:
/// your data stays on disk (and in iCloud and your backups) until a fixed build ships.
struct StoreErrorView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't open your data", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text("Nothing has been deleted. Your entries are still on this phone, in iCloud, and in your backups. Send this message to whoever builds the app:")
            Text(message)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }
}
