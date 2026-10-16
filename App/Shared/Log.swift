import os

/// Unified logging. View on a connected phone with Console.app (filter
/// subsystem `eightytwenty`), or launch with OS_ACTIVITY_DT_MODE=1 to mirror to stderr.
enum Log {
    static let oura = Logger(subsystem: "eightytwenty", category: "oura")
    static let sync = Logger(subsystem: "eightytwenty", category: "sync")
    static let health = Logger(subsystem: "eightytwenty", category: "health")
}
