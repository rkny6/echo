import Foundation
import SwiftData
import Testing
@testable import echo

struct DiaryServiceTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            DiaryEntry.self,
            ChatMessage.self,
            ConversationSnapshot.self,
            PendingResponse.self,
            PendingHealthLLMJob.self,
            HealthAlertRecord.self,
            CharacterProfile.self,
            UserProfile.self,
            AppSettings.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func makeService(container: ModelContainer) -> DiaryService {
        let logger = MockLoggerService()
        let chatMessageStore = ChatMessageStore(modelContainer: container, logger: logger)
        let profileService = ProfileService(modelContainer: container, logger: logger)
        return DiaryService(
            modelContainer: container,
            chatMessageStore: chatMessageStore,
            logger: logger,
            llmServiceFactory: LLMServiceFactory(
                keychainService: MockKeychainService(),
                settingsService: MockSettingsService()
            ),
            settingsService: MockSettingsService(),
            profileService: profileService
        )
    }

    @Test func diaryServiceOwnsListAndDeleteWithoutUIContextWrites() async throws {
        let container = try makeContainer()
        let service = makeService(container: container)

        // Seed via a sibling context (legacy dual-writer simulation), then
        // prove service is the only path UI should use for list/delete.
        let seed = ModelContext(container)
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let keepID = UUID()
        let dropID = UUID()
        seed.insert(
            DiaryEntry(
                id: keepID,
                date: day,
                content: "今天和她聊了很久",
                keywords: ["聊天", "很久"]
            )
        )
        seed.insert(
            DiaryEntry(
                id: dropID,
                date: day.addingTimeInterval(-86_400),
                content: "昨天有点想她",
                keywords: ["想她"]
            )
        )
        try seed.save()

        let listed = await service.loadAllEntries()
        #expect(listed.count == 2)
        #expect(listed.map(\.id).contains(keepID))
        #expect(listed.map(\.id).contains(dropID))
        // Newest first by date.
        #expect(listed.first?.id == keepID)

        await service.deleteEntry(id: dropID)
        let afterDelete = await service.loadAllEntries()
        #expect(afterDelete.count == 1)
        #expect(afterDelete.first?.id == keepID)
        #expect(afterDelete.first?.content == "今天和她聊了很久")

        // Durable store has a single row; UI context must not be required.
        let verify = ModelContext(container)
        let rows = try verify.fetch(FetchDescriptor<DiaryEntry>())
        #expect(rows.count == 1)
        #expect(rows.first?.id == keepID)

        // Idempotent delete of missing id.
        await service.deleteEntry(id: dropID)
        #expect((await service.loadAllEntries()).count == 1)
    }

    @Test func retrieveRelevantEntriesReturnsSnapshotsByKeywordOverlap() async throws {
        let container = try makeContainer()
        let service = makeService(container: container)

        let seed = ModelContext(container)
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_100_000))
        seed.insert(
            DiaryEntry(
                date: day,
                content: "和她一起去看了电影",
                keywords: ["电影", "一起"]
            )
        )
        seed.insert(
            DiaryEntry(
                date: day.addingTimeInterval(-86_400),
                content: "今天只是随便走走",
                keywords: ["走走"]
            )
        )
        try seed.save()

        let hits = await service.retrieveRelevantEntries(for: "晚上想再看一部电影")
        #expect(hits.count == 1)
        #expect(hits.first?.content.contains("电影") == true)

        let miss = await service.retrieveRelevantEntries(for: "完全无关的话题xyz")
        #expect(miss.isEmpty)
    }
}
