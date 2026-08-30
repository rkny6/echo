import Foundation
import SwiftUI

@MainActor
final class ChatFeature {
    private let manager: ConversationManaging
    private let chatStore: ChatMessageStore
    private let logger: LoggingProviding

    init(conversationManager: ConversationManaging, chatStore: ChatMessageStore, logger: LoggingProviding) {
        self.manager = conversationManager
        self.chatStore = chatStore
        self.logger = logger
    }

    func sendMessage(_ content: String, conversationId: UUID) async throws { try await manager.sendMessage(content, conversationId: conversationId) }
    func sendImage(id: UUID, content: String, imageData: Data, imageMimeType: String, conversationId: UUID) async throws { try await manager.sendImageMessage(id: id, content: content, imageData: imageData, imageMimeType: imageMimeType, conversationId: conversationId) }
    func resend(id: UUID) async throws { try await manager.resendMessage(id: id) }
    func startConversation(event: CompanionEvent) async throws { try await manager.startConversation(event: event) }
    func state() async -> ConversationState { await manager.getConversationState() }
    func currentConversationId() async -> UUID? { await manager.getCurrentConversationId() }
    func reconcileAfterForeground() async { await manager.reconcileAfterForeground() }
    func recoverInterruptedUserReplies() async { await manager.recoverInterruptedUserReplies() }
    func recordTyping(_ text: String) async { await manager.recordTypingActivity(text) }
    func debugInfo() async throws -> ConversationDebugInfo { try await manager.getDebugInfo() }
    func afterMessagesDeleted(messageIDs: Set<UUID>, conversationIds: Set<UUID>) async { await manager.afterMessagesDeleted(messageIDs: messageIDs, conversationIds: conversationIds) }
    func forceProcessPendingEvents() async throws { try await manager.forceProcessPendingEvents() }
    func forceDeliverPendingResponses() async throws { try await manager.forceDeliverPendingResponses() }
    func clearAllPendingEvents() async throws { try await manager.clearAllPendingEvents() }
    func clearAllPendingResponses() async throws { try await manager.clearAllPendingResponses() }
}
