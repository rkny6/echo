import Foundation

/// Protocol for logging
protocol LoggingProviding: Sendable {
    /// Log a message. Implementations should bound retention (ring buffer).
    func log(_ message: String, level: LogLevel) async

    /// Get currently retained logs (may be a capped window, not full history)
    func getLogs() async -> [LogEntry]

    /// Clear all retained logs
    func clearLogs() async throws
}

/// Log level enumeration
enum LogLevel: String {
    case debug
    case info
    case warning
    case error
}

/// Single log entry
struct LogEntry: Identifiable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let message: String
}
