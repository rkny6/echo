import SwiftData

/// SwiftData model configuration for previews
extension ModelConfiguration {
    static let preview: ModelConfiguration = {
        return ModelConfiguration(isStoredInMemoryOnly: true)
    }()
}

extension ModelContainer {
    static let preview: ModelContainer = {
        return try! ModelContainer(
            for: ChatMessage.self,
                 CompanionEvent.self,
                 RelationshipMemory.self,
                 CharacterProfile.self,
                 UserProfile.self,
                 AppSettings.self,
                 PendingResponse.self,
                 PendingEvent.self,
                 LongTermMemory.self,
                 DailyContext.self,
                 CharacterStatus.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }()
}

extension ModelContext {
    static let preview: ModelContext = {
        return ModelContext(ModelContainer.preview)
    }()
}

enum PreviewFactory {
    static func conversationManager(
        modelContainer: ModelContainer,
        diaryService: DiaryService? = nil,
        profileService: (any ProfileProviding)? = nil
    ) -> ConversationManager {
        let logger = MockLoggerService()
        let settingsService = MockSettingsService()
        let pendingEventQueue = PendingEventQueue(modelContainer: modelContainer, logger: logger)
        let chatMessageStore = ChatMessageStore(
            modelContainer: modelContainer,
            logger: logger
        )
        let resolvedProfileService = profileService ?? ProfileService(
            modelContainer: modelContainer,
            logger: logger
        )
        let delayedResponseManager = DelayedResponseManager(
            profileService: resolvedProfileService,
            notificationService: MockNotificationService(),
            chatMessageStore: chatMessageStore,
            logger: logger
        )
        let typingMonitor = TypingMonitor(logger: logger)
        let llmServiceFactory = LLMServiceFactory(
            keychainService: MockKeychainService(),
            settingsService: settingsService
        )
        let memoryManager = MemoryManager(
            modelContainer: modelContainer,
            chatMessageStore: chatMessageStore,
            logger: logger,
            llmServiceFactory: llmServiceFactory,
            settingsService: settingsService
        )
        
        // Create mock daily context and status managers using dummy dependencies (since they won't be used in preview)
        let dailyContextManager = DailyContextManager(
            logger: logger,
            llmServiceFactory: llmServiceFactory,
            settingsService: settingsService
        )
        
        let characterStatusManager = CharacterStatusManager(
            logger: logger
        )
        
        let timeZoneAwarenessProvider = MockTimeZoneAwarenessProvider(logger: logger)
        let resolvedDiaryService = diaryService ?? DiaryService(
            modelContainer: modelContainer,
            chatMessageStore: chatMessageStore,
            logger: logger,
            llmServiceFactory: llmServiceFactory,
            settingsService: settingsService,
            profileService: resolvedProfileService
        )

        let promptContextAssembler = PromptContextAssembler(
            dailyContextManager: dailyContextManager,
            characterStatusManager: characterStatusManager,
            memoryManager: memoryManager,
            timeZoneAwarenessProvider: timeZoneAwarenessProvider,
            dateAmbienceProvider: DateAmbienceProvider(logger: logger),
            weatherAmbienceProvider: WeatherAmbienceProvider(logger: logger),
            sleepAmbienceProvider: SleepAmbienceProvider(
                healthDataService: MockHealthDataService(),
                logger: logger
            ),
            locationProvider: MockLocationService(),
            chatMessageStore: chatMessageStore
        )

        let imageMessageProcessor = ImageMessageProcessor(
            settingsService: settingsService,
            logger: logger
        )

        return ConversationManager(
            llmServiceFactory: llmServiceFactory,
            promptBuilder: MockPromptBuilder(),
            notificationService: MockNotificationService(),
            logger: logger,
            settingsService: settingsService,
            profileService: resolvedProfileService,
            chatMessageStore: chatMessageStore,
            delayedResponseManager: delayedResponseManager,
            pendingEventQueue: pendingEventQueue,
            typingMonitor: typingMonitor,
            memoryManager: memoryManager,
            dailyContextManager: dailyContextManager,
            characterStatusManager: characterStatusManager,
            diaryService: resolvedDiaryService,
            promptContextAssembler: promptContextAssembler,
            imageMessageProcessor: imageMessageProcessor
        )
    }

    @MainActor
    static func appViewModel(modelContainer: ModelContainer = .preview) -> AppViewModel {
        let logger = MockLoggerService()
        let settingsService = MockSettingsService()
        let llmServiceFactory = LLMServiceFactory(
            keychainService: MockKeychainService(),
            settingsService: settingsService
        )
        let chatMessageStore = ChatMessageStore(modelContainer: modelContainer, logger: logger)
        let profileService = ProfileService(
            modelContainer: modelContainer,
            logger: logger
        )
        let apiProfileService = APIProfileService(
            modelContainer: modelContainer,
            logger: logger
        )
        let diaryService = DiaryService(
            modelContainer: modelContainer,
            chatMessageStore: chatMessageStore,
            logger: logger,
            llmServiceFactory: llmServiceFactory,
            settingsService: settingsService,
            profileService: profileService
        )
        let memoryManager = MemoryManager(
            modelContainer: modelContainer,
            chatMessageStore: chatMessageStore,
            logger: logger,
            llmServiceFactory: llmServiceFactory,
            settingsService: settingsService
        )
        let onlineGreetingService = OnlineGreetingService(
            llmServiceFactory: llmServiceFactory,
            promptBuilder: MockPromptBuilder(),
            settingsService: settingsService,
            chatMessageStore: chatMessageStore,
            logger: logger,
            timeZoneAwarenessProvider: MockTimeZoneAwarenessProvider(logger: logger),
            profileService: profileService
        )
        let cm = conversationManager(
            modelContainer: modelContainer,
            diaryService: diaryService,
            profileService: profileService
        )
        let healthProactiveCoordinator = HealthProactiveCoordinator()
        let systemEventCoordinator = SystemEventCoordinator(
            eventDetectionService: MockEventDetectionService(),
            conversationManager: cm,
            locationService: MockLocationService(),
            diaryService: diaryService,
            healthProactiveCoordinator: healthProactiveCoordinator,
            logger: logger
        )
        let proactiveEngagementCoordinator = ProactiveEngagementCoordinator(
            chatMessageStore: chatMessageStore,
            conversationManager: cm,
            onlineGreetingService: onlineGreetingService,
            healthProactiveCoordinator: healthProactiveCoordinator,
            diaryService: diaryService,
            logger: logger,
            settingsService: settingsService
            // intentDecider intentionally omitted for previews — LLM-judged
            // proactive timing is opt-in and irrelevant to preview rendering.
        )
        return AppViewModel(
            conversationManager: cm,
            chatMessageStore: chatMessageStore,
            eventDetectionService: MockEventDetectionService(),
            logger: logger,
            settingsService: settingsService,
            llmServiceFactory: llmServiceFactory,
            notificationService: MockNotificationService(),
            healthDataService: MockHealthDataService(),
            locationService: MockLocationService(),
            diaryService: diaryService,
            profileService: profileService,
            apiProfileService: apiProfileService,
            memoryManager: memoryManager,
            systemEventCoordinator: systemEventCoordinator,
            proactiveEngagementCoordinator: proactiveEngagementCoordinator
        )
    }
}
