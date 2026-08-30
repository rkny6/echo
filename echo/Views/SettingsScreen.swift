import SwiftUI
import SwiftData

/// Settings screen for API configuration and app preferences with modern design
struct SettingsScreen: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.colorScheme) var colorScheme
    @State private var apiKeyInput = ""
    @State private var hasExistingAPIKey = false
    @State private var savedAPIKeyPreview = ""
    @State private var isSavingAPIKey = false
    @State private var showingAgnesAPIKeyInput = false
    @State private var selectedProvider: LLMProvider = .customOpenAICompatible
    @State private var selectedModel: String
    @State private var temperature: Double
    @State private var maxTokens: Int
    @State private var customBaseURL: String
    @State private var endpointMode: LLMAPIEndpointMode
    @State private var mcpServerURL: String
    @State private var savedMessage = ""
    @State private var isSaved = false
    @State private var isTestingConnection = false
    @State private var isErrorMessage = false

    private var hasChanges: Bool {
        let currentSettings = viewModel.appSettings
        return selectedProvider != currentSettings.selectedProvider ||
            selectedModel != currentSettings.selectedModel ||
            temperature != currentSettings.temperature ||
            maxTokens != currentSettings.maxTokens ||
            customBaseURL != (currentSettings.customBaseURL ?? "") ||
            endpointMode != currentSettings.endpointMode
    }

    private var saveButtonTitle: String {
        isSaved && !hasChanges ? "已保存" : "保存设置"
    }

    private func clearSaveState() {
        if isSaved || !savedMessage.isEmpty {
            isSaved = false
            savedMessage = ""
            isErrorMessage = false
        }
    }

    private func maskAPIKey(_ key: String) -> String {
        guard key.count > 8 else { return "***" }
        let prefix = String(key.prefix(5))
        let suffix = String(key.suffix(4))
        return "\(prefix)***...\(suffix)"
    }

    private func loadExistingAPIKey() {
        Task {
            if let key = await viewModel.retrieveAPIKey(for: .customOpenAICompatible), !key.isEmpty {
                hasExistingAPIKey = true
                savedAPIKeyPreview = maskAPIKey(key)
            }
        }
    }

    private func saveAPIKeyInline() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSavingAPIKey = true
        Task {
            await viewModel.saveAPIKey(trimmed, for: .customOpenAICompatible)
            hasExistingAPIKey = true
            savedAPIKeyPreview = maskAPIKey(trimmed)
            apiKeyInput = ""
            isSavingAPIKey = false
        }
    }

    private func deleteAPIKeyInline() {
        isSavingAPIKey = true
        Task {
            await viewModel.deleteAPIKey(for: .customOpenAICompatible)
            hasExistingAPIKey = false
            savedAPIKeyPreview = ""
            apiKeyInput = ""
            isSavingAPIKey = false
        }
    }

    var body: some View {
        ScreenBackground {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 20) {
                    // Header Section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("设置")
                            .font(.system(size: 32, weight: .bold, design: .default))
                            .foregroundColor(AppTheme.textColor(colorScheme))

                        Text("配置应用偏好和管理账户")
                            .font(.system(size: 15, weight: .regular, design: .default))
                            .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                            .opacity(0.80)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                    // Appearance Settings
                    VStack(spacing: 12) {
                        AppearanceSettingsCard(themeManager: themeManager)
                    }
                    .padding(.horizontal, 20)

                    // Preference Settings
                    VStack(spacing: 12) {
                        SettingsCard(
                            title: "偏好设置",
                            subtitle: "自定义应用行为和外观"
                        ) {
                            // Proactive Caring Toggle
                            ToggleRow(
                                icon: "heart.fill",
                                title: "角色主动关心",
                                subtitle: "角色在你很久没说话时，会主动问候",
                                isOn: Binding(
                                    get: { viewModel.appSettings.proactiveCaringEnabled },
                                    set: { newValue in updateSetting { $0.proactiveCaringEnabled = newValue } }
                                )
                            )

                            if viewModel.appSettings.proactiveCaringEnabled {
                                MinimalDivider()

                                // LLM-judged proactive timing toggle
                                ToggleRow(
                                    icon: "brain",
                                    title: "用 AI 判断主动关心的时机",
                                    subtitle: "开启后由模型综合关系记忆和当下情境判断要不要主动找你，而不是固定的时间/时长规则",
                                    isOn: Binding(
                                        get: { viewModel.appSettings.useLLMProactiveJudgment },
                                        set: { newValue in updateSetting { $0.useLLMProactiveJudgment = newValue } }
                                    )
                                )
                            }

                            MinimalDivider()

                            // MCP Toggle
                            ToggleRow(
                                icon: "link",
                                title: "使用工具调用 (MCP)",
                                subtitle: "开启后模型可在对话中调用已注册的工具（如天气查询、MCP 服务器）",
                                isOn: Binding(
                                    get: { viewModel.appSettings.enableMCP },
                                    set: { newValue in updateSetting { $0.enableMCP = newValue } }
                                )
                            )

                            MinimalDivider()

                            // User Avatar Toggle
                            ToggleRow(
                                icon: "person.fill",
                                title: "显示我的头像",
                                subtitle: "在消息旁显示你的头像",
                                isOn: Binding(
                                    get: { viewModel.appSettings.showUserAvatar },
                                    set: { newValue in updateSetting { $0.showUserAvatar = newValue } }
                                )
                            )

                            MinimalDivider()

                            // Character Avatar Toggle
                            ToggleRow(
                                icon: "person.crop.square.fill",
                                title: "显示角色头像",
                                subtitle: "在消息旁显示角色的头像",
                                isOn: Binding(
                                    get: { viewModel.appSettings.showCharacterAvatar },
                                    set: { newValue in updateSetting { $0.showCharacterAvatar = newValue } }
                                )
                            )
                        }
                    }
                    .padding(.horizontal, 20)

                    // Advanced Settings
                    VStack(spacing: 12) {
                        SettingsCard(
                            title: "高级选项",
                            subtitle: "调试和开发相关设置"
                        ) {
                            // Debug Mode Toggle
                            ToggleRow(
                                icon: "bug",
                                title: "调试模式",
                                subtitle: "查看日志和诊断信息",
                                tintColor: AppTheme.warningColor(colorScheme),
                                isOn: Binding(
                                    get: { viewModel.appSettings.debugModeEnabled },
                                    set: { newValue in updateSetting { $0.debugModeEnabled = newValue } }
                                )
                            )

                            MinimalDivider()

                            ToggleRow(
                                icon: "photo.on.rectangle.angled",
                                title: "允许发送图片",
                                subtitle: "启用图片发送后才可配置 Agnes AI API Key",
                                tintColor: AppTheme.adaptiveAccentColor(colorScheme),
                                isOn: Binding(
                                    get: { viewModel.appSettings.allowImageSending },
                                    set: { newValue in updateSetting { $0.allowImageSending = newValue } }
                                )
                            )

                            // Agnes API Key - only visible in debug mode
                            if viewModel.appSettings.debugModeEnabled && viewModel.appSettings.allowImageSending {
                                MinimalDivider()

                                Button(action: {
                                    showingAgnesAPIKeyInput = true
                                }) {
                                    HStack(spacing: 12) {
                                        Image(systemName: "key.fill")
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(AppTheme.adaptiveAccentColor(colorScheme))

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Agnes API Key")
                                                .font(.system(size: 16, weight: .semibold, design: .default))
                                                .foregroundColor(AppTheme.textColor(colorScheme))
                                            Text("配置 Agnes 图像理解所需的 API Key (Debug)")
                                                .font(.system(size: 13, weight: .regular, design: .default))
                                                .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                                                .opacity(0.80)
                                        }

                                        Spacer()

                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                                            .opacity(0.60)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 14)
                                    .background(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(AppTheme.inputFieldBackground(colorScheme))
                                    )
                                }
                            }

                            if viewModel.appSettings.debugModeEnabled {
                                MinimalDivider()
                                
                                NavigationLink(destination: DebugScreen(viewModel: viewModel)) {
                                    HStack(spacing: 10) {
                                        Image(systemName: "terminal.fill")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(AppTheme.adaptiveAccentColor(colorScheme))

                                        Text("查看日志")
                                            .font(.system(size: 16, weight: .semibold, design: .default))
                                            .foregroundColor(AppTheme.textColor(colorScheme))

                                        Spacer()

                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                                            .opacity(0.60)
                                    }
                                    .padding(.horizontal, 4)
                                }
                            }

                            // MCP Server URL — dev entry, wired when the
                            // swift-mcp SDK is integrated. Only visible in
                            // debug mode so regular users are not exposed to a
                            // field that is not yet functional.
                            if viewModel.appSettings.debugModeEnabled {
                                MinimalDivider()

                                VStack(alignment: .leading, spacing: 12) {
                                    Text("MCP 服务器地址")
                                        .font(.system(size: 14, weight: .semibold, design: .default))
                                        .foregroundColor(AppTheme.secondaryTextColor(colorScheme))

                                    TextField("例如: https://mcp.example.com/sse", text: $mcpServerURL)
                                        .font(.system(size: 16, weight: .regular, design: .default))
                                        .autocapitalization(.none)
                                        .keyboardType(.URL)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 14)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .fill(AppTheme.inputFieldBackground(colorScheme))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .stroke(AppTheme.inputFieldBorderColor(colorScheme), lineWidth: 1)
                                        )

                                    Text("启用「使用工具调用 (MCP)」后连接该远程服务器获取外部工具（开发中，需集成 swift-mcp SDK）。")
                                        .font(.system(size: 12, weight: .regular, design: .default))
                                        .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                                        .opacity(0.70)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .onChange(of: mcpServerURL) { newValue in
                                    updateSetting { $0.mcpServerURL = newValue.isEmpty ? nil : newValue }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)

                    // API Configuration
                    VStack(spacing: 12) {
                        SettingsCard(
                            title: "API 配置",
                            subtitle: "配置自定义 API 地址和模型参数"
                        ) {
                            // Custom API Base URL
                            VStack(alignment: .leading, spacing: 12) {
                                Text("API 地址")
                                    .font(.system(size: 14, weight: .semibold, design: .default))
                                    .foregroundColor(AppTheme.secondaryTextColor(colorScheme))

                                ProfileTextField(
                                    title: "Base URL",
                                    placeholder: "例如: https://api.yourprovider.com/v1",
                                    text: $customBaseURL
                                )
                                .onChange(of: customBaseURL) { _ in clearSaveState() }
                            }

                            // Model Selection
                            VStack(alignment: .leading, spacing: 12) {
                                Text("模型名称")
                                    .font(.system(size: 14, weight: .semibold, design: .default))
                                    .foregroundColor(AppTheme.secondaryTextColor(colorScheme))

                                ProfileTextField(
                                    title: "模型名称",
                                    placeholder: "例如: gpt-4-turbo 或自定义模型名",
                                    text: $selectedModel
                                )
                                .onChange(of: selectedModel) { _ in clearSaveState() }
                            }

                            // Endpoint Mode
                            VStack(alignment: .leading, spacing: 12) {
                                Text("接口模式")
                                    .font(.system(size: 14, weight: .semibold, design: .default))
                                    .foregroundColor(AppTheme.secondaryTextColor(colorScheme))

                                Menu {
                                    ForEach(LLMAPIEndpointMode.allCases, id: \.self) { mode in
                                        Button {
                                            endpointMode = mode
                                            clearSaveState()
                                        } label: {
                                            HStack {
                                                Text(mode.displayName)
                                                if mode == endpointMode {
                                                    Image(systemName: "checkmark")
                                                        .font(.system(size: 13, weight: .semibold))
                                                }
                                            }
                                        }
                                    }
                                } label: {
                                    HStack {
                                        Text(endpointMode.displayName)
                                            .font(.system(size: 16, weight: .regular, design: .default))
                                            .foregroundColor(AppTheme.textColor(colorScheme))

                                        Spacer()

                                        Image(systemName: "chevron.down")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 14)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(AppTheme.inputFieldBackground(colorScheme))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(AppTheme.inputFieldBorderColor(colorScheme), lineWidth: 1)
                                    )
                                }
                            }

                            // Temperature Slider
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 0) {
                                    Text("温度参数")
                                        .font(.system(size: 14, weight: .semibold, design: .default))
                                        .foregroundColor(AppTheme.secondaryTextColor(colorScheme))

                                    Spacer()

                                    Text(String(format: "%.1f", temperature))
                                        .font(.system(size: 14, weight: .semibold, design: .default))
                                        .foregroundColor(AppTheme.adaptiveAccentColor(colorScheme))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .fill(AppTheme.adaptiveAccentColor(colorScheme).opacity(0.10))
                                        )
                                }

                                Slider(value: $temperature, in: 0...1, step: 0.1)
                                    .accentColor(AppTheme.adaptiveAccentColor(colorScheme))
                                    .onChange(of: temperature) { _, _ in
                                        clearSaveState()
                                    }

                                HStack(spacing: 0) {
                                    Text("精确")
                                        .font(.system(size: 12, weight: .regular, design: .default))
                                        .foregroundColor(AppTheme.tertiaryTextColor(colorScheme))
                                        .opacity(0.70)

                                    Spacer()

                                    Text("创意")
                                        .font(.system(size: 12, weight: .regular, design: .default))
                                        .foregroundColor(AppTheme.tertiaryTextColor(colorScheme))
                                        .opacity(0.70)
                                }
                            }

                            // Max Tokens
                            VStack(alignment: .leading, spacing: 12) {
                                Text("最大令牌数")
                                    .font(.system(size: 14, weight: .semibold, design: .default))
                                    .foregroundColor(AppTheme.secondaryTextColor(colorScheme))

                                TextField("例如: 4096", value: $maxTokens, format: .number)
                                    .font(.system(size: 16, weight: .regular, design: .default))
                                    .keyboardType(.numberPad)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 14)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(AppTheme.inputFieldBackground(colorScheme))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(AppTheme.inputFieldBorderColor(colorScheme), lineWidth: 1)
                                    )
                                    .onChange(of: maxTokens) { _ in clearSaveState() }
                            }

                            // API Key (inline, no sheet)
                            VStack(alignment: .leading, spacing: 12) {
                                Text("API Key")
                                    .font(.system(size: 14, weight: .semibold, design: .default))
                                    .foregroundColor(AppTheme.secondaryTextColor(colorScheme))

                                if hasExistingAPIKey && apiKeyInput.isEmpty {
                                    HStack(spacing: 12) {
                                        Text(savedAPIKeyPreview)
                                            .font(.system(size: 14, weight: .regular, design: .monospaced))
                                            .foregroundColor(AppTheme.textColor(colorScheme))

                                        Spacer()

                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 18, weight: .semibold))
                                            .foregroundColor(AppTheme.successColor(colorScheme))
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(AppTheme.successColor(colorScheme).opacity(0.08))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(AppTheme.successColor(colorScheme).opacity(0.20), lineWidth: 1)
                                    )
                                }

                                SecureField(
                                    hasExistingAPIKey ? "输入新 Key 以替换（留空则保持不变）" : "输入你的 API Key",
                                    text: $apiKeyInput
                                )
                                    .font(.system(size: 16, weight: .regular, design: .default))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 14)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(AppTheme.inputFieldBackground(colorScheme))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(AppTheme.inputFieldBorderColor(colorScheme), lineWidth: 1)
                                    )

                                if !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasExistingAPIKey {
                                    HStack(spacing: 12) {
                                        if !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                            SecondaryButton(
                                                title: isSavingAPIKey ? "保存中..." : (hasExistingAPIKey ? "更新 Key" : "保存 Key"),
                                                disabled: isSavingAPIKey
                                            ) {
                                                saveAPIKeyInline()
                                            }
                                        }

                                        if hasExistingAPIKey {
                                            SecondaryButton(
                                                title: "删除",
                                                disabled: isSavingAPIKey
                                            ) {
                                                deleteAPIKeyInline()
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.top, 4)

                            // Action Buttons
                            VStack(spacing: 12) {
                                PrimaryButton(
                                    title: saveButtonTitle,
                                    disabled: !hasChanges
                                ) {
                                    saveSettings()
                                }

                                SecondaryButton(
                                    title: isTestingConnection ? "测试中..." : "测试连接",
                                    disabled: isTestingConnection
                                ) {
                                    testConnection()
                                }

                                NavigationLink(destination: APIProfilesScreen(viewModel: viewModel)) {
                                    HStack(spacing: 10) {
                                        Image(systemName: "square.stack")
                                            .font(.system(size: 14, weight: .semibold))

                                        Text("API 配置文件")
                                            .font(.system(size: 16, weight: .semibold, design: .default))

                                        Spacer()

                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 14, weight: .semibold))
                                            .opacity(0.60)
                                    }
                                    .foregroundColor(AppTheme.adaptiveAccentColor(colorScheme))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 14)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(AppTheme.inputFieldBackground(colorScheme))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(AppTheme.inputFieldBorderColor(colorScheme), lineWidth: 1)
                                    )
                                }

                                Text("上面的 API Key 是当前生效的 Key；如果你有多个不同的接口/Key，建议在「API 配置文件」里分别保存，切换配置时会自动换用对应的 Key。")
                                    .font(.system(size: 12, weight: .regular, design: .default))
                                    .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                                    .opacity(0.70)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 4)
                            }
                            .padding(.top, 8)
                        }
                    }
                    .padding(.horizontal, 20)

                    // Message Banner
                    if !savedMessage.isEmpty {
                        MessageBanner(
                            message: savedMessage,
                            isError: isErrorMessage
                        )
                        .padding(.horizontal, 20)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    Spacer(minLength: 20)
                }
                .padding(.vertical, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .dismissKeyboardOnTap()
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Re-sync when returning from child screens (e.g. API profiles).
            // Local @State is only initialized once; applying a profile updates
            // viewModel.appSettings but would otherwise leave this form stale.
            syncFormFromViewModel()
        }
        .task {
            loadExistingAPIKey()
        }
        .sheet(isPresented: $showingAgnesAPIKeyInput) {
            AgnesAPIKeyInputSheet(viewModel: viewModel)
        }
    }

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        _selectedProvider = State(initialValue: .customOpenAICompatible)
        _selectedModel = State(initialValue: viewModel.appSettings.selectedModel)
        _temperature = State(initialValue: viewModel.appSettings.temperature)
        _maxTokens = State(initialValue: viewModel.appSettings.maxTokens)
        _customBaseURL = State(initialValue: viewModel.appSettings.customBaseURL ?? "")
        _endpointMode = State(initialValue: viewModel.appSettings.endpointMode)
        _mcpServerURL = State(initialValue: viewModel.appSettings.mcpServerURL ?? "")
    }

    /// Pull the live API config into the editable form fields.
    private func syncFormFromViewModel() {
        let current = viewModel.appSettings
        selectedProvider = current.selectedProvider
        selectedModel = current.selectedModel
        temperature = current.temperature
        maxTokens = current.maxTokens
        customBaseURL = current.customBaseURL ?? ""
        endpointMode = current.endpointMode
        mcpServerURL = current.mcpServerURL ?? ""
        isSaved = false
        savedMessage = ""
        isErrorMessage = false
        loadExistingAPIKey()
    }

    private func updateSetting(_ update: (inout AppSettings) -> Void) {
        // Work on a detached copy — never mutate the live SwiftData row from
        // the MainActor (see AppSettings.copy()).
        var settings = viewModel.appSettings.copy()
        update(&settings)
        Task { await viewModel.updateAppSettings(settings) }
    }

    private func saveSettings() {
        var settings = viewModel.appSettings.copy()
        settings.selectedProvider = selectedProvider
        settings.selectedModel = selectedModel
        settings.temperature = temperature
        settings.maxTokens = maxTokens
        settings.customBaseURL = customBaseURL.isEmpty ? nil : customBaseURL
        settings.endpointMode = endpointMode

        Task {
            await viewModel.updateAppSettings(settings)
            withAnimation(.easeInOut(duration: 0.3)) {
                savedMessage = "已保存"
                isSaved = true
                isErrorMessage = false
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    savedMessage = ""
                }
            }
        }
    }

    private func testConnection() {
        isTestingConnection = true
        isErrorMessage = false
        savedMessage = "正在测试连接..."

        Task {
            do {
                let success: Bool
                if showingAgnesAPIKeyInput {
                    success = try await viewModel.testAgnesConnection()
                } else {
                    var testSettings = viewModel.appSettings.copy()
                    testSettings.selectedProvider = selectedProvider
                    testSettings.selectedModel = selectedModel
                    testSettings.temperature = temperature
                    testSettings.maxTokens = maxTokens
                    testSettings.customBaseURL = customBaseURL.isEmpty ? nil : customBaseURL
                    testSettings.endpointMode = endpointMode
                    success = try await viewModel.testProviderConnection(using: testSettings)
                }

                withAnimation(.easeInOut(duration: 0.3)) {
                    savedMessage = success ? "测试连接成功" : "测试连接失败：请检查 API Key 和网络"
                    isSaved = false
                    isErrorMessage = !success
                }
            } catch {
                withAnimation(.easeInOut(duration: 0.3)) {
                    savedMessage = "测试连接失败：\(error.localizedDescription)"
                    isSaved = false
                    isErrorMessage = true
                }
            }

            if viewModel.appSettings.debugModeEnabled {
                await viewModel.refreshDebugLogs()
            }

            isTestingConnection = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    savedMessage = ""
                }
            }
        }
    }
}

// MARK: - Helper Components

/// Appearance settings: theme preset selection + light/dark/system mode.
/// Purely cosmetic — persisted via ThemeManager (UserDefaults), never touches app data.
struct AppearanceSettingsCard: View {
    @ObservedObject var themeManager: ThemeManager
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SettingsCard(
            title: "外观",
            subtitle: "选择配色主题与明暗模式"
        ) {
            // Theme preset swatches
            VStack(alignment: .leading, spacing: 12) {
                Text("配色主题")
                    .font(.system(size: 14, weight: .semibold, design: .default))
                    .foregroundColor(AppTheme.secondaryTextColor(colorScheme))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(ThemePreset.allCases) { preset in
                            themeSwatch(for: preset)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
                }
            }

            MinimalDivider()

            // Appearance mode selector
            VStack(alignment: .leading, spacing: 12) {
                Text("明暗模式")
                    .font(.system(size: 14, weight: .semibold, design: .default))
                    .foregroundColor(AppTheme.secondaryTextColor(colorScheme))

                HStack(spacing: 8) {
                    ForEach(AppearanceMode.allCases) { mode in
                        appearanceOption(for: mode)
                    }
                }
            }
        }
    }

    private func themeSwatch(for preset: ThemePreset) -> some View {
        let palette = preset.palette
        let isSelected = themeManager.preset == preset

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                themeManager.preset = preset
            }
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(palette.backgroundL)
                        .frame(width: 48, height: 48)
                    Circle()
                        .fill(palette.userBubbleL)
                        .frame(width: 26, height: 26)
                    Circle()
                        .fill(palette.accentL)
                        .frame(width: 14, height: 14)
                        .offset(x: 12, y: 12)
                }
                .overlay(
                    Circle()
                        .stroke(
                            isSelected ? AppTheme.adaptiveAccentColor(colorScheme) : AppTheme.borderColor(colorScheme),
                            lineWidth: isSelected ? 2.5 : 1
                        )
                        .frame(width: 54, height: 54)
                )

                Text(palette.displayName)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? AppTheme.textColor(colorScheme) : AppTheme.secondaryTextColor(colorScheme))
            }
            .frame(width: 64)
        }
        .buttonStyle(.plain)
    }

    private func appearanceOption(for mode: AppearanceMode) -> some View {
        let isSelected = themeManager.appearanceMode == mode

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                themeManager.appearanceMode = mode
            }
        } label: {
            Text(mode.displayName)
                .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .white : AppTheme.textColor(colorScheme))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? AppTheme.adaptiveAccentColor(colorScheme) : AppTheme.inputFieldBackground(colorScheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isSelected ? Color.clear : AppTheme.inputFieldBorderColor(colorScheme), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

struct ToggleRow: View {
    let icon: String
    let title: String
    let subtitle: String
    var tintColor: Color? = nil
    @Binding var isOn: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(tintColor ?? AppTheme.adaptiveAccentColor(colorScheme))
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .medium, design: .default))
                    .foregroundColor(AppTheme.textColor(colorScheme))

                Text(subtitle)
                    .font(.system(size: 13, weight: .regular, design: .default))
                    .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                    .opacity(0.70)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .toggleStyle(SwitchToggleStyle(tint: tintColor ?? AppTheme.adaptiveAccentColor(colorScheme)))
        }
        .padding(.horizontal, 4)
    }
}

struct MessageBanner: View {
    let message: String
    let isError: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(isError ? AppTheme.errorColor(colorScheme) : AppTheme.successColor(colorScheme))

            Text(message)
                .font(.system(size: 14, weight: .semibold, design: .default))
                .foregroundColor(isError ? AppTheme.errorColor(colorScheme) : AppTheme.successColor(colorScheme))

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill((isError ? AppTheme.errorColor(colorScheme) : AppTheme.successColor(colorScheme)).opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke((isError ? AppTheme.errorColor(colorScheme) : AppTheme.successColor(colorScheme)).opacity(0.30), lineWidth: 1)
        )
    }
}

struct AgnesAPIKeyInputSheet: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject var viewModel: AppViewModel
    @State private var apiKey = ""
    @State private var hasExistingKey = false
    @State private var savedAPIKeyPreview = ""

    private func maskAPIKey(_ key: String) -> String {
        guard key.count > 8 else { return "***" }
        let prefix = String(key.prefix(5))
        let suffix = String(key.suffix(4))
        return "\(prefix)***...\(suffix)"
    }

    var body: some View {
        NavigationStack {
            ScreenBackground {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Agnes AI API Key")
                                .font(.system(size: 28, weight: .bold, design: .default))
                                .foregroundColor(AppTheme.textColor(colorScheme))

                            Text("用于为图片消息启用 Agnes 云端图像理解")
                                .font(.system(size: 15, weight: .regular, design: .default))
                                .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                                .opacity(0.80)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)

                        ModernCard {
                            VStack(spacing: 20) {
                                if hasExistingKey && apiKey.isEmpty {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text("已保存的 Agnes Key")
                                            .font(.system(size: 14, weight: .semibold, design: .default))
                                            .foregroundColor(AppTheme.secondaryTextColor(colorScheme))

                                        HStack(spacing: 12) {
                                            Text(savedAPIKeyPreview)
                                                .font(.system(size: 14, weight: .regular, design: .monospaced))
                                                .foregroundColor(AppTheme.textColor(colorScheme))

                                            Spacer()

                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 18, weight: .semibold))
                                                .foregroundColor(AppTheme.successColor(colorScheme))
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 12)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .fill(AppTheme.successColor(colorScheme).opacity(0.08))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .stroke(AppTheme.successColor(colorScheme).opacity(0.20), lineWidth: 1)
                                        )
                                    }
                                }

                                VStack(alignment: .leading, spacing: 12) {
                                    Text(hasExistingKey ? "替换 Agnes Key" : "Agnes AI API Key")
                                        .font(.system(size: 14, weight: .semibold, design: .default))
                                        .foregroundColor(AppTheme.secondaryTextColor(colorScheme))

                                    SecureField("输入你的 Agnes API Key", text: $apiKey)
                                        .font(.system(size: 16, weight: .regular, design: .default))
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 14)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .fill(AppTheme.inputFieldBackground(colorScheme))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .stroke(AppTheme.inputFieldBorderColor(colorScheme), lineWidth: 1)
                                        )
                                }

                                VStack(spacing: 12) {
                                    PrimaryButton(
                                        title: hasExistingKey ? "保存更新" : "保存",
                                        disabled: apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ) {
                                        saveAPIKey()
                                    }

                                    HStack(spacing: 12) {
                                        SecondaryButton(title: "测试连接", disabled: false) {
                                            testConnection()
                                        }

                                        if hasExistingKey {
                                            SecondaryButton(title: "删除", disabled: false) {
                                                deleteAPIKey()
                                            }
                                            SecondaryButton(title: "取消", disabled: false) {
                                                apiKey = ""
                                            }
                                        } else {
                                            SecondaryButton(title: "取消", disabled: false) {
                                                dismiss()
                                            }
                                        }
                                    }
                                }
                                .padding(.top, 8)
                            }
                        }
                        .padding(.horizontal, 20)

                        Spacer(minLength: 20)
                    }
                    .padding(.vertical, 20)
                }
                .scrollDismissesKeyboard(.interactively)
                .dismissKeyboardOnTap()
            }
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if let key = await viewModel.retrieveAgnesAPIKey(), !key.isEmpty {
                    hasExistingKey = true
                    savedAPIKeyPreview = maskAPIKey(key)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                    }
                }
            }
        }
    }

    private func saveAPIKey() {
        Task {
            await viewModel.saveAgnesAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            dismiss()
        }
    }

    private func deleteAPIKey() {
        Task {
            await viewModel.deleteAgnesAPIKey()
            await MainActor.run {
                hasExistingKey = false
                apiKey = ""
                savedAPIKeyPreview = ""
            }
        }
    }

    private func testConnection() {
        Task {
            do {
                let success = try await viewModel.testAgnesConnection()
                await MainActor.run {
                    let message = success ? "Agnes 连接测试成功" : "Agnes 连接测试失败"
                    print(message)
                }
            } catch {
                await MainActor.run {
                    print("Agnes 连接测试失败：\(error.localizedDescription)")
                }
            }
        }
    }
}
