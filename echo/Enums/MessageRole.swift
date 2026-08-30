import Foundation

/// Role of message sender
enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}
