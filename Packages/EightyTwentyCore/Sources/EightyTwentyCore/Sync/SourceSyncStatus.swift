import Foundation

/// What Today shows for one data source (Oura, Apple Health), one line each.
public enum SourceSyncStatus: Equatable, Sendable {
    case notConnected
    case syncing
    case neverSynced
    case synced(at: Date)
    /// The latest try failed. `lastSynced` is the last one that worked, if any.
    case failed(lastSynced: Date?)

    public init(connected: Bool, syncing: Bool, lastSynced: Date?, lastTryFailed: Bool) {
        if !connected {
            self = .notConnected
        } else if syncing {
            self = .syncing
        } else if lastTryFailed {
            self = .failed(lastSynced: lastSynced)
        } else if let lastSynced {
            self = .synced(at: lastSynced)
        } else {
            self = .neverSynced
        }
    }
}
