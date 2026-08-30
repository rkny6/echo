import Foundation
import SwiftData

/// Sole durable owner for `CharacterProfile` and `UserProfile` singleton rows.
///
/// Uses a private `ModelContext` (Diary-style). UI and background services
/// read via snapshots / scalars and write only through `updateCharacter` /
/// `updateUser` field-copy onto the live singleton — never insert
/// `CharacterProfile.default` / `UserProfile.default` into SwiftData, and
/// never prune from ConversationManager or the UI context.
actor ProfileService: ProfileProviding {
    private let modelContainer: ModelContainer
    private let modelContext: ModelContext
    private let logger: LoggingProviding

    /// Live singleton rows owned by this actor's context.
    private var character: CharacterProfile
    private var user: UserProfile

    init(
        modelContainer: ModelContainer,
        logger: LoggingProviding
    ) {
        self.modelContainer = modelContainer
        self.modelContext = ModelContext(modelContainer)
        self.logger = logger

        // Ensure singleton rows exist and extras are pruned before any read.
        self.character = Self.ensureCharacter(in: modelContext, logger: logger)
        self.user = Self.ensureUser(in: modelContext, logger: logger)
    }

    // MARK: - ProfileProviding

    func loadCharacter() async -> CharacterProfileSnapshot {
        // Re-fetch + prune in case another process/context left extras
        // (legacy dual-writer residue). Prefer newest by updatedAt.
        character = Self.ensureCharacter(in: modelContext, logger: logger)
        return CharacterProfileSnapshot(from: character)
    }

    func loadUser() async -> UserProfileSnapshot {
        user = Self.ensureUser(in: modelContext, logger: logger)
        return UserProfileSnapshot(from: user)
    }

    func updateCharacter(_ draft: CharacterProfileSnapshot) async throws {
        character = Self.ensureCharacter(in: modelContext, logger: logger)
        character.name = draft.name
        character.avatarName = draft.avatarName
        character.personality = draft.personality
        character.background = draft.background
        character.speakingStyle = draft.speakingStyle
        character.persona = draft.persona
        character.tone = draft.tone
        character.boundaries = draft.boundaries
        character.relationship = draft.relationship
        character.customRelationshipDescription = draft.customRelationshipDescription
        character.attachmentStyle = draft.attachmentStyle
        // Preserve original createdAt; always bump updatedAt on durable write.
        character.updatedAt = Date()
        try modelContext.save()
        await logger.log("Character profile updated: \(character.name)", level: .debug)
    }

    func updateUser(_ draft: UserProfileSnapshot) async throws {
        user = Self.ensureUser(in: modelContext, logger: logger)
        user.name = draft.name
        user.avatarName = draft.avatarName
        user.personality = draft.personality
        user.background = draft.background
        user.birthday = draft.birthday
        user.updatedAt = Date()
        try modelContext.save()
        await logger.log("User profile updated: \(user.name)", level: .debug)
    }

    func characterName() async -> String {
        character = Self.ensureCharacter(in: modelContext, logger: logger)
        return character.name
    }

    func userBirthday() async -> Date? {
        user = Self.ensureUser(in: modelContext, logger: logger)
        return user.birthday
    }

    // MARK: - Singleton ensure / prune

    /// Keep newest CharacterProfile; insert a fresh instance if none exist.
    /// Never inserts `CharacterProfile.default` (shared static).
    private static func ensureCharacter(in context: ModelContext, logger: LoggingProviding) -> CharacterProfile {
        let request = FetchDescriptor<CharacterProfile>(
            sortBy: [SortDescriptor(\CharacterProfile.updatedAt, order: .reverse)]
        )
        let profiles = (try? context.fetch(request)) ?? []
        if let keep = profiles.first {
            pruneExtras(profiles, keeping: keep, in: context, logger: logger)
            return keep
        }
        let created = CharacterProfile()
        context.insert(created)
        do {
            try context.save()
        } catch {
            let message = "ProfileService: failed to save newly-created CharacterProfile: \(error.localizedDescription)"
            Task { await logger.log(message, level: .error) }
        }
        return created
    }

    /// Keep newest UserProfile; insert a fresh instance if none exist.
    /// Never inserts `UserProfile.default` (shared static).
    private static func ensureUser(in context: ModelContext, logger: LoggingProviding) -> UserProfile {
        let request = FetchDescriptor<UserProfile>(
            sortBy: [SortDescriptor(\UserProfile.updatedAt, order: .reverse)]
        )
        let profiles = (try? context.fetch(request)) ?? []
        if let keep = profiles.first {
            pruneExtras(profiles, keeping: keep, in: context, logger: logger)
            return keep
        }
        let created = UserProfile()
        context.insert(created)
        do {
            try context.save()
        } catch {
            let message = "ProfileService: failed to save newly-created UserProfile: \(error.localizedDescription)"
            Task { await logger.log(message, level: .error) }
        }
        return created
    }

    private static func pruneExtras<T: PersistentModel>(
        _ profiles: [T],
        keeping keep: T,
        in context: ModelContext,
        logger: LoggingProviding
    ) {
        guard profiles.count > 1 else { return }
        var didDelete = false
        for profile in profiles where profile !== keep {
            context.delete(profile)
            didDelete = true
        }
        if didDelete {
            do {
                try context.save()
            } catch {
                let message = "ProfileService: failed to save after pruning extra \(T.self) rows: \(error.localizedDescription)"
                Task { await logger.log(message, level: .error) }
            }
        }
    }
}
