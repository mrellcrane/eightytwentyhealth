import Foundation
import os
import Sentry

/// App logging. Every line goes to the unified log (Console.app, subsystem
/// `eightytwenty`) and, when a Sentry DSN is configured, to Sentry, where a cloud
/// Claude Code session can read it (see CLAUDE.md). Errors also open a Sentry issue.
///
/// Never log health values, tokens or anything you wrote: messages leave the phone.
struct Log {
    static let app = Log(category: "app")
    static let oura = Log(category: "oura")
    static let sync = Log(category: "sync")
    static let health = Log(category: "health")
    static let backup = Log(category: "backup")
    static let coach = Log(category: "coach")
    static let meditation = Log(category: "meditation")

    let category: String
    private let logger: Logger

    init(category: String) {
        self.category = category
        self.logger = Logger(subsystem: "eightytwenty", category: category)
    }

    func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        SentrySDK.logger.info(message, attributes: ["category": category])
    }

    func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        SentrySDK.logger.warn(message, attributes: ["category": category])
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        SentrySDK.logger.error(message, attributes: ["category": category])
        SentrySDK.capture(message: "[\(category)] \(message)") { scope in
            scope.setLevel(.error)
            scope.setTag(value: category, key: "category")
        }
    }

    /// Starts Sentry if this build has a DSN (Config/Secrets.xcconfig locally,
    /// the SENTRY_DSN secret in CI). Without one, logging stays on the phone.
    static func start(bundle: Bundle = .main) {
        guard let host = bundle.object(forInfoDictionaryKey: "SentryDSN") as? String,
              !host.isEmpty, !host.hasPrefix("$(") else { return }
        SentrySDK.start { options in
            // Stored without the scheme: xcconfig reads "//" as a comment.
            options.dsn = host.contains("://") ? host : "https://" + host
            options.environment = environment
            options.enableLogs = true
            options.sendDefaultPii = false
            options.attachScreenshot = false
            options.attachViewHierarchy = false
        }
        let info = bundle.infoDictionary ?? [:]
        app.info("Launched \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?")), \(environment)")
    }

    private static var environment: String {
        #if DEBUG
        return "debug"
        #else
        // TestFlight installs carry a sandbox receipt; App Store ones don't.
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" ? "testflight" : "production"
        #endif
    }
}
