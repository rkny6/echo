import Foundation

/// Protocol for scheduling notifications
protocol NotificationScheduling: Sendable {
    /// Schedule a notification to be sent at a specific time.
    /// - Parameter identifier: stable id so the notification can later be cancelled
    ///   (e.g. if it was pre-scheduled as a fallback and then delivered in-app instead).
    func scheduleNotification(
        title: String,
        body: String,
        delay: TimeInterval,
        metadata: [String: String]?,
        identifier: String
    ) async throws

    /// Cancel a single pending notification by identifier.
    func cancelNotification(identifier: String) async throws

    /// Cancel all pending notifications
    func cancelAllNotifications() async throws
    
    /// Request notification permissions
    func requestAuthorization() async throws -> Bool
}

extension NotificationScheduling {
    /// Convenience overload for call sites that don't need to cancel the
    /// notification later — generates a random identifier internally.
    func scheduleNotification(
        title: String,
        body: String,
        delay: TimeInterval,
        metadata: [String: String]? = nil
    ) async throws {
        try await scheduleNotification(
            title: title,
            body: body,
            delay: delay,
            metadata: metadata,
            identifier: UUID().uuidString
        )
    }
}
