import Foundation

/// Single owner surface for CharacterProfile + UserProfile durable R/W.
/// Cross-actor consumers must use snapshots / scalars — never live `@Model`s.
protocol ProfileProviding: Sendable {
    func loadCharacter() async -> CharacterProfileSnapshot
    func loadUser() async -> UserProfileSnapshot
    func updateCharacter(_ draft: CharacterProfileSnapshot) async throws
    func updateUser(_ draft: UserProfileSnapshot) async throws
    func characterName() async -> String
    func userBirthday() async -> Date?
}
