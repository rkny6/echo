import Foundation

/// API endpoint mode for the unified LLM adapter.
enum LLMAPIEndpointMode: String, Codable, CaseIterable, Sendable {
    case chatCompletions = "chat_completions"
    case responses = "responses"

    var displayName: String {
        switch self {
        case .chatCompletions:
            return "Chat Completions"
        case .responses:
            return "Responses"
        }
    }

    var path: String {
        switch self {
        case .chatCompletions:
            return "/chat/completions"
        case .responses:
            return "/responses"
        }
    }

    func endpointURL(baseURL: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutSlash = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        return "\(withoutSlash)\(path)"
    }
}
