import Foundation

/// Sendable read model for the user profile.
/// Durable `UserProfile` rows are owned by `ProfileService` (private
/// ModelContext). UI and prompt consumers use snapshots so they never hold
/// live models across contexts.
struct UserProfileSnapshot: Sendable, Equatable {
    var name: String
    var avatarName: String
    var personality: String
    var background: String?
    var birthday: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        name: String = "用户",
        avatarName: String = "user_default",
        personality: String = "",
        background: String? = "女性用户",
        birthday: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.name = name
        self.avatarName = avatarName
        self.personality = personality
        self.background = background
        self.birthday = birthday
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from profile: UserProfile) {
        self.name = profile.name
        self.avatarName = profile.avatarName
        self.personality = profile.personality
        self.background = profile.background
        self.birthday = profile.birthday
        self.createdAt = profile.createdAt
        self.updatedAt = profile.updatedAt
    }

    static let `default` = UserProfileSnapshot()
}
