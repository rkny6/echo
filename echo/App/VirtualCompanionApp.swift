import SwiftUI
import SwiftData

@main
struct VirtualCompanionApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let dateContextManager = DateContextManager.shared

    let modelContainer: ModelContainer
    @State private var viewModel: AppViewModel?
    @Environment(\.scenePhase) private var scenePhase
    
    init() {
        // Configure SwiftData
        let schema = Schema([
            ChatMessage.self,
            CompanionEvent.self,
            RelationshipMemory.self,
            APIProfile.self,
            CharacterProfile.self,
            UserProfile.self,
            AppSettings.self,
            PendingResponse.self,
            PendingEvent.self,
            ConversationSnapshot.self,
            HealthAlertRecord.self,
            PendingHealthLLMJob.self,
            LongTermMemory.self,
            DailyContext.self,
            CharacterStatus.self,
            DiaryEntry.self
        ])

        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )

        do {
            modelContainer = try ModelContainer(
                for: schema,
                configurations: [modelConfiguration]
            )
        } catch {
            let fallbackStoreURL = Self.defaultStoreURL()
            if Self.shouldResetStore(for: error) {
                Self.resetStore(at: fallbackStoreURL)
                do {
                    modelContainer = try ModelContainer(
                        for: schema,
                        configurations: [modelConfiguration]
                    )
                } catch {
                    fatalError("Could not initialize ModelContainer after resetting store: \(error)")
                }
            } else {
                fatalError("Could not initialize ModelContainer: \(error)")
            }
        }
    }
    
    private static func defaultStoreURL() -> URL {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return supportDirectory.appendingPathComponent("default.store")
    }

    private static func shouldResetStore(for error: Error) -> Bool {
        let description = error.localizedDescription
        return description.contains("migration") || description.contains("NSCocoaErrorDomain") || description.contains("mandatory destination attribute")
    }

    private static func resetStore(at url: URL) {
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        let shmURL = URL(fileURLWithPath: url.path + "-shm")
        let candidates = [url, walURL, shmURL]

        for candidate in candidates {
            try? FileManager.default.removeItem(at: candidate)
        }
    }

    var body: some Scene {
        WindowGroup {
            if let viewModel = viewModel {
                RootView(viewModel: viewModel)
                    .tint(AppTheme.accentPrimary)
            } else {
                ProgressView()
                    .onAppear {
                        Task {
                            await initializeViewModel()
                        }
                    }
            }
        }
        .modelContainer(modelContainer)
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                // Single serial pipeline: reconcile + health-first + greeting catch-up.
                Task {
                    await viewModel?.handleAppDidBecomeActive()
                }
            }
            if newPhase == .background || newPhase == .inactive {
                // Schedule app refresh when entering background
                BackgroundTaskService.shared.scheduleAppRefresh()
                // Re-arm the ~23:30 diary slot too — submitting again just
                // replaces any still-pending request with a freshly computed
                // "next 23:30", so this stays correct even if the app sat in
                // the foreground across a day boundary.
                BackgroundTaskService.shared.scheduleDiaryGeneration()
            }
        }
    }
    
    @MainActor
    private func initializeViewModel() async {
        // Initialize services
        let keychainService = KeychainService()
        let loggerService = LoggerService()
        let settingsService = SettingsService(modelContainer: modelContainer, logger: loggerService)
        let notificationService = NotificationService()
        let healthDataService = HealthDataService()
        let locationService = LocationService()
        let timeZoneAwarenessProvider = TimeZoneAwarenessProvider(logger: loggerService)
        
        // Request notification permissions
        do {
            _ = try await notificationService.requestAuthorization()
        } catch {
            await loggerService.log(
                "Failed to request notification authorization: \(error.localizedDescription)",
                level: .error
            )
        }
        
        // Initialize prompt builder and LLM factory (now using new structure)
        let promptBuilder = PromptBuilder()
        let llmServiceFactory = LLMServiceFactory(
            keychainService: keychainService,
            settingsService: settingsService,
            logger: loggerService
        )

        // Single chat owner (PR1a–PR1e): writes + prompt-context reads.
        // Declared early because Memory / Diary / Event / DRM / Conversation
        // all take a reference.
        let chatMessageStore = ChatMessageStore(
            modelContainer: modelContainer,
            logger: loggerService
        )

        // Sole durable owner for CharacterProfile / UserProfile.
        let profileService = ProfileService(
            modelContainer: modelContainer,
            logger: loggerService
        )

        // Sole durable owner for APIProfile rows.
        let apiProfileService = APIProfileService(
            modelContainer: modelContainer,
            logger: loggerService
        )
        
        // Initialize memory manager
        let memoryManager = MemoryManager(
            modelContainer: modelContainer,
            chatMessageStore: chatMessageStore,
            logger: loggerService,
            llmServiceFactory: llmServiceFactory,
            settingsService: settingsService
        )

        // Initialize event detection
        let eventDetectionService = EventDetectionService(
            healthDataService: healthDataService,
            locationService: locationService,
            profileService: profileService,
            dateContextManager: dateContextManager,
            llmServiceFactory: llmServiceFactory,
            promptBuilder: promptBuilder,
            settingsService: settingsService,
            chatMessageStore: chatMessageStore,
            logger: loggerService,
            timeZoneAwarenessProvider: timeZoneAwarenessProvider
        )

        // Initialize conversation infrastructure
        let pendingEventQueue = PendingEventQueue(
            modelContainer: modelContainer,
            logger: loggerService
        )
        let delayedResponseManager = DelayedResponseManager(
            profileService: profileService,
            notificationService: notificationService,
            chatMessageStore: chatMessageStore,
            logger: loggerService
        )
        let typingMonitor = TypingMonitor(logger: loggerService)
        
        let dailyContextManager = DailyContextManager(
            logger: loggerService,
            llmServiceFactory: llmServiceFactory,
            settingsService: settingsService
        )
        
        let characterStatusManager = CharacterStatusManager(
            logger: loggerService
        )

        // Single DiaryService shared by conversation retrieval, system
        // triggers (after-midnight generation), and UI/debug tools.
        let diaryService = DiaryService(
            modelContainer: modelContainer,
            chatMessageStore: chatMessageStore,
            logger: loggerService,
            llmServiceFactory: llmServiceFactory,
            settingsService: settingsService,
            profileService: profileService
        )

        // Extracted from ConversationManager: bundles daily-context/status/
        // memory/ambience/gap so both event-triggered and user-message
        // replies assemble this exact same set of values through one call
        // instead of two independently-maintained copies.
        let promptContextAssembler = PromptContextAssembler(
            dailyContextManager: dailyContextManager,
            characterStatusManager: characterStatusManager,
            memoryManager: memoryManager,
            timeZoneAwarenessProvider: timeZoneAwarenessProvider,
            dateAmbienceProvider: DateAmbienceProvider(logger: loggerService),
            weatherAmbienceProvider: WeatherAmbienceProvider(logger: loggerService),
            sleepAmbienceProvider: SleepAmbienceProvider(
                healthDataService: HealthDataService(),
                logger: loggerService
            ),
            locationProvider: locationService,
            chatMessageStore: chatMessageStore
        )

        // Extracted from ConversationManager: cloud/on-device image
        // recognition + fallback policy, isolated in its own actor.
        let imageMessageProcessor = ImageMessageProcessor(
            settingsService: settingsService,
            logger: loggerService
        )

        // Tool registry for LLM tool calls (Phase 2). The weather tool is the
        // first built-in; registered unconditionally here but only exposed to
        // the model when the "使用 MCP" toggle (AppSettings.enableMCP) is on.
        let localTools: [any LLMTool] = [
            WeatherTool(
                locationProvider: locationService,
                weatherFetcher: DailyWeatherFetcher()
            )
        ]
        let toolRegistry = ToolRegistry(tools: localTools)

        let conversationManager = ConversationManager(
            llmServiceFactory: llmServiceFactory,
            promptBuilder: promptBuilder,
            notificationService: notificationService,
            logger: loggerService,
            settingsService: settingsService,
            profileService: profileService,
            chatMessageStore: chatMessageStore,
            delayedResponseManager: delayedResponseManager,
            pendingEventQueue: pendingEventQueue,
            typingMonitor: typingMonitor,
            memoryManager: memoryManager,
            dailyContextManager: dailyContextManager,
            characterStatusManager: characterStatusManager,
            diaryService: diaryService,
            promptContextAssembler: promptContextAssembler,
            imageMessageProcessor: imageMessageProcessor,
            toolRegistry: toolRegistry
        )

        // Merge in remote MCP tools asynchronously: fetching a server's
        // tools/list requires a network round trip (and the MCP
        // initialize handshake), which can't happen inside the synchronous
        // composition root above. Runs once at launch; if the server is
        // unreachable the app keeps working with just the local tools
        // (WeatherTool) already registered — MCP failure never blocks
        // startup or breaks plain-text replies.
        Task {
            let settings = try? await settingsService.getSettings()
            // Debug-only override: `simctl launch <bundle-id> -mcpServerURL <url>`
            // lets a local MCP test server be wired in without touching the
            // SwiftData-backed settings UI. Only honored in DEBUG builds so it
            // can never leak into release.
            let launchArgs = ProcessInfo.processInfo.arguments
            #if DEBUG
            await loggerService.log(
                "MCP debug: launchArgs=\(launchArgs), enableMCP=\(String(describing: settings?.enableMCP)), storedURL=\(String(describing: settings?.mcpServerURL))",
                level: .info
            )
            #endif
            let debugMCPServerURL: String? = {
                #if DEBUG
                if let idx = launchArgs.firstIndex(of: "-mcpServerURL"),
                   idx + 1 < launchArgs.count {
                    return launchArgs[idx + 1]
                }
                #endif
                return nil
            }()
            let urlString = debugMCPServerURL ?? settings?.mcpServerURL
            guard (debugMCPServerURL != nil || settings?.enableMCP == true),
                  let urlString,
                  let serverURL = URL(string: urlString)
            else { return }

            let connector = MCPConnector(serverURL: serverURL, logger: loggerService)
            do {
                let remoteDefinitions = try await connector.fetchTools()
                let remoteTools: [any LLMTool] = remoteDefinitions.map { definition in
                    RemoteMCPTool(definition: definition) { call in
                        try await connector.callTool(call)
                    }
                }
                await conversationManager.setToolRegistry(ToolRegistry(tools: localTools + remoteTools))
                await loggerService.log(
                    "MCP connected: \(remoteTools.count) tool(s) from \(urlString)",
                    level: .info
                )
            } catch {
                await loggerService.log(
                    "MCP connection to \(urlString) failed, continuing with local tools only: \(error.localizedDescription)",
                    level: .error
                )
            }
        }

        let messageBatcher = MessageBatcher(
            logger: loggerService,
            onCompleted: { batch in
                do {
                    try await conversationManager.handleAccumulatedBatch(batch)
                } catch is CancellationError {
                    await loggerService.log(
                        "Accumulated batch handling cancelled",
                        level: .debug
                    )
                } catch {
                    await loggerService.log(
                        "Failed to handle accumulated batch: \(error.localizedDescription)",
                        level: .error
                    )
                }
            },
            onWaitingStateChange: { visible in
                await conversationManager.handleReadingIndicatorChange(visible)
            }
        )
        await conversationManager.setMessageBatcher(messageBatcher)
        await conversationManager.configureTypingMonitorCallbacks()

        let healthLLMGenerationService = HealthLLMGenerationService(
            llmServiceFactory: llmServiceFactory,
            promptBuilder: promptBuilder,
            settingsService: settingsService,
            chatMessageStore: chatMessageStore,
            logger: loggerService,
            timeZoneAwarenessProvider: timeZoneAwarenessProvider,
            profileService: profileService
        )
        let onlineGreetingService = OnlineGreetingService(
            llmServiceFactory: llmServiceFactory,
            promptBuilder: promptBuilder,
            settingsService: settingsService,
            chatMessageStore: chatMessageStore,
            logger: loggerService,
            timeZoneAwarenessProvider: timeZoneAwarenessProvider,
            profileService: profileService
        )
        let healthProactiveDeliveryService = HealthProactiveDeliveryService(
            eventDetectionService: eventDetectionService,
            llmGenerationService: healthLLMGenerationService,
            notificationService: notificationService,
            chatMessageStore: chatMessageStore,
            profileService: profileService,
            logger: loggerService
        )
        let healthProactiveCoordinator = HealthProactiveCoordinator()
        await healthProactiveCoordinator.configure(
            deliveryService: healthProactiveDeliveryService
        )

        // Built here (composition root) rather than inside AppViewModel so
        // both this file and AppViewModel receive the same instance via
        // their initializers — no `.shared` global, no window where a call
        // site could run before the reference exists.
        let systemEventCoordinator = SystemEventCoordinator(
            eventDetectionService: eventDetectionService,
            conversationManager: conversationManager,
            locationService: locationService,
            diaryService: diaryService,
            healthProactiveCoordinator: healthProactiveCoordinator,
            logger: loggerService
        )

        // Optional LLM-judged replacement for the fixed proactive-outreach
        // thresholds (see ProactiveIntentDecider's doc comment). Always
        // constructed — it's inert unless AppSettings.useLLMProactiveJudgment
        // is turned on in Settings, so there's no extra cost when it's off.
        let proactiveIntentDecider = ProactiveIntentDecider(
            llmServiceFactory: llmServiceFactory,
            settingsService: settingsService,
            profileService: profileService,
            memoryManager: memoryManager,
            logger: loggerService,
            timeZoneAwarenessProvider: timeZoneAwarenessProvider
        )

        // Extracted from AppViewModel: online-greeting / evening-check-in
        // timing plus the cold-start health/diary catch-up pipeline. Built
        // here so it's a normal injected dependency, not something
        // AppViewModel constructs for itself.
        let proactiveEngagementCoordinator = ProactiveEngagementCoordinator(
            chatMessageStore: chatMessageStore,
            conversationManager: conversationManager,
            onlineGreetingService: onlineGreetingService,
            healthProactiveCoordinator: healthProactiveCoordinator,
            diaryService: diaryService,
            logger: loggerService,
            settingsService: settingsService,
            intentDecider: proactiveIntentDecider
        )

        // Create view model
        let vm = AppViewModel(
            conversationManager: conversationManager,
            chatMessageStore: chatMessageStore,
            eventDetectionService: eventDetectionService,
            logger: loggerService,
            settingsService: settingsService,
            llmServiceFactory: llmServiceFactory,
            notificationService: notificationService,
            healthDataService: healthDataService,
            locationService: locationService,
            keychainService: keychainService,
            diaryService: diaryService,
            profileService: profileService,
            apiProfileService: apiProfileService,
            memoryManager: memoryManager,
            systemEventCoordinator: systemEventCoordinator,
            proactiveEngagementCoordinator: proactiveEngagementCoordinator
        )

        // Chat rows merge from ChatMessageStore.changes (PR1d); no per-insert
        // refresh callback is required for health proactive delivery.

        await conversationManager.setCallbacks(
            onStateChange: { state in
                await MainActor.run {
                    vm.conversationState = state
                }
            },
            onReplyGenerating: {
                await MainActor.run {
                    vm.isGeneratingReply = true
                }
            },
            onReadingIndicatorChange: { visible in
                await MainActor.run {
                    vm.isCharacterReading = visible
                }
            },
            onEventResponseScheduled: {
                await MainActor.run {
                    vm.isGeneratingReply = false
                }
            },
            onReplyReady: {
                await MainActor.run {
                    // Durable assistant rows arrive via store.changes.
                    vm.isGeneratingReply = false
                }
            },
            onError: { message in
                await MainActor.run {
                    vm.isGeneratingReply = false
                    vm.errorMessage = message
                    // Failed status is broadcast by ChatMessageStore; keep a
                    // safety refresh in case the UI window was empty/stale.
                    Task { await vm.refreshChatHistory() }
                }
            }
        )
        
        await conversationManager.setOnCharacterStatusChange { status in
            await MainActor.run {
                vm.isCharacterOnline = status == .online
            }
        }

        await conversationManager.setOnScheduledOnline {
            await vm.handleScheduledOnline()
        }

        await systemEventCoordinator.setOnlineGreetingCatchUp {
            // Same serial order as runProactiveCatchUp silence branch (greeting, then evening).
            await vm.maybeCatchUpOnlineGreeting(source: "bgRefresh")
            await vm.maybeCatchUpEveningCheckIn(source: "bgRefresh")
        }

        // Only start monitoring (which wires up the refresh/health/diary
        // handlers that can invoke the callback above) now that the
        // callback is actually registered — previously this ran fire-and-forget
        // from inside AppViewModel's init with no guaranteed ordering
        // relative to this registration.
        await systemEventCoordinator.startMonitoring()
        
        // Prefer service snapshots so daily context is not built from
        // AppViewModel's pre-loadInitialState defaults.
        do {
            let character = await profileService.loadCharacter()
            let user = await profileService.loadUser()
            try await conversationManager.initializeDailyContextAndStatus(
                character: character,
                user: user
            )
            let initialStatus = await characterStatusManager.getCurrentStatus()
            vm.isCharacterOnline = initialStatus == .online
        } catch {
            await loggerService.log(
                "Failed to initialize daily context and status: \(error.localizedDescription)",
                level: .warning
            )
        }

        await delayedResponseManager.setOnDelivered { conversationId in
            await conversationManager.handleDelayedResponseDelivered(conversationId: conversationId)
        }

        self.viewModel = vm

        // Cold-start catch-up: health first, then silence greeting if no health story.
        await vm.runProactiveCatchUp(source: "coldStart")

        BackgroundTaskService.shared.scheduleAppRefresh()
        BackgroundTaskService.shared.scheduleDiaryGeneration()
    }
}
