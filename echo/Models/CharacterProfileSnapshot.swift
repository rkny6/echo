import Foundation

/// Sendable read model for the companion character profile.
/// Durable `CharacterProfile` rows are owned by `ProfileService` (private
/// ModelContext). UI and prompt consumers use snapshots so they never hold
/// live models across contexts or race CM prune with UI save.
struct CharacterProfileSnapshot: Sendable, Equatable {
    var name: String
    var avatarName: String
    var personality: String
    var background: String
    var speakingStyle: String
    var persona: String
    var tone: String
    var boundaries: String
    var relationship: RelationshipType?
    var customRelationshipDescription: String?
    var attachmentStyle: AttachmentStyle
    var createdAt: Date
    var updatedAt: Date

    init(
        name: String = "默认角色",
        avatarName: String = "character_default",
        personality: String = "温暖、有趣、细心，会照顾身边的人",
        background: String = "一位男性虚拟伴侣，会认真倾听并主动关心对方",
        speakingStyle: String = "自然亲切，偏男性口吻",
        persona: String = "温暖、有趣、细心的男性伴侣",
        tone: String = "自然亲切",
        boundaries: String = "体贴而尊重边界的男性虚拟伙伴",
        relationship: RelationshipType? = .companion,
        customRelationshipDescription: String? = nil,
        attachmentStyle: AttachmentStyle = .normal,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.name = name
        self.avatarName = avatarName
        self.personality = personality
        self.background = background
        self.speakingStyle = speakingStyle
        self.persona = persona
        self.tone = tone
        self.boundaries = boundaries
        self.relationship = relationship
        self.customRelationshipDescription = customRelationshipDescription
        self.attachmentStyle = attachmentStyle
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from profile: CharacterProfile) {
        self.name = profile.name
        self.avatarName = profile.avatarName
        self.personality = profile.personality
        self.background = profile.background
        self.speakingStyle = profile.speakingStyle
        self.persona = profile.persona
        self.tone = profile.tone
        self.boundaries = profile.boundaries
        self.relationship = profile.relationship
        self.customRelationshipDescription = profile.customRelationshipDescription
        self.attachmentStyle = profile.attachmentStyle
        self.createdAt = profile.createdAt
        self.updatedAt = profile.updatedAt
    }

    static let `default` = CharacterProfileSnapshot()
}
