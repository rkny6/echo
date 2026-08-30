import Foundation

/// Relationship type between user and companion
enum RelationshipType: String, Codable, CaseIterable {
    case companion
    case closeFriend
    case bestFriend
    case supportivePartner
    case caringSibling
    case mentor
    case guardian
    case custom
    
    var displayName: String {
        switch self {
        case .companion:
            return "伙伴"
        case .closeFriend:
            return "亲密朋友"
        case .bestFriend:
            return "最好的朋友"
        case .supportivePartner:
            return "贴心伴侣"
        case .caringSibling:
            return "贴心的兄妹"
        case .mentor:
            return "导师"
        case .guardian:
            return "守护者"
        case .custom:
            return "自定义"
        }
    }
}
