import Foundation
import SwiftData

/// One day's diary/朋友圈-style entry, written from the character's own POV.
/// Generated at most once per calendar day, after that day ends (local
/// midnight — only on days with at least one real conversation), and later
/// retrieved by keyword relevance — see DiaryService — to be woven into
/// future prompts as searchable memory, rather than just being another fixed
/// blob that's always included.
///
/// **Ownership:** durable reads/writes go only through `DiaryService`
/// (private ModelContext). UI uses `DiaryEntrySnapshot`; do not
/// `ModelContext.insert` / `delete` / fetch `DiaryEntry` from AppViewModel
/// or other actors.
@Model
final class DiaryEntry: @unchecked Sendable {
    @Attribute(.unique) var id: UUID
    /// Start-of-day date this entry is about (not the time it was generated).
    var date: Date
    var content: String
    /// Lightweight keyword set extracted from the entry, used for relevance
    /// scoring at retrieval time (see DiaryService.retrieveRelevantEntries).
    var keywords: [String]
    var createdAt: Date

    init(
        id: UUID = UUID(),
        date: Date,
        content: String,
        keywords: [String],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.date = date
        self.content = content
        self.keywords = keywords
        self.createdAt = createdAt
    }
}
