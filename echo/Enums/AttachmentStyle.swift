import Foundation

/// Attachment style of the companion character
enum AttachmentStyle: String, Codable, CaseIterable {
    case clingy
    case normal
    case independent
    
    var displayName: String {
        switch self {
        case .clingy:
            return "粘人/焦虑型"
        case .normal:
            return "普通型"
        case .independent:
            return "独立/高冷型"
        }
    }
}
