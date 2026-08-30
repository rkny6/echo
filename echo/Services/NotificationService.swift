import Foundation
import UserNotifications

/// Service for scheduling and managing notifications
actor NotificationService: NotificationScheduling {
    private let userNotificationCenter = UNUserNotificationCenter.current()

    init() {
        // Idempotent: AppDelegate already sets the same shared delegate at launch.
        // Keep this assignment so previews / tests that construct the service
        // without AppDelegate still get a working owner.
        userNotificationCenter.delegate = NotificationDelegate.shared
    }

    func scheduleNotification(
        title: String,
        body: String,
        delay: TimeInterval,
        metadata: [String: String]? = nil,
        identifier: String = UUID().uuidString
    ) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        // Add metadata as userInfo
        if let metadata = metadata {
            content.userInfo = metadata
        }

        let trigger: UNNotificationTrigger? = delay > 0
            ? UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
            : nil
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )

        try await userNotificationCenter.add(request)
    }

    func cancelNotification(identifier: String) async throws {
        userNotificationCenter.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    func cancelAllNotifications() async throws {
        userNotificationCenter.removeAllPendingNotificationRequests()
    }

    /// Request notification permissions
    func requestAuthorization() async throws -> Bool {
        return try await userNotificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
    }
}

// MARK: - Notification Delegate

/// Sole `UNUserNotificationCenterDelegate` for the process.
/// Foreground presentation + tap routing live here only.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .badge, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor in
            NotificationRouter.shared.handleNotificationUserInfo(userInfo)
        }
        completionHandler()
    }
}
