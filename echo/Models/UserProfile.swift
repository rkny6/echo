import Foundation
import SwiftData

/// User profile information
@Model
final class UserProfile: @unchecked Sendable {
    var name: String
    private var _avatarName: String?
    var avatarName: String {
        get { _avatarName ?? "user_default" }
        set { _avatarName = newValue }
    }
    var personality: String
    var background: String?
    var birthday: Date?  // 用户生日
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
        self._avatarName = avatarName
        self.personality = personality
        self.background = background
        self.birthday = birthday
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
    
    static let `default` = UserProfile()
}

extension UserProfile: Equatable {
    static func == (lhs: UserProfile, rhs: UserProfile) -> Bool {
        return lhs.name == rhs.name
            && lhs.avatarName == rhs.avatarName
            && lhs.personality == rhs.personality
            && lhs.background == rhs.background
            && lhs.birthday == rhs.birthday
            && lhs.createdAt == rhs.createdAt
            && lhs.updatedAt == rhs.updatedAt
    }
}
