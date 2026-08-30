import Foundation
import SwiftData

actor MemoryManager: MemoryManaging {
    private let modelContainer: ModelContainer
    private let modelContext: ModelContext
    private let chatMessageStore: ChatMessageStore
    private let logger: LoggingProviding
    private let llmServiceFactory: any LLMServiceFactoryProviding
    private let settingsService: SettingsProviding
    
    private var longTermMemory: LongTermMemory?
    /// Detached buffer of chat rows waiting to fold into long-term facts.
    private var unsummarizedMessages: [ChatMessageSnapshot] = []
    private var isSummarizing = false
    
    private let maxContextTokens = 4096
    
    init(
        modelContainer: ModelContainer,
        chatMessageStore: ChatMessageStore,
        logger: LoggingProviding,
        llmServiceFactory: any LLMServiceFactoryProviding,
        settingsService: SettingsProviding
    ) {
        self.modelContainer = modelContainer
        self.modelContext = ModelContext(modelContainer)
        self.chatMessageStore = chatMessageStore
        self.logger = logger
        self.llmServiceFactory = llmServiceFactory
        self.settingsService = settingsService
        Task {
            await loadLongTermMemory()
        }
    }
    
    private func loadLongTermMemory() async {
        let request = FetchDescriptor<LongTermMemory>()
        do {
            let memories = try modelContext.fetch(request)
            if let existing = memories.first {
                longTermMemory = existing
            } else {
                let newMemory = LongTermMemory()
                modelContext.insert(newMemory)
                try modelContext.save()
                longTermMemory = newMemory
                await logger.log("Created new long-term memory", level: .debug)
            }
        } catch {
            await logger.log("Failed to load long-term memory: \(error)", level: .error)
        }
    }
    
    func loadUserFacingMemory() async -> UserFacingMemorySnapshot {
        // Ensure long-term singleton exists before the UI first opens this screen.
        if longTermMemory == nil {
            await loadLongTermMemory()
        }

        return UserFacingMemorySnapshot(
            longTermSummary: longTermMemory?.globalSummary ?? "",
            longTermLastUpdated: longTermMemory?.lastSummaryUpdate,
            extractedUserProfile: longTermMemory?.userProfile ?? [:],
            totalMessagesProcessed: longTermMemory?.totalMessagesProcessed ?? 0,
            unsummarizedMessageCount: unsummarizedMessages.count
        )
    }

    func clearLongTermSummary() async {
        if longTermMemory == nil {
            await loadLongTermMemory()
        }
        guard let memory = longTermMemory else { return }
        memory.globalSummary = ""
        memory.lastSummaryUpdate = Date()
        // Drop buffer so a mid-flight summary window cannot immediately rewrite
        // the same deleted text back into globalSummary.
        unsummarizedMessages.removeAll()
        do {
            try modelContext.save()
            await logger.log("User cleared long-term summary", level: .info)
        } catch {
            await logger.log("Failed to clear long-term summary: \(error)", level: .error)
        }
    }

    func clearExtractedUserProfile() async {
        if longTermMemory == nil {
            await loadLongTermMemory()
        }
        guard let memory = longTermMemory else { return }
        memory.userProfile = [:]
        do {
            try modelContext.save()
            await logger.log("User cleared extracted user profile memory", level: .info)
        } catch {
            await logger.log("Failed to clear extracted user profile: \(error)", level: .error)
        }
    }

    func addMessage(_ message: ChatMessageSnapshot, userName: String, characterName: String) async {
        unsummarizedMessages.append(message)
        longTermMemory?.totalMessagesProcessed += 1
        do {
            try modelContext.save()
        } catch {
            await logger.log("Failed to update message count: \(error)", level: .error)
        }
        
        await checkAndTriggerSummaryIfNeeded(userName: userName, characterName: characterName)
    }

    func removeMessages(_ messageIDs: Set<UUID>) async {
        guard !messageIDs.isEmpty else { return }
        let before = unsummarizedMessages.count
        unsummarizedMessages.removeAll { messageIDs.contains($0.id) }
        let removed = before - unsummarizedMessages.count
        if removed > 0 {
            await logger.log(
                "Removed \(removed) deleted message(s) from unsummarized memory buffer",
                level: .debug
            )
        }
    }

    /// Test / debug: IDs still waiting to be folded into a summary.
    func unsummarizedMessageIDs() async -> Set<UUID> {
        Set(unsummarizedMessages.map(\.id))
    }
    
    private func checkAndTriggerSummaryIfNeeded(userName: String, characterName: String) async {
        guard !isSummarizing, let memory = longTermMemory else { return }
        
        let summaryTokens = TokenEstimator.estimateTokens(for: memory.globalSummary)
        let unsummarizedTokens = TokenEstimator.estimateTokens(
            for: unsummarizedMessages,
            userName: userName,
            characterName: characterName
        )
        let totalTokens = summaryTokens + unsummarizedTokens
        let budget = Int(Double(maxContextTokens) * memory.tokenBudgetPercentage)
        
        if totalTokens >= budget {
            await triggerSummaryUpdate(userName: userName, characterName: characterName)
        }
    }
    
    private func triggerSummaryUpdate(userName: String, characterName: String) async {
        guard !isSummarizing, let memory = longTermMemory else { return }
        
        isSummarizing = true
        defer { isSummarizing = false }
        
        await logger.log("Starting summary update with \(unsummarizedMessages.count) unsummarized messages", level: .debug)
        
        let existingSummary = memory.globalSummary
        let messagesToSummarize = Array(unsummarizedMessages)
        
        do {
            let settings = try await settingsService.getSettings()
            let provider = try await llmServiceFactory.createProvider(settings: settings)

            let summaryPrompt = buildSummaryPrompt(
                existingSummary: existingSummary,
                messages: messagesToSummarize,
                userName: userName,
                characterName: characterName
            )

            // Concept reduction step 3: objective facts only (喜好/习惯/承诺等).
            // Relationship feel and plot go to diary / raw chat, not this summary.
            let systemPrompt = """
你是客观事实提取器。根据对话，只更新可核验的事实记忆（偏好、习惯、承诺、重要日期、稳定背景等）。
不要写关系亲密度、情绪氛围、故事情节或角色口吻。只返回事实摘要正文，不要标题或额外说明。
"""

            let newSummary = try await provider.sendMessageWithRetry(
                systemPrompt: systemPrompt,
                userMessage: summaryPrompt,
                temperature: 0.2,
                maxTokens: 500,
                logger: logger
            )
            
            memory.globalSummary = newSummary
            memory.lastSummaryUpdate = Date()
            unsummarizedMessages.removeAll()
            try modelContext.save()
            
            await logger.log("Successfully updated long-term summary", level: .debug)

            // Relationship summary LLM updates intentionally removed (step 2):
            // diary + long-term facts cover user-facing memory; avoid a third
            // overlapping relationship narrative in storage and prompts.

            if memory.totalMessagesProcessed % 100 == 0 {
                await extractUserProfile(from: newSummary, provider: provider)
            }
            
        } catch {
            await logger.log("Failed to update summary: \(error)", level: .error)
        }
    }
    
    private func buildSummaryPrompt(
        existingSummary: String,
        messages: [ChatMessageSnapshot],
        userName: String,
        characterName: String
    ) -> String {
        var prompt = """
你在维护「关于 \(userName)」的客观事实档案。对话双方是：\(userName)（女性用户）、\(characterName)（男性角色）。
本摘要只记可复用的事实，不记关系心情或叙事剧情（那些由日记等渠道承担）。

"""

        if !existingSummary.isEmpty {
            prompt += """
已有的事实摘要（请在此基础上合并、去重、修正过时项，不要整篇复述无关旧文）：
\(existingSummary)

"""
        }

        prompt += """
自上次更新以来的对话：

"""

        for message in messages {
            let speaker = message.role == .assistant ? characterName : userName
            prompt += "\(speaker)：\(message.content)\n"
        }

        prompt += """

请输出更新后的事实摘要。要求：
1. 第三人称；对 \(userName) 用「她」，对 \(characterName) 用「他」；主体优先写关于她的事实，角色侧只保留对她有用的稳定信息（如他答应过的具体承诺）
2. 只保留客观、可核验的内容，例如：
   - 偏好与厌恶（食物、兴趣、忌讳）
   - 习惯与作息、工作/生活背景中的稳定事实
   - 明确承诺与约定（含时间点时尽量保留）
   - 重要日期、地点、人名等硬信息
3. 明确不要写：关系亲密度/信任感、暧昧氛围、情绪高潮、故事情节点、对话复盘、角色口吻或文风模仿
4. 删除寒暄、一次性情绪发泄、无法核实的猜测；旧摘要里若混有上述非事实内容，改写时删掉
5. 合并去重，条目化或短段落均可；控制在 400 字以内；若本轮对话没有新事实，可几乎原样保留已有事实摘要并略作整理

更新后的事实摘要：
"""

        return prompt
    }
    
    private func extractUserProfile(from summary: String, provider: LLMProviderService) async {
        guard let memory = longTermMemory else { return }
        
        let extractPrompt = """
根据以下「关于她」的客观事实摘要，提取用户的关键事实，以简单的 JSON 返回，只包含摘要中有依据的字段：

\(summary)

请以 JSON 格式返回，可包含但不限于：
- name: 用户名
- gender: 性别（默认女，除非摘要中明确另有说明）
- likes: 喜欢的事物
- dislikes: 不喜欢的事物
- important_dates: 重要日期
- personality: 可观察的稳定性格特点（不要写关系氛围）
- goals: 明确说过的目标或愿望

不要编造摘要中没有的信息。只返回 JSON，不要其他内容。
"""
        
        do {
            let systemPrompt = "你是客观事实提取专家。只返回有依据的 JSON，不要编造，不要任何其他内容。"
            let response = try await provider.sendMessageWithRetry(
                systemPrompt: systemPrompt,
                userMessage: extractPrompt,
                temperature: 0.1,
                maxTokens: 300,
                logger: logger
            )
            
            if let jsonData = response.data(using: .utf8),
               let profileDict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: String] {
                for (key, value) in profileDict {
                    memory.userProfile[key] = value
                }
                try modelContext.save()
                await logger.log("Updated user profile from summary", level: .debug)
            }
        } catch {
            await logger.log("Failed to extract user profile: \(error)", level: .error)
        }
    }
    
    func getMemoryContext(
        userName: String,
        characterName: String,
        recentMessageLimit: Int? = nil
    ) async -> (globalSummary: String, userProfile: [String: String], recentMessages: [ChatMessageSnapshot]) {
        let limit = recentMessageLimit ?? longTermMemory?.slidingWindowSize ?? 20
        
        let recentMessages: [ChatMessageSnapshot]
        do {
            // Store returns oldest → newest already.
            recentMessages = try await chatMessageStore.fetchRecent(limit: limit)
        } catch {
            await logger.log("Failed to fetch recent messages: \(error)", level: .error)
            recentMessages = []
        }
        
        return (
            globalSummary: longTermMemory?.globalSummary ?? "",
            userProfile: longTermMemory?.userProfile ?? [:],
            recentMessages: recentMessages
        )
    }
}
