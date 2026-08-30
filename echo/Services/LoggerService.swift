import Foundation

/// Service for application logging.
///
/// In-memory entries are capped with a ring buffer so long sessions
/// (proactive timers, health checks, chat loops) cannot grow unbounded.
actor LoggerService: LoggingProviding {
    /// Maximum retained log entries. Oldest entries are dropped first.
    static let defaultMaxEntries = 500

    private let maxEntries: Int
    private var logEntries: [LogEntry] = []

    init(maxEntries: Int = LoggerService.defaultMaxEntries) {
        self.maxEntries = max(1, maxEntries)
    }

    func log(_ message: String, level: LogLevel) async {
        let entry = LogEntry(
            id: UUID(),
            timestamp: Date(),
            level: level,
            message: message
        )
        logEntries.append(entry)
        trimIfNeeded()

        switch level {
        case .debug:
            AppLog.debug("LoggerService", message)
        case .info:
            AppLog.info("LoggerService", message)
        case .warning:
            AppLog.warning("LoggerService", message)
        case .error:
            AppLog.error("LoggerService", message)
        }
    }

    func getLogs() async -> [LogEntry] {
        return logEntries
    }

    func clearLogs() async throws {
        logEntries.removeAll(keepingCapacity: true)
    }

    private func trimIfNeeded() {
        let overflow = logEntries.count - maxEntries
        guard overflow > 0 else { return }
        logEntries.removeFirst(overflow)
    }
}
