import Foundation

actor DailyContextManager {
    private let logger: LoggingProviding
    private let llmServiceFactory: any LLMServiceFactoryProviding
    private let settingsService: SettingsProviding
    
    private let defaults = UserDefaults.standard
    private let contextKey = "DailyContext"
    private let contextDateKey = "DailyContextDate"
    private let contextTimeZoneKey = "DailyContextTimeZone"
    
    init(
        logger: LoggingProviding,
        llmServiceFactory: any LLMServiceFactoryProviding,
        settingsService: SettingsProviding
    ) {
        self.logger = logger
        self.llmServiceFactory = llmServiceFactory
        self.settingsService = settingsService
    }
    
    private func getSavedDailyContext() -> String? {
        // Check if time zone has changed
        let savedTimeZone = defaults.string(forKey: contextTimeZoneKey)
        let currentTimeZone = TimeZone.current.identifier
        
        guard let savedDate = defaults.object(forKey: contextDateKey) as? Date,
              Calendar.current.isDateInToday(savedDate),
              savedTimeZone == currentTimeZone,
              let savedContext = defaults.string(forKey: contextKey) else {
            return nil
        }
        return savedContext
    }
    
    private func saveDailyContext(_ context: String) {
        defaults.set(context, forKey: contextKey)
        defaults.set(Date(), forKey: contextDateKey)
        defaults.set(TimeZone.current.identifier, forKey: contextTimeZoneKey)
    }
    
    func getOrCreateDailyContextString(
        for date: Date = Date(),
        character: CharacterProfileSnapshot,
        user: UserProfileSnapshot
    ) async throws -> String {
        if let existing = getSavedDailyContext() {
            return existing
        }
        
        let context = try await generateDailyContext(
            for: date,
            character: character,
            user: user
        )
        
        saveDailyContext(context)
        
        await logger.log("Generated and saved new daily context", level: .debug)
        
        return context
    }
    
    private func generateDailyContext(
        for date: Date,
        character: CharacterProfileSnapshot,
        user: UserProfileSnapshot
    ) async throws -> String {
        let calendar = Calendar.current
        let isWeekend = calendar.isDateInWeekend(date)
        let hour = calendar.component(.hour, from: date)
        
        let settings = try await settingsService.getSettings()
        let provider = try await llmServiceFactory.createProvider(settings: settings)
        
        let prompt = """
请根据以下信息生成一段简短、宽泛的中文描述，概括这个角色今天可能在做什么。描述要刻意保持模糊，避免过于具体的时间点，防止与角色性格产生冲突。角色默认为男性，描述时用「他」。

【角色信息】
名字：\(character.name)
性别：男
性格：\(character.personality)
背景：\(character.background)

【时间信息】
今天是\(isWeekend ? "周末" : "工作日")
当前时间大概是\(describeTimeOfDay(hour))

请用一段简短的中文描述，示例：
"今天工作日，他大概在公司忙项目，晚上可能会去健身房。"
"周末，他应该在家休息，下午可能和朋友出去。"

请直接输出描述，不要添加其他内容。
"""
        
        let response = try await provider.sendMessageWithRetry(
            systemPrompt: "你是一个擅长生成自然、模糊日常活动描述的助手。",
            userMessage: prompt,
            temperature: 0.8,
            maxTokens: 100,
        logger: logger
        )
        
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func describeTimeOfDay(_ hour: Int) -> String {
        switch hour {
        case 0..<6:
            return "深夜"
        case 6..<12:
            return "上午"
        case 12..<18:
            return "下午"
        case 18..<24:
            return "晚上"
        default:
            return "白天"
        }
    }
    
    func getCurrentDailyContextString() async -> String? {
        return getSavedDailyContext()
    }
}
