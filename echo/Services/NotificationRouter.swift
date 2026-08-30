import Foundation

/// Routes notification taps into the SwiftUI shell.
///
/// `UNUserNotificationCenterDelegate` is process-wide and lives outside the
/// view hierarchy; this small MainActor store is the bridge so RootView can
/// switch to the chat tab and AppViewModel can refresh history.
@MainActor
final class NotificationRouter: ObservableObject {
    static let shared = NotificationRouter()

    /// Bumped on every tap so observers fire even when conversationId repeats.
    @Published private(set) var openChatToken: Int = 0
    @Published private(set) var conversationId: UUID?
    @Published private(set) var responseId: UUID?

    private init() {}

    /// Parse `userInfo` written by NotificationService / DelayedResponseManager.
    func handleNotificationUserInfo(_ userInfo: [AnyHashable: Any]) {
        let conversationId = Self.uuid(from: userInfo["conversationId"])
        let responseId = Self.uuid(from: userInfo["responseId"])
        // Only act on taps that look like our chat notifications.
        guard conversationId != nil || responseId != nil || userInfo["eventType"] != nil else {
            // Still open chat for unknown companion banners that lack metadata.
            openChat(conversationId: nil, responseId: nil)
            return
        }
        openChat(conversationId: conversationId, responseId: responseId)
    }

    func openChat(conversationId: UUID?, responseId: UUID? = nil) {
        self.conversationId = conversationId
        self.responseId = responseId
        openChatToken &+= 1
    }

    private static func uuid(from value: Any?) -> UUID? {
        if let uuid = value as? UUID { return uuid }
        if let string = value as? String { return UUID(uuidString: string) }
        return nil
    }
}
