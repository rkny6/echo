import Foundation

/// Which proactive occasion is being evaluated. Mirrors the subset of
/// `CompanionEventType` that `ProactiveEngagementCoordinator` drives, kept
/// separate so this file doesn't need to know about the full event enum.
enum ProactiveJudgmentKind: Sendable {
    case onlineGreeting
    case eveningCheckIn

    var eventType: CompanionEventType {
        switch self {
        case .onlineGreeting: return .onlineGreeting
        case .eveningCheckIn: return .eveningCheckIn
        }
    }

    /// Short occasion description folded into the decision prompt.
    var occasionDescription: String {
        switch self {
        case .onlineGreeting:
            return "角色刚「上线」，评估要不要在此刻主动跟用户打招呼"
        case .eveningCheckIn:
            return "现在是晚间（21:00-23:00），评估要不要主动做一次轻量的晚间关心"
        }
    }
}

/// Outcome of a single proactive-intent judgment call.
struct ProactiveDecision: Sendable, Equatable {
    let shouldSend: Bool
    /// Ready-to-send message text. Present only when `shouldSend` is true.
    let message: String?
    /// Free-text rationale, logged for debugging — never shown to the user.
    let reason: String
}

/// Replaces the fixed-threshold "should I reach out right now" judgment
/// (magic numbers like `silenceThresholdHours = 3.0` or the 21–23 evening
/// window) with a single structured LLM call that weighs the same signals
/// a person would: how long the silence has felt, what's in the relationship
/// memory, what was last talked about, the character's own persona, and the
/// time of day.
///
/// This is deliberately narrow — it is not a general agent loop. It answers
/// exactly one question ("should the character reach out right now, and if
/// so with what message?") from a context snapshot it is handed. All hard
/// safety limits (don't interrupt an active chat, global cooldown, once-a-day
/// caps) stay in `NotificationGovernor` / `ProactiveEngagementCoordinator`
/// and are evaluated *before* and *after* this call — a bad or unparsable
/// model response can only ever result in *not* sending anything, never in
/// bypassing those limits.
actor ProactiveIntentDecider {
    private let llmServiceFactory: any LLMServiceFactoryProviding
    private let settingsService: SettingsProviding
    private let profileService: any ProfileProviding
    private let memoryManager: any MemoryManaging
    private let logger: LoggingProviding
    private let timeZoneAwarenessProvider: TimeZoneAwarenessProvider

    /// Hard ceiling so a slow/hanging API call can never stall the caller
    /// (cold start / foreground / BGTask) — same pattern as
    /// `HealthLLMGenerationService.withTimeout`.
    private static let timeoutSeconds: TimeInterval = 12
    private static let maxTokens = 400

    init(
        llmServiceFactory: any LLMServiceFactoryProviding,
        settingsService: SettingsProviding,
        profileService: any ProfileProviding,
        memoryManager: any MemoryManaging,
        logger: LoggingProviding,
        timeZoneAwarenessProvider: TimeZoneAwarenessProvider
    ) {
        self.llmServiceFactory = llmServiceFactory
        self.settingsService = settingsService
        self.profileService = profileService
        self.memoryManager = memoryManager
        self.logger = logger
        self.timeZoneAwarenessProvider = timeZoneAwarenessProvider
    }

    /// - Returns: `nil` on any failure (timeout, network error, unparsable
    ///   response). Callers must treat `nil` the same as "don't send" —
    ///   fail closed, no template fallback, matching how
    ///   `HealthLLMGenerationService` / `OnlineGreetingService` already
    ///   treat a failed generation.
    func decide(
        kind: ProactiveJudgmentKind,
        silence: ContactSilenceMetrics,
        characterName: String
    ) async -> ProactiveDecision? {
        do {
            let decision = try await withTimeout(seconds: Self.timeoutSeconds) { [self] in
                try await runDecision(kind: kind, silence: silence)
            }
            await logger.log(
                "ProactiveIntentDecider(\(kind.eventType.rawValue)): shouldSend=\(decision.shouldSend) reason=\(decision.reason)",
                level: .info
            )
            return decision
        } catch {
            await logger.log(
                "ProactiveIntentDecider(\(kind.eventType.rawValue)): failed — \(error.localizedDescription); treating as no-send",
                level: .warning
            )
            return nil
        }
    }

    // MARK: - Private

    private func runDecision(
        kind: ProactiveJudgmentKind,
        silence: ContactSilenceMetrics
    ) async throws -> ProactiveDecision {
        let character = await profileService.loadCharacter()
        let user = await profileService.loadUser()
        let memory = await memoryManager.getMemoryContext(
            userName: user.name,
            characterName: character.name,
            recentMessageLimit: 10
        )
        let localTimeString = timeZoneAwarenessProvider.getLocalTimeString()

        let systemPrompt = Self.buildSystemPrompt(character: character, user: user)
        let userPrompt = Self.buildDecisionPrompt(
            kind: kind,
            silence: silence,
            characterName: character.name,
            userName: user.name,
            longTermSummary: memory.globalSummary,
            recentMessages: memory.recentMessages,
            localTimeString: localTimeString
        )

        let settings = try await settingsService.getSettings()
        let provider = try await llmServiceFactory.createProvider(settings: settings)
        let raw = try await provider.sendMessageWithRetry(
            systemPrompt: systemPrompt,
            userMessage: userPrompt,
            temperature: 0.4,
            maxTokens: min(settings.maxTokens, Self.maxTokens),
            logger: logger
        )

        return try Self.parseDecision(from: raw)
    }

    private static func buildSystemPrompt(
        character: CharacterProfileSnapshot,
        user: UserProfileSnapshot
    ) -> String {
        """
        你是「是否要主动联系用户」的判断器，同时代入角色本人的视角来写候选消息。
        角色设定：\(character.name)，\(character.persona)。性格：\(character.personality)。说话风格：\(character.speakingStyle)。
        用户：\(user.name)。

        你只做一件事：结合沉默时长、两人关系记忆、最近聊了什么、现在的时间，判断角色此刻是否应该主动找用户说句话。
        不要为了"任务完成"而强行判定要发消息——大多数时候，安静地不打扰才是对的选择。
        只有当沉默的分量、关系的温度、当下的场合，让"主动说一句"显得自然、不突兀、不粘人时，才判定要发。

        只返回一个 JSON 对象，不要任何其他文字、不要 Markdown 代码块标记，格式严格为：
        {"should_send": true 或 false, "message": "要发送的消息，不需要发送时留空字符串", "reason": "一句话说明判断依据，仅供内部日志，不会给用户看"}
        """
    }

    private static func buildDecisionPrompt(
        kind: ProactiveJudgmentKind,
        silence: ContactSilenceMetrics,
        characterName: String,
        userName: String,
        longTermSummary: String,
        recentMessages: [ChatMessageSnapshot],
        localTimeString: String?
    ) -> String {
        var prompt = "场合：\(kind.occasionDescription)\n"
        prompt += "当前本地时间：\(localTimeString ?? "未知")\n"
        prompt += "距上次用户消息：wall-clock \(String(format: "%.1f", silence.wallClockHours)) 小时，"
        prompt += "清醒时段内 \(String(format: "%.1f", silence.awakeHours)) 小时，"
        prompt += "跨越 \(silence.calendarDaysApart) 个自然日边界，沉默基调=\(silence.careTone.rawValue)\n\n"

        if !longTermSummary.isEmpty {
            prompt += "关于 \(userName) 的已知事实摘要：\n\(longTermSummary)\n\n"
        }

        if recentMessages.isEmpty {
            prompt += "最近没有可参考的聊天记录（可能是全新关系，或记录已被清空）。\n\n"
        } else {
            prompt += "最近的对话（从旧到新）：\n"
            for message in recentMessages.suffix(10) {
                let speaker = message.role == .assistant ? characterName : userName
                prompt += "\(speaker)：\(message.content)\n"
            }
            prompt += "\n"
        }

        prompt += "请给出你的判断（严格 JSON，不要多余文字）。"
        return prompt
    }

    /// Tolerant JSON parsing: models sometimes wrap the object in ```json
    /// fences despite instructions — strip those before decoding, same
    /// defensive posture `JSONValue.init(jsonString:)`'s callers already need.
    private static func parseDecision(from raw: String) throws -> ProactiveDecision {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let value = try JSONValue(jsonString: cleaned)
        guard case .object(let object) = value else {
            throw ProactiveIntentDeciderError.malformedResponse(raw)
        }

        guard case .bool(let shouldSend)? = object["should_send"] else {
            throw ProactiveIntentDeciderError.malformedResponse(raw)
        }

        let message = object["message"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = object["reason"]?.stringValue ?? ""

        if shouldSend && (message == nil || message!.isEmpty) {
            // Model said "yes" but gave nothing to send — treat as a
            // malformed response rather than silently sending nothing while
            // claiming success in the log.
            throw ProactiveIntentDeciderError.malformedResponse(raw)
        }

        return ProactiveDecision(
            shouldSend: shouldSend,
            message: shouldSend ? message : nil,
            reason: reason
        )
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ProactiveIntentDeciderError.timeout
            }
            guard let result = try await group.next() else {
                throw ProactiveIntentDeciderError.timeout
            }
            group.cancelAll()
            return result
        }
    }
}

enum ProactiveIntentDeciderError: Error, LocalizedError, Equatable {
    case timeout
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "ProactiveIntentDecider timed out"
        case .malformedResponse(let raw):
            return "ProactiveIntentDecider got an unparsable response: \(raw.prefix(200))"
        }
    }
}
