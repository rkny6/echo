import Foundation
import SwiftData
import NaturalLanguage

/// Generates a once-a-day diary/朋友圈-style entry written from the
/// character's own POV (only on days with at least one real conversation),
/// and retrieves past entries by keyword relevance to the current
/// conversation — this is the "actually searched" memory layer, distinct
/// from MemoryManager's always-included rolling summary (see that file's
/// MemoryManaging protocol doc comment).
///
/// **Single owner for `DiaryEntry`:** all durable insert / delete / list /
/// relevance reads go through this actor's private `ModelContext`. UI must
/// use snapshots (`loadAllEntries` / `deleteEntry`) and must not touch
/// `DiaryEntry` on the shared UI context (avoids BG gen vs UI delete races).
actor DiaryService {
    private let modelContainer: ModelContainer
    private let modelContext: ModelContext
    private let chatMessageStore: ChatMessageStore
    private let logger: LoggingProviding
    private let llmServiceFactory: LLMServiceFactory
    private let settingsService: SettingsProviding
    private let profileService: any ProfileProviding

    /// How many past entries to pull into a single prompt at retrieval time.
    private static let maxRetrievedEntries = 2
    /// Entries need at least this many overlapping keywords with the current
    /// conversation to be considered relevant enough to include — otherwise
    /// we'd always be stuffing in *something*, defeating the point of doing
    /// relevance matching at all.
    private static let minKeywordOverlapToInclude = 1

    init(
        modelContainer: ModelContainer,
        chatMessageStore: ChatMessageStore,
        logger: LoggingProviding,
        llmServiceFactory: LLMServiceFactory,
        settingsService: SettingsProviding,
        profileService: any ProfileProviding
    ) {
        self.modelContainer = modelContainer
        self.modelContext = ModelContext(modelContainer)
        self.chatMessageStore = chatMessageStore
        self.logger = logger
        self.llmServiceFactory = llmServiceFactory
        self.settingsService = settingsService
        self.profileService = profileService
    }

    // MARK: - Generation

    /// Call periodically (background refresh, foreground reconciliation).
    /// By default writes a diary for **yesterday** once that calendar day is
    /// fully over (i.e. after local midnight) — so the entry summarizes a
    /// complete day rather than an in-progress one. No-ops when yesterday
    /// already has an entry or had no conversation.
    /// - Parameter bypassTimeGate: when true, generates for **today** instead
    ///   (manual/debug only — useful without waiting until the next day).
    func generateDiaryIfNeeded(bypassTimeGate: Bool = false) async {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)

        // Normal path: after midnight, backfill yesterday's completed day.
        // Debug path: force a diary for the still-in-progress today.
        let targetDay: Date
        if bypassTimeGate {
            targetDay = today
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: today) {
            targetDay = yesterday
        } else {
            return
        }

        guard !(await hasEntry(for: targetDay)) else { return }
        _ = await generateDiaryEntry(for: targetDay)
    }

    /// Manually rewrite the diary for a specific calendar day from that day's
    /// chat. Existing entries for the day are replaced only after a successful
    /// generation — failures leave the previous entry intact.
    @discardableResult
    func regenerateDiary(for day: Date) async -> Bool {
        let targetDay = Calendar.current.startOfDay(for: day)
        return await generateDiaryEntry(for: targetDay, replaceExisting: true)
    }

    // MARK: - UI / ownership surface

    /// All diary entries, newest first (UI list). Snapshots only.
    func loadAllEntries() async -> [DiaryEntrySnapshot] {
        let request = FetchDescriptor<DiaryEntry>(
            sortBy: [SortDescriptor(\DiaryEntry.date, order: .reverse)]
        )
        guard let entries = try? modelContext.fetch(request) else { return [] }
        return entries.map(DiaryEntrySnapshot.init(from:))
    }

    /// Permanently delete one entry by id. No-op if missing.
    func deleteEntry(id: UUID) async {
        let predicate = #Predicate<DiaryEntry> { $0.id == id }
        guard let entry = try? modelContext.fetch(FetchDescriptor(predicate: predicate)).first else {
            return
        }
        modelContext.delete(entry)
        do {
            try modelContext.save()
            await logger.log("Diary entry deleted id=\(id.uuidString)", level: .info)
        } catch {
            await logger.log(
                "Failed to delete diary entry: \(error.localizedDescription)",
                level: .error
            )
        }
    }

    /// Shared write path used by automatic generation and manual regenerate.
    /// - Parameter replaceExisting: when true, delete any same-day entries
    ///   only after the new content is ready (manual regenerate).
    @discardableResult
    private func generateDiaryEntry(for targetDay: Date, replaceExisting: Bool = false) async -> Bool {
        let calendar = Calendar.current
        let dayMessages = await fetchMessages(on: targetDay, calendar: calendar)
        guard !dayMessages.isEmpty else {
            await logger.log("No conversation on \(targetDay), skipping diary entry", level: .debug)
            return false
        }

        let dayReference = Self.dayReference(for: targetDay, calendar: calendar)

        do {
            let character = await profileService.loadCharacter()
            let user = await profileService.loadUser()
            let settings = try await settingsService.getSettings()
            let provider = try await llmServiceFactory.createProvider(settings: settings)

            let prompt = buildDiaryPrompt(
                messages: dayMessages,
                character: character,
                user: user,
                dayReference: dayReference
            )
            let systemPrompt = """
            你是\(character.name)，一位有自己生活和感受的男性，不是助手。现在要写一篇只属于自己的日记/朋友圈动态，记录\(dayReference)和\(user.name)（女性）的互动带给你的感受。
            这是角色的私人回顾，不是在直接对\(user.name)说话。提到她时使用第三人称「她」或她的名字，不要使用第二人称「你」。
            只返回日记内容本身，不要添加任何说明或标签。
            """

            let content = try await provider.sendMessageWithRetry(
                systemPrompt: systemPrompt,
                userMessage: prompt,
                temperature: 0.8,
                maxTokens: 300,
                logger: logger
            )
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                await logger.log("Diary generation returned empty content, skipping", level: .warning)
                return false
            }

            if replaceExisting {
                await deleteEntries(for: targetDay, save: false)
            }

            let entry = DiaryEntry(
                date: targetDay,
                content: trimmed,
                keywords: Array(Self.extractKeywords(from: trimmed + " " + dayMessages.map(\.content).joined(separator: " ")))
            )
            modelContext.insert(entry)
            try modelContext.save()
            await logger.log("Diary entry generated for \(targetDay)", level: .info)
            return true
        } catch {
            await logger.log("Failed to generate diary entry: \(error.localizedDescription)", level: .error)
            return false
        }
    }

    private func hasEntry(for day: Date) async -> Bool {
        let request = FetchDescriptor<DiaryEntry>()
        guard let entries = try? modelContext.fetch(request) else { return false }
        return entries.contains { Calendar.current.isDate($0.date, inSameDayAs: day) }
    }

    private func deleteEntries(for day: Date, save: Bool = true) async {
        let request = FetchDescriptor<DiaryEntry>()
        guard let entries = try? modelContext.fetch(request) else { return }
        let matching = entries.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }
        guard !matching.isEmpty else { return }
        for entry in matching {
            modelContext.delete(entry)
        }
        if save {
            do {
                try modelContext.save()
            } catch {
                await logger.log(
                    "DiaryService: failed to save after deleting entries for \(day): \(error.localizedDescription)",
                    level: .error
                )
            }
        }
    }

    private func fetchMessages(on day: Date, calendar: Calendar) async -> [ChatMessageSnapshot] {
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) else { return [] }
        do {
            return try await chatMessageStore.fetchInRange(from: day, to: dayEnd)
        } catch {
            await logger.log(
                "Failed to fetch diary-day messages: \(error.localizedDescription)",
                level: .error
            )
            return []
        }
    }

    private func buildDiaryPrompt(
        messages: [ChatMessageSnapshot],
        character: CharacterProfileSnapshot,
        user: UserProfileSnapshot,
        dayReference: String
    ) -> String {
        var prompt = "\(dayReference)和\(user.name)之间发生的对话：\n\n"
        for message in messages {
            let speaker = message.role == .assistant ? character.name : user.name
            prompt += "\(speaker)：\(message.content)\n"
        }
        prompt += """

        请以\(character.name)（男性）的第一人称视角，写一篇简短的日记或朋友圈动态，记录\(dayReference)的心情和感受。这里不是与用户直接对话，而是角色在回顾当天发生的事情。
        要求：
        1. 第一人称"我"的口吻，像真实的男性写日记/发动态一样
        2. 提到当前用户\(user.name)时，使用第三人称女性指代「她」或直接使用\(user.name)，不要使用「你」
        3. 上述「她」只指当前用户；如需要描述第三方女性，必须确保指代明确，避免产生歧义
        4. 只写感受、印象深刻的片段，不要逐条复述对话内容
        5. 保持\(character.name)的性格和说话风格
        6. 3-5句话，简短自然，不要写成流水账
        7. 不要使用表情符号、话题标签或"日记"这类标题字样

        直接输出内容：
        """
        return prompt
    }

    /// Natural Chinese day reference for prompts: 今天 / 昨天 / M月d日.
    private static func dayReference(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) {
            return "今天"
        }
        if calendar.isDateInYesterday(day) {
            return "昨天"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: day)
    }

    // MARK: - Retrieval

    /// Finds past diary entries relevant to `queryText` (typically the
    /// current user message / recent conversation window), scored by
    /// keyword overlap. Returns empty when nothing clears the relevance bar —
    /// callers should skip including anything rather than grabbing the most
    /// recent entry regardless of relevance.
    func retrieveRelevantEntries(for queryText: String) async -> [DiaryEntrySnapshot] {
        guard !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let queryKeywords = Self.extractKeywords(from: queryText)
        guard !queryKeywords.isEmpty else { return [] }

        let request = FetchDescriptor<DiaryEntry>(
            sortBy: [SortDescriptor(\DiaryEntry.date, order: .reverse)]
        )
        guard let entries = try? modelContext.fetch(request), !entries.isEmpty else { return [] }

        let scored = entries.compactMap { entry -> (entry: DiaryEntrySnapshot, score: Int)? in
            let overlap = queryKeywords.intersection(entry.keywords).count
            guard overlap >= Self.minKeywordOverlapToInclude else { return nil }
            return (DiaryEntrySnapshot(from: entry), overlap)
        }

        return scored
            // Higher overlap first; among ties, prefer the more recent entry
            // (entries array is already newest-first, and sort is stable).
            .sorted { $0.score > $1.score }
            .prefix(Self.maxRetrievedEntries)
            .map(\.entry)
    }

    /// Formats retrieved entries into a ready-to-insert prompt section, or
    /// nil if nothing relevant was found.
    func diaryMemorySnippet(for queryText: String, characterName: String) async -> String? {
        let entries = await retrieveRelevantEntries(for: queryText)
        guard !entries.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"

        let entryLines = entries.map { entry in
            "\(formatter.string(from: entry.date))：\(entry.content)"
        }.joined(separator: "\n")

        return """
        【日记记忆】
        以下是\(characterName)自己之前写过的日记/动态片段，和当前话题可能相关：
        \(entryLines)

        如果这些内容和当前对话自然相关，可以像回忆起自己写过的东西一样自然地提起；如果不相关就不要提，不要生硬地逐字复述。
        """
    }

    // MARK: - Keyword extraction

    /// Extracts a lightweight keyword set from Chinese/mixed text using
    /// NaturalLanguage's word tokenizer (works reasonably well for Chinese
    /// segmentation without needing any external NLP service). This is a
    /// deliberately simple, fully-local, zero-network approach — no
    /// embeddings/vector search dependency, since that would require the
    /// configured LLM endpoint to also support an embeddings API, which
    /// isn't guaranteed for arbitrary custom OpenAI-compatible endpoints.
    private static func extractKeywords(from text: String) -> Set<String> {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var keywords: Set<String> = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let token = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip single characters and punctuation-only tokens — they're
            // rarely meaningful as standalone keywords and mostly add noise.
            if token.count >= 2, token.rangeOfCharacter(from: .punctuationCharacters) == nil {
                keywords.insert(token.lowercased())
            }
            return true
        }
        return keywords
    }

}
