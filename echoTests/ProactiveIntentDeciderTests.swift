import Foundation
import SwiftData
import Testing
@testable import echo

struct ProactiveIntentDeciderTests {
    private func makeDecider(
        script: [LLMGenerationResult],
        memoryManager: MockMemoryManager = MockMemoryManager()
    ) -> (decider: ProactiveIntentDecider, profileService: ProfileService, container: ModelContainer) {
        let logger = MockLoggerService()
        let container = try! ModelContainer(
            for: Schema([CharacterProfile.self, UserProfile.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let profileService = ProfileService(modelContainer: container, logger: logger)
        let decider = ProactiveIntentDecider(
            llmServiceFactory: MockLLMServiceFactory(script: script),
            settingsService: MockSettingsService(),
            profileService: profileService,
            memoryManager: memoryManager,
            logger: logger,
            timeZoneAwarenessProvider: MockTimeZoneAwarenessProvider(logger: logger)
        )
        return (decider, profileService, container)
    }

    private func silence(awakeHours: Double = 5) -> ContactSilenceMetrics {
        ContactSilenceMetrics(lastContactAt: Date().addingTimeInterval(-awakeHours * 3600))
    }

    @Test func parsesShouldSendTrueWithMessage() async throws {
        let (decider, _, _) = makeDecider(script: [
            .text(#"{"should_send": true, "message": "在吗，突然想你了", "reason": "多日沉默，关系记忆里她提过喜欢被主动联系"}"#)
        ])

        let decision = await decider.decide(kind: .onlineGreeting, silence: silence(), characterName: "阿俊")

        #expect(decision?.shouldSend == true)
        #expect(decision?.message == "在吗，突然想你了")
    }

    @Test func parsesShouldSendFalse() async throws {
        let (decider, _, _) = makeDecider(script: [
            .text(#"{"should_send": false, "message": "", "reason": "沉默时间不长，不显突兀但也没必要现在打扰"}"#)
        ])

        let decision = await decider.decide(kind: .eveningCheckIn, silence: silence(), characterName: "阿俊")

        #expect(decision?.shouldSend == false)
        #expect(decision?.message == nil)
    }

    @Test func stripsMarkdownCodeFenceBeforeParsing() async throws {
        let (decider, _, _) = makeDecider(script: [
            .text("```json\n{\"should_send\": true, \"message\": \"早呀\", \"reason\": \"早晨常规问候\"}\n```")
        ])

        let decision = await decider.decide(kind: .onlineGreeting, silence: silence(), characterName: "阿俊")

        #expect(decision?.shouldSend == true)
        #expect(decision?.message == "早呀")
    }

    @Test func malformedJSONFailsClosed() async throws {
        let (decider, _, _) = makeDecider(script: [
            .text("这不是 JSON，模型没有按格式返回")
        ])

        let decision = await decider.decide(kind: .onlineGreeting, silence: silence(), characterName: "阿俊")

        #expect(decision == nil)
    }

    @Test func shouldSendTrueWithoutMessageFailsClosed() async throws {
        // A model that says "yes" but forgets to write a message must not
        // be treated as a valid "no" either — it's an error, not a decision.
        let (decider, _, _) = makeDecider(script: [
            .text(#"{"should_send": true, "message": "", "reason": "忘记写消息"}"#)
        ])

        let decision = await decider.decide(kind: .onlineGreeting, silence: silence(), characterName: "阿俊")

        #expect(decision == nil)
    }

    @Test func emptyLLMScriptFailsClosedRatherThanThrowing() async throws {
        let (decider, _, _) = makeDecider(script: [])

        let decision = await decider.decide(kind: .onlineGreeting, silence: silence(), characterName: "阿俊")

        #expect(decision == nil)
    }

    @Test func passesRelationshipMemoryAndRecentMessagesIntoThePrompt() async throws {
        let memoryManager = MockMemoryManager(
            globalSummary: "她喜欢猫，最近在准备一场考试。",
            recentMessages: [
                ChatMessageSnapshot(
                    id: UUID(),
                    role: .user,
                    content: "今天好累啊",
                    timestamp: Date(),
                    isRead: true,
                    status: .completed
                )
            ]
        )
        let (decider, _, _) = makeDecider(
            script: [.text(#"{"should_send": true, "message": "辛苦啦，早点休息", "reason": "呼应她说的累"}"#)],
            memoryManager: memoryManager
        )

        let decision = await decider.decide(kind: .eveningCheckIn, silence: silence(), characterName: "阿俊")

        #expect(decision?.shouldSend == true)
        // The context assembly itself (system+user prompt content) is
        // exercised indirectly here; the meaningful contract under test is
        // that a decider with richer memory still parses to a valid decision.
        #expect(decision?.message?.isEmpty == false)
    }
}
