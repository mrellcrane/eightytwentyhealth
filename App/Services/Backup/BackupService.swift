import Foundation
import SwiftData
import EightyTwentyCore

/// Plain-JSON backups of everything you created, written to two places:
/// iCloud Drive (survives losing the phone) and the app's Documents folder
/// (Files > On My iPhone > 80/20). Runs automatically at most once a day.
@MainActor
@Observable
final class BackupService {
    static let keepAutomaticBackups = 30
    static let automaticInterval: TimeInterval = 20 * 60 * 60

    private(set) var lastError: String?
    private(set) var lastLocations: [String] = []

    private(set) var lastBackupAt: Date? = UserDefaults.standard.object(forKey: "lastBackupAt") as? Date

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    func backupIfDue(context: ModelContext) async {
        if let lastBackupAt, Date().timeIntervalSince(lastBackupAt) < Self.automaticInterval { return }
        await backupNow(context: context)
    }

    /// Writes a backup to every available location. Returns the local file (for sharing).
    @discardableResult
    func backupNow(context: ModelContext) async -> URL? {
        do {
            let document = try Repository(context: context).backupDocument(appVersion: appVersion)
            // Nothing to protect yet: don't litter empty files.
            guard !document.isEmpty else { return nil }
            let data = try document.encoded()
            let name = BackupFiles.fileName(for: document.exportedAt)

            var written: [String] = []
            var localURL: URL?
            if let folder = Self.localFolder() {
                let url = folder.appendingPathComponent(name)
                try data.write(to: url, options: .atomic)
                Self.prune(folder)
                localURL = url
                written.append("On My iPhone")
            }
            if let folder = await Self.iCloudFolder() {
                try await Self.coordinatedWrite(data, to: folder.appendingPathComponent(name))
                Self.prune(folder)
                written.append("iCloud Drive")
            }
            lastBackupAt = document.exportedAt
            UserDefaults.standard.set(document.exportedAt, forKey: "lastBackupAt")
            lastLocations = written
            lastError = nil
            return localURL
        } catch {
            Log.backup.error("Backup failed: \(String(describing: error))")
            lastError = error.localizedDescription
            return nil
        }
    }

    func restore(from url: URL, context: ModelContext) throws -> (moods: Int, gratitude: Int, activities: Int) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let backup = try BackupDocument.decode(Data(contentsOf: url))
        return try Repository(context: context).restore(backup)
    }

    // MARK: Locations

    static func localFolder() -> URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let folder = documents.appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Nil when iCloud is off, signed out, or the app was built without iCloud.
    static func iCloudFolder() async -> URL? {
        // This call can block, so keep it off the main thread.
        await Task.detached(priority: .utility) { () -> URL? in
            guard FileManager.default.ubiquityIdentityToken != nil,
                  let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return nil }
            let folder = container.appendingPathComponent("Documents/Backups", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }.value
    }

    private static func coordinatedWrite(_ data: Data, to url: URL) async throws {
        try await Task.detached(priority: .utility) {
            var coordinationError: NSError?
            var writeError: Error?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
                do {
                    try data.write(to: target, options: .atomic)
                } catch {
                    writeError = error
                }
            }
            if let error = coordinationError ?? writeError { throw error }
        }.value
    }

    private static func prune(_ folder: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in BackupFiles.filesToPrune(names, keep: keepAutomaticBackups) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
