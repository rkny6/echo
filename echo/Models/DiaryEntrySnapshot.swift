import Foundation

/// Sendable read model for diary/朋友圈 entries.
/// Durable `DiaryEntry` rows are owned by `DiaryService` (private ModelContext);
/// UI and prompt retrieval use snapshots so callers never hold live models
/// across contexts or race BG generation with UI delete.
struct DiaryEntrySnapshot: Sendable, Identifiable, Equatable {
    let id: UUID
    /// Start-of-day date this entry is about (not generation time).
    let date: Date
    let content: String
    let keywords: [String]
    let createdAt: Date

    init(
        id: UUID,
        date: Date,
        content: String,
        keywords: [String],
        createdAt: Date
    ) {
        self.id = id
        self.date = date
        self.content = content
        self.keywords = keywords
        self.createdAt = createdAt
    }

    init(from entry: DiaryEntry) {
        self.id = entry.id
        self.date = entry.date
        self.content = entry.content
        self.keywords = entry.keywords
        self.createdAt = entry.createdAt
    }
}
