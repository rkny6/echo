import Foundation
import SwiftData

/// Companion character profile (singleton - only one active character)
@Model
final class CharacterProfile: @unchecked Sendable {
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
    private var _attachmentStyleRawValue: String?
    var attachmentStyle: AttachmentStyle {
        get {
            if let raw = _attachmentStyleRawValue, let style = AttachmentStyle(rawValue: raw) {
                return style
            }
            return .normal
        }
        set {
            _attachmentStyleRawValue = newValue.rawValue
        }
    }
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
        self._attachmentStyleRawValue = attachmentStyle.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
    
    static let `default` = CharacterProfile()
}

extension CharacterProfile: Equatable {
    static func == (lhs: CharacterProfile, rhs: CharacterProfile) -> Bool {
        return lhs.name == rhs.name
            && lhs.avatarName == rhs.avatarName
            && lhs.personality == rhs.personality
            && lhs.background == rhs.background
            && lhs.speakingStyle == rhs.speakingStyle
            && lhs.persona == rhs.persona
            && lhs.tone == rhs.tone
            && lhs.boundaries == rhs.boundaries
            && lhs.relationship == rhs.relationship
            && lhs.customRelationshipDescription == rhs.customRelationshipDescription
            && lhs.createdAt == rhs.createdAt
            && lhs.updatedAt == rhs.updatedAt
    }
}
