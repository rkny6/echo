import Foundation
import SwiftData
import Testing
@testable import echo

struct ProfileServiceTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            CharacterProfile.self,
            UserProfile.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test func loadCreatesSingletonRowsAndReturnsSnapshots() async throws {
        let container = try makeContainer()
        let service = ProfileService(modelContainer: container, logger: MockLoggerService())

        let character = await service.loadCharacter()
        let user = await service.loadUser()

        #expect(!character.name.isEmpty)
        #expect(!user.name.isEmpty)
        #expect(await service.characterName() == character.name)
        #expect(await service.userBirthday() == user.birthday)

        let verify = ModelContext(container)
        #expect(try verify.fetch(FetchDescriptor<CharacterProfile>()).count == 1)
        #expect(try verify.fetch(FetchDescriptor<UserProfile>()).count == 1)
    }

    @Test func initPrunesExtraProfileRowsKeepingNewest() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)

        let olderCharacter = CharacterProfile(name: "old-char")
        olderCharacter.updatedAt = Date(timeIntervalSince1970: 1_000)
        let newerCharacter = CharacterProfile(name: "new-char")
        newerCharacter.updatedAt = Date(timeIntervalSince1970: 2_000)
        seed.insert(olderCharacter)
        seed.insert(newerCharacter)

        let olderUser = UserProfile(name: "old-user")
        olderUser.updatedAt = Date(timeIntervalSince1970: 1_000)
        let newerUser = UserProfile(name: "new-user")
        newerUser.updatedAt = Date(timeIntervalSince1970: 2_000)
        seed.insert(olderUser)
        seed.insert(newerUser)
        try seed.save()

        let service = ProfileService(modelContainer: container, logger: MockLoggerService())
        let character = await service.loadCharacter()
        let user = await service.loadUser()

        #expect(character.name == "new-char")
        #expect(user.name == "new-user")

        let verify = ModelContext(container)
        #expect(try verify.fetch(FetchDescriptor<CharacterProfile>()).count == 1)
        #expect(try verify.fetch(FetchDescriptor<UserProfile>()).count == 1)
        #expect(try verify.fetch(FetchDescriptor<CharacterProfile>()).first?.name == "new-char")
        #expect(try verify.fetch(FetchDescriptor<UserProfile>()).first?.name == "new-user")
    }

    @Test func updateCopiesFieldsOntoLiveSingletonWithoutInsertingDraft() async throws {
        let container = try makeContainer()
        let service = ProfileService(modelContainer: container, logger: MockLoggerService())

        let beforeCharacter = await service.loadCharacter()
        let beforeUser = await service.loadUser()

        var characterDraft = beforeCharacter
        characterDraft.name = "阿夜"
        characterDraft.personality = "冷静克制"
        characterDraft.speakingStyle = "短句"
        characterDraft.persona = "夜行者"
        characterDraft.tone = "低沉"
        characterDraft.boundaries = "尊重边界"
        characterDraft.relationship = .custom
        characterDraft.customRelationshipDescription = "青梅竹马"
        characterDraft.attachmentStyle = .clingy

        var userDraft = beforeUser
        userDraft.name = "小满"
        userDraft.personality = "外向"
        userDraft.background = "喜欢散步"
        userDraft.birthday = Date(timeIntervalSince1970: 946_684_800)

        try await service.updateCharacter(characterDraft)
        try await service.updateUser(userDraft)

        let character = await service.loadCharacter()
        let user = await service.loadUser()

        #expect(character.name == "阿夜")
        #expect(character.personality == "冷静克制")
        #expect(character.speakingStyle == "短句")
        #expect(character.persona == "夜行者")
        #expect(character.tone == "低沉")
        #expect(character.boundaries == "尊重边界")
        #expect(character.relationship == .custom)
        #expect(character.customRelationshipDescription == "青梅竹马")
        #expect(character.attachmentStyle == .clingy)
        #expect(character.createdAt == beforeCharacter.createdAt)
        #expect(character.updatedAt >= beforeCharacter.updatedAt)

        #expect(user.name == "小满")
        #expect(user.personality == "外向")
        #expect(user.background == "喜欢散步")
        #expect(user.birthday == Date(timeIntervalSince1970: 946_684_800))
        #expect(user.createdAt == beforeUser.createdAt)
        #expect(user.updatedAt >= beforeUser.updatedAt)

        let verify = ModelContext(container)
        #expect(try verify.fetch(FetchDescriptor<CharacterProfile>()).count == 1)
        #expect(try verify.fetch(FetchDescriptor<UserProfile>()).count == 1)
        #expect(try verify.fetch(FetchDescriptor<CharacterProfile>()).first?.name == "阿夜")
        #expect(try verify.fetch(FetchDescriptor<UserProfile>()).first?.name == "小满")
    }
}
