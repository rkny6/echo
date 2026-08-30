import Foundation
import OSLog

struct AppLog {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "echo", category: "AppLog")

    static func debug(_ category: String, _ message: String) {
        logger.debug("[\(category)] \(message, privacy: .public)")
    }

    static func info(_ category: String, _ message: String) {
        logger.info("[\(category)] \(message, privacy: .public)")
    }

    static func warning(_ category: String, _ message: String) {
        logger.warning("[\(category)] \(message, privacy: .public)")
    }

    static func error(_ category: String, _ message: String) {
        logger.error("[\(category)] \(message, privacy: .public)")
    }
}
