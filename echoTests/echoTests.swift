//
//  echoTests.swift
//  echoTests
//
//  Created by rkny6 on 4/16/26.
//

import Foundation
import SwiftData
import Testing
import UIKit
@testable import echo

struct echoTests {

    @Test func conversationStateIncludesWaitingForResponse() {
        #expect(ConversationState.waitingForResponse.rawValue == "waitingForResponse")
    }

    @Test func healthAlertDedupKeyIsStablePerDay() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let key1 = HealthAlertDedup.key(for: .sleep, date: date)
        let key2 = HealthAlertDedup.key(for: .sleep, date: date)
        #expect(key1 == key2)
        #expect(key1.hasPrefix("sleep_"))
    }

    @Test func extremeStepThresholdsAreStricterThanModerate() {
        #expect(HealthProactiveThresholds.stepsExtremelyLow < 2000)
        #expect(HealthProactiveThresholds.stepsExtremelyHigh > 10000)
    }

    @Test func softMorningSleepCareIsMilderAndPreNoon() {
        #expect(HealthProactiveThresholds.sleepSoftCareStartHour < HealthProactiveThresholds.sleepSoftCareEndHour)
        #expect(HealthProactiveThresholds.sleepSoftCareEndHour <= 12)
        #expect(HealthProactiveThresholds.sleepDurationSoftLowMinutes > HealthProactiveThresholds.sleepDurationExtremelyLowMinutes)
        #expect(HealthProactiveThresholds.sleepDurationSoftHighMinutes < HealthProactiveThresholds.sleepDurationExtremelyHighMinutes)
        #expect(HealthProactiveThresholds.sleepQualitySoftLow > HealthProactiveThresholds.sleepQualityExtremelyLow)
        #expect(HealthProactiveThresholds.sleepSoftCareProbability > 0)
        #expect(HealthProactiveThresholds.sleepSoftCareProbability < 1)
        #expect(HealthProactiveThresholds.sleepSoftCareCooldownDays >= 2)
    }

    @Test func menstrualProactiveUsesCycleScopedDedupKey() {
        #expect(HealthProactiveThresholds.menstrualApproachWindowDays == 3)

        let cycleKey = "1700000000"
        let event = CompanionEvent(
            type: .menstrualCycle,
            priority: CompanionEventType.menstrualCycle.defaultPriority,
            metadata: [
                "daysUntilStart": "2",
                "cycleKey": cycleKey,
                "source": "health_proactive"
            ]
        )

        let day1 = Date(timeIntervalSince1970: 1_700_000_000)
        let day2 = day1.addingTimeInterval(24 * 3600)
        let key1 = HealthAlertDedup.key(for: event, date: day1)
        let key2 = HealthAlertDedup.key(for: event, date: day2)
        #expect(key1 == "menstrualCycle_cycle_\(cycleKey)")
        #expect(key1 == key2)

        // Without cycleKey, fall back to per-day key (legacy / non-proactive path).
        let legacy = CompanionEvent(type: .menstrualCycle, metadata: ["daysUntilStart": "1"])
        let legacyKey = HealthAlertDedup.key(for: legacy, date: day1)
        #expect(legacyKey.hasPrefix("menstrualCycle_"))
        #expect(!legacyKey.contains("_cycle_"))
    }

    @Test func eveningCheckInIsSeparateFromOnlineGreeting() {
        #expect(CompanionEventType.eveningCheckIn.rawValue == "eveningCheckIn")
        #expect(CompanionEventType.eveningCheckIn.defaultPriority < CompanionEventType.onlineGreeting.defaultPriority)
        #expect(CompanionEventType.eveningCheckIn.isHealthEventType == false)
        #expect(ProactiveSendSource.eveningCheckIn.rawValue == "eveningCheckIn")

        let event = CompanionEvent(
            type: .eveningCheckIn,
            metadata: ["hoursSinceContact": "14.0", "source": "evening_check_in"]
        )
        let description = EventMessageService.describe(event)
        #expect(description.contains("晚上"))
    }

    @Test func optimizedImageRecognizerRejectsInvalidImage() async {
        let recognizer = OptimizedImageRecognizer()
        // Empty UIImage has no CIImage representation.
        await #expect(throws: OptimizedImageRecognizer.RecognizerError.invalidImage) {
            _ = try await recognizer.recognize(image: UIImage())
        }
    }

    @Test func agnesServiceBuildsBase64ImageDataURL() {
        let service = AgnesImageRecognitionService()
        let data = Data([0x01, 0x02, 0x03, 0x04])
        let payload = service.makeDataURL(from: data, mimeType: "image/jpeg")
        #expect(payload?.hasPrefix("data:image/jpeg;base64,") == true)
        #expect(payload?.contains("AQIDBA==") == true)
    }

    @Test func chatMessageStoreDeleteRemovesMessagesFromPersistentStore() async throws {
        let schema = Schema([ChatMessage.self, ConversationSnapshot.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let store = ChatMessageStore(modelContainer: container)

        let conversationId = UUID()
        let first = try await store.insertUser(
            UserMessageDraft(
                content: "先删我",
                timestamp: Date().addingTimeInterval(-10),
                conversationId: conversationId,
                isRead: true,
                status: .completed
            )
        )
        let second = try await store.insertAssistantSegment(
            AssistantSegmentDraft(
                content: "留着我",
                conversationId: conversationId
            )
        )

        _ = try await store.delete(ids: Set([first.id]))

        let remaining = try await store.fetchRecent(limit: 10)
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == second.id)
    }

    @Test func memoryManagerRemoveMessagesDropsUnsummarizedBuffer() async throws {
        let schema = Schema([
            ChatMessage.self,
            LongTermMemory.self,
            CharacterProfile.self,
            UserProfile.self,
            AppSettings.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let logger = MockLoggerService()
        let settingsService = MockSettingsService()
        let chatMessageStore = ChatMessageStore(modelContainer: container, logger: logger)
        let memoryManager = MemoryManager(
            modelContainer: container,
            chatMessageStore: chatMessageStore,
            logger: logger,
            llmServiceFactory: LLMServiceFactory(
                keychainService: MockKeychainService(),
                settingsService: settingsService
            ),
            settingsService: settingsService
        )

        let keep = ChatMessageSnapshot(
            id: UUID(),
            role: .user,
            content: "keep",
            conversationId: UUID(),
            isRead: true
        )
        let drop = ChatMessageSnapshot(
            id: UUID(),
            role: .assistant,
            content: "drop",
            conversationId: UUID(),
            isRead: true
        )

        await memoryManager.addMessage(keep, userName: "她", characterName: "他")
        await memoryManager.addMessage(drop, userName: "她", characterName: "他")
        await memoryManager.removeMessages(Set([drop.id]))

        let remaining = await memoryManager.unsummarizedMessageIDs()
        #expect(remaining.contains(keep.id))
        #expect(!remaining.contains(drop.id))
    }

    @Test func memoryManagerClearUserFacingMemoryEmptiesSummaries() async throws {
        let schema = Schema([
            ChatMessage.self,
            LongTermMemory.self,
            CharacterProfile.self,
            UserProfile.self,
            AppSettings.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let longTerm = LongTermMemory(
            globalSummary: "她喜欢猫",
            userProfile: ["likes": "猫"],
            totalMessagesProcessed: 12
        )
        context.insert(longTerm)
        try context.save()

        let logger = MockLoggerService()
        let settingsService = MockSettingsService()
        let chatMessageStore = ChatMessageStore(modelContainer: container, logger: logger)
        let memoryManager = MemoryManager(
            modelContainer: container,
            chatMessageStore: chatMessageStore,
            logger: logger,
            llmServiceFactory: LLMServiceFactory(
                keychainService: MockKeychainService(),
                settingsService: settingsService
            ),
            settingsService: settingsService
        )

        // Allow actor init Task to load singleton rows.
        try await Task.sleep(nanoseconds: 50_000_000)

        let before = await memoryManager.loadUserFacingMemory()
        #expect(before.hasLongTermSummary)
        #expect(before.hasExtractedUserProfile)

        await memoryManager.clearLongTermSummary()
        await memoryManager.clearExtractedUserProfile()
        let after = await memoryManager.loadUserFacingMemory()
        #expect(after.isCompletelyEmpty)
        #expect(after.longTermSummary.isEmpty)
        #expect(after.extractedUserProfile.isEmpty)
    }

    @Test func conversationSnapshotRecomputeAlignsWithRemainingChat() async throws {
        let schema = Schema([ChatMessage.self, ConversationSnapshot.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let store = ChatMessageStore(modelContainer: container)
        let conversationId = UUID()

        let olderUser = Date(timeIntervalSince1970: 1_700_000_000)
        let midAssistant = olderUser.addingTimeInterval(60)
        let newestUser = olderUser.addingTimeInterval(120)

        _ = try await store.insertUser(
            UserMessageDraft(
                content: "旧",
                timestamp: olderUser,
                conversationId: conversationId,
                isRead: true,
                status: .completed
            )
        )
        let assistant = try await store.insertAssistantSegment(
            AssistantSegmentDraft(
                content: "回",
                timestamp: midAssistant,
                conversationId: conversationId,
                isRead: true
            )
        )
        let userNew = try await store.insertUser(
            UserMessageDraft(
                content: "新",
                timestamp: newestUser,
                conversationId: conversationId,
                isRead: true,
                status: .completed
            )
        )

        _ = try await store.delete(ids: Set([userNew.id]))

        let snapshot = await store.loadConversationSnapshot()
        #expect(snapshot.lastUserMessageAt == olderUser)
        #expect(snapshot.lastAssistantMessageAt == assistant.timestamp)
        #expect(snapshot.currentConversationId == conversationId)
    }

    @Test func delayedResponseCancelForConversationOnly() async throws {
        let schema = Schema([
            PendingResponse.self,
            CharacterProfile.self,
            UserProfile.self,
            ChatMessage.self,
            ConversationSnapshot.self,
            PendingHealthLLMJob.self,
            HealthAlertRecord.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let logger = MockLoggerService()
        let chatMessageStore = ChatMessageStore(
            modelContainer: container,
            logger: logger
        )
        let profileService = ProfileService(
            modelContainer: container,
            logger: logger
        )
        let manager = DelayedResponseManager(
            profileService: profileService,
            notificationService: MockNotificationService(),
            chatMessageStore: chatMessageStore,
            logger: logger
        )

        let keepConversation = UUID()
        let dropConversation = UUID()
        let keepId = try await manager.schedule(
            content: "keep",
            conversationId: keepConversation,
            eventType: nil,
            characterName: "echo",
            delay: 60,
            armInProcessDelivery: false
        )
        let dropId = try await manager.schedule(
            content: "drop",
            conversationId: dropConversation,
            eventType: nil,
            characterName: "echo",
            delay: 60,
            armInProcessDelivery: false
        )

        try await manager.cancelPendingResponses(for: Set([dropConversation]))

        #expect(try await manager.hasPendingResponses(for: keepConversation))
        #expect(try await manager.hasPendingResponses(for: dropConversation) == false)
        #expect(keepId != dropId)

        // PR2d: DRM schedule/cancel must land in the store (single durable owner).
        #expect(await chatMessageStore.hasPendingDelayedResponses(for: keepConversation))
        #expect(await chatMessageStore.hasPendingDelayedResponses(for: dropConversation) == false)
        #expect(await chatMessageStore.pendingDelayedResponseCount() == 1)
        #expect(await chatMessageStore.loadPendingResponse(id: keepId)?.status == .pending)
        #expect(await chatMessageStore.loadPendingResponse(id: dropId)?.status == .cancelled)
    }

    @Test func chatCompletionsIsTheDefaultEndpointMode() {
        let endpoint = LLMAPIEndpointMode.chatCompletions.endpointURL(baseURL: "https://api.example.com/v1")
        #expect(endpoint == "https://api.example.com/v1/chat/completions")
    }

    @Test func responsesEndpointIsSupported() {
        let endpoint = LLMAPIEndpointMode.responses.endpointURL(baseURL: "https://api.example.com/v1")
        #expect(endpoint == "https://api.example.com/v1/responses")
    }

    @Test func loggerServiceDropsOldestEntriesWhenCapExceeded() async {
        let logger = LoggerService(maxEntries: 3)

        await logger.log("a", level: .debug)
        await logger.log("b", level: .info)
        await logger.log("c", level: .warning)
        await logger.log("d", level: .error)

        let logs = await logger.getLogs()
        #expect(logs.count == 3)
        #expect(logs.map(\.message) == ["b", "c", "d"])
        #expect(logs.map(\.level) == [.info, .warning, .error])
    }

    @Test func loggerServiceClearRemovesRetainedEntries() async throws {
        let logger = LoggerService(maxEntries: 5)
        await logger.log("keep-me", level: .info)
        try await logger.clearLogs()
        let logs = await logger.getLogs()
        #expect(logs.isEmpty)
    }
}
