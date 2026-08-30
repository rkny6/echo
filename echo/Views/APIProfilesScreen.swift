import SwiftUI
import SwiftData

/// Screen for managing saved API profiles
struct APIProfilesScreen: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) var dismiss
    @State private var profiles: [APIProfileSnapshot] = []
    @State private var showingNewProfileSheet = false
    @State private var selectedProfile: APIProfileSnapshot?
    @State private var showingEditSheet = false
    @State private var savedMessage = ""

    var body: some View {
        ScreenBackground {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 24) {
                    // Header
                    VStack(alignment: .leading, spacing: 8) {
                        Text("API 配置文件")
                            .font(.system(size: 28, weight: .bold, design: .default))
                            .foregroundColor(AppTheme.textColor(colorScheme))

                        Text("保存和管理多个 API 配置")
                            .font(.system(size: 14, weight: .regular, design: .default))
                            .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                            .opacity(0.80)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                    // Add Profile Button
                    VStack(spacing: 12) {
                        PrimaryButton(
                            title: "新建配置文件",
                            disabled: false
                        ) {
                            showingNewProfileSheet = true
                        }
                    }
                    .padding(.horizontal, 20)

                    // Profiles List
                    if profiles.isEmpty {
                        ModernCard {
                            VStack(spacing: 12) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 40, weight: .semibold))
                                    .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                                    .opacity(0.50)

                                Text("没有保存的配置文件")
                                    .font(.system(size: 16, weight: .semibold, design: .default))
                                    .foregroundColor(AppTheme.textColor(colorScheme))

                                Text("创建第一个配置文件来快速切换 API 设置")
                                    .font(.system(size: 13, weight: .regular, design: .default))
                                    .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                                    .multilineTextAlignment(.center)
                                    .opacity(0.70)
                            }
                            .padding(.vertical, 40)
                            .frame(maxWidth: .infinity)
                        }
                        .padding(.horizontal, 20)
                    } else {
                        VStack(spacing: 12) {
                            ForEach(profiles) { profile in
                                ModernCard {
                                    VStack(spacing: 12) {
                                        HStack(spacing: 12) {
                                            VStack(alignment: .leading, spacing: 6) {
                                                Text(profile.name)
                                                    .font(.system(size: 16, weight: .semibold, design: .default))
                                                    .foregroundColor(AppTheme.textColor(colorScheme))

                                                HStack(spacing: 8) {
                                                    Text("自定义 API")
                                                        .font(.system(size: 12, weight: .regular, design: .default))
                                                        .foregroundColor(AppTheme.adaptiveAccentColor(colorScheme))

                                                    Text("•")
                                                        .foregroundColor(AppTheme.secondaryTextColor(colorScheme))

                                                    Text(profile.model)
                                                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                                                        .foregroundColor(AppTheme.secondaryTextColor(colorScheme))

                                                    Text("•")
                                                        .foregroundColor(AppTheme.secondaryTextColor(colorScheme))

                                                    Text(profile.endpointMode.displayName)
                                                        .font(.system(size: 12, weight: .regular, design: .default))
                                                        .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                                                }
                                            }

                                            Spacer()

                                            VStack(spacing: 8) {
                                                Button(action: { applyProfile(profile) }) {
                                                    Image(systemName: "checkmark.circle.fill")
                                                        .font(.system(size: 16, weight: .semibold))
                                                        .foregroundColor(AppTheme.adaptiveAccentColor(colorScheme))
                                                }

                                                Menu {
                                                    Button("编辑", action: { selectedProfile = profile; showingEditSheet = true })
                                                    Button("删除", role: .destructive, action: { deleteProfile(profile) })
                                                } label: {
                                                    Image(systemName: "ellipsis")
                                                        .font(.system(size: 16, weight: .semibold))
                                                        .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                                                }
                                            }
                                        }

                                        MinimalDivider()
                                            .padding(.vertical, 8)

                                        VStack(alignment: .leading, spacing: 4) {
                                            if let baseURL = profile.baseURL, !baseURL.isEmpty {
                                                HStack(spacing: 8) {
                                                    Text("Base URL:")
                                                        .font(.system(size: 11, weight: .semibold, design: .default))
                                                        .foregroundColor(AppTheme.secondaryTextColor(colorScheme))

                                                    Text(baseURL)
                                                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                                                        .foregroundColor(AppTheme.tertiaryTextColor(colorScheme))
                                                        .lineLimit(1)
                                                }
                                            }

                                            HStack(spacing: 8) {
                                                Text("温度:")
                                                    .font(.system(size: 11, weight: .semibold, design: .default))
                                                    .foregroundColor(AppTheme.secondaryTextColor(colorScheme))

                                                Text(String(format: "%.1f", profile.temperature))
                                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                                    .foregroundColor(AppTheme.tertiaryTextColor(colorScheme))

                                                Spacer()

                                                Text("最大令牌:")
                                                    .font(.system(size: 11, weight: .semibold, design: .default))
                                                    .foregroundColor(AppTheme.secondaryTextColor(colorScheme))

                                                Text("\(profile.maxTokens)")
                                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                                    .foregroundColor(AppTheme.tertiaryTextColor(colorScheme))
                                            }
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .fill(AppTheme.inputFieldBackground(colorScheme))
                                        )
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }

                    // Success Message
                    if !savedMessage.isEmpty {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(AppTheme.successColor(colorScheme))

                            Text(savedMessage)
                                .font(.system(size: 14, weight: .semibold, design: .default))
                                .foregroundColor(AppTheme.successColor(colorScheme))

                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(AppTheme.successColor(colorScheme).opacity(0.10))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(AppTheme.successColor(colorScheme).opacity(0.30), lineWidth: 1)
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
            Task {
                profiles = await viewModel.loadAPIProfiles()
            }
        }
        .sheet(isPresented: $showingNewProfileSheet) {
            NewAPIProfileSheet(viewModel: viewModel) { newProfile in
                profiles.insert(newProfile, at: 0)
                showingNewProfileSheet = false
                withAnimation(.easeInOut(duration: 0.3)) {
                    savedMessage = "配置文件已保存"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            savedMessage = ""
                        }
                    }
                }
            }
        }
        .sheet(item: $selectedProfile) { profile in
            EditAPIProfileSheet(viewModel: viewModel, profile: profile) {
                Task { profiles = await viewModel.loadAPIProfiles() }
                showingEditSheet = false
                withAnimation(.easeInOut(duration: 0.3)) {
                    savedMessage = "配置文件已更新"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            savedMessage = ""
                        }
                    }
                }
            }
        }
    }

    private func applyProfile(_ profile: APIProfileSnapshot) {
        Task {
            let didApplyKey = await viewModel.applyProfile(profile)
            withAnimation(.easeInOut(duration: 0.3)) {
                savedMessage = didApplyKey
                    ? "已应用配置文件: \(profile.name)"
                    : "已应用配置文件: \(profile.name)（该配置未保存 Key，已清除当前 Key，请重新填写）"
                DispatchQueue.main.asyncAfter(deadline: .now() + (didApplyKey ? 2 : 3.5)) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        savedMessage = ""
                    }
                }
            }
        }
    }

    private func deleteProfile(_ profile: APIProfileSnapshot) {
        Task {
            await viewModel.deleteProfile(profile)
            profiles.removeAll { $0.id == profile.id }
            withAnimation(.easeInOut(duration: 0.3)) {
                savedMessage = "配置文件已删除"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        savedMessage = ""
                    }
                }
            }
        }
    }
}

// MARK: - New Profile Sheet
struct NewAPIProfileSheet: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject var viewModel: AppViewModel
    @State private var name = ""
    @State private var baseURL: String
    @State private var model: String
    @State private var endpointMode: LLMAPIEndpointMode
    @State private var temperature: Double
    @State private var maxTokens: Int
    @State private var apiKey = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    let onSave: (APIProfileSnapshot) -> Void

    /// Pre-fill from the current Settings screen values as a convenient
    /// starting point — still fully editable, unlike before where these
    /// values were silently snapshotted with no way to change them here.
    init(viewModel: AppViewModel, onSave: @escaping (APIProfileSnapshot) -> Void) {
        self.viewModel = viewModel
        self.onSave = onSave
        let current = viewModel.appSettings
        _baseURL = State(initialValue: current.customBaseURL ?? "")
        _model = State(initialValue: current.selectedModel)
        _endpointMode = State(initialValue: current.endpointMode)
        _temperature = State(initialValue: current.temperature)
        _maxTokens = State(initialValue: current.maxTokens)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScreenBackground {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("新建配置文件")
                                .font(.system(size: 24, weight: .bold, design: .default))
                                .foregroundColor(AppTheme.textColor(colorScheme))

                            Text("每个配置文件都有自己独立的 API Key，切换配置文件时会一并切换 Key")
                                .font(.system(size: 13, weight: .regular, design: .default))
                                .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                                .opacity(0.70)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        ModernCard {
                            VStack(spacing: 16) {
                                APIProfileFormField(title: "名称", placeholder: "例如: GPT-4 生产环境", text: $name, colorScheme: colorScheme)

                                APIProfileFormField(title: "Base URL (可选)", placeholder: "https://api.example.com/v1", text: $baseURL, colorScheme: colorScheme)

                                APIProfileFormField(title: "模型", placeholder: "模型名称", text: $model, colorScheme: colorScheme)

                                APIProfileEndpointModePicker(endpointMode: $endpointMode, colorScheme: colorScheme)

                                APIProfileTemperatureSlider(temperature: $temperature, colorScheme: colorScheme)

                                APIProfileMaxTokensField(maxTokens: $maxTokens, colorScheme: colorScheme)

                                VStack(alignment: .leading, spacing: 12) {
                                    Text("API Key（可选，留空则不设置）")
                                        .font(.system(size: 14, weight: .semibold, design: .default))
                                        .foregroundColor(AppTheme.secondaryTextColor(colorScheme))

                                    SecureField("输入这个配置专用的 API Key", text: $apiKey)
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

                                if let errorMessage {
                                    Text(errorMessage)
                                        .font(.system(size: 13, weight: .regular, design: .default))
                                        .foregroundColor(AppTheme.errorColor(colorScheme))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }

                                VStack(spacing: 12) {
                                    PrimaryButton(
                                        title: isSaving ? "保存中..." : "保存配置文件",
                                        disabled: !isValid || isSaving
                                    ) {
                                        saveProfile()
                                    }

                                    SecondaryButton(
                                        title: "取消",
                                        disabled: isSaving
                                    ) {
                                        dismiss()
                                    }
                                }
                                .padding(.top, 8)
                            }
                        }

                        Spacer()
                    }
                    .padding(20)
                }
                .scrollDismissesKeyboard(.interactively)
                .dismissKeyboardOnTap()
            }
            .navigationBarTitleDisplayMode(.inline)
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

    private func saveProfile() {
        isSaving = true
        errorMessage = nil
        Task {
            let created = await viewModel.createProfile(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : baseURL,
                model: model.trimmingCharacters(in: .whitespacesAndNewlines),
                endpointMode: endpointMode,
                temperature: temperature,
                maxTokens: maxTokens,
                apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            isSaving = false
            if let created {
                onSave(created)
            } else {
                errorMessage = "保存失败，请重试"
            }
        }
    }
}

// MARK: - Edit Profile Sheet
struct EditAPIProfileSheet: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject var viewModel: AppViewModel
    let profile: APIProfileSnapshot
    let onSave: () -> Void
    
    @State private var name: String = ""
    @State private var baseURL: String = ""
    @State private var model: String = ""
    @State private var endpointMode: LLMAPIEndpointMode = .chatCompletions
    @State private var temperature: Double = 0.7
    @State private var maxTokens: Int = 2000
    @State private var apiKey: String = ""
    @State private var hasExistingKey = false
    @State private var savedAPIKeyPreview = ""
    @State private var isSaving = false

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
                    VStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("编辑配置文件")
                                .font(.system(size: 24, weight: .bold, design: .default))
                                .foregroundColor(AppTheme.textColor(colorScheme))

                            Text("修改 API 配置设置")
                                .font(.system(size: 13, weight: .regular, design: .default))
                                .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                                .opacity(0.70)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        ModernCard {
                            VStack(spacing: 16) {
                                APIProfileFormField(title: "名称", placeholder: "配置文件名称", text: $name, colorScheme: colorScheme)

                                APIProfileFormField(title: "Base URL (可选)", placeholder: "https://api.example.com/v1", text: $baseURL, colorScheme: colorScheme)

                                APIProfileFormField(title: "模型", placeholder: "模型名称", text: $model, colorScheme: colorScheme)

                                APIProfileEndpointModePicker(endpointMode: $endpointMode, colorScheme: colorScheme)

                                APIProfileTemperatureSlider(temperature: $temperature, colorScheme: colorScheme)

                                APIProfileMaxTokensField(maxTokens: $maxTokens, colorScheme: colorScheme)

                                VStack(alignment: .leading, spacing: 12) {
                                    Text("API Key")
                                        .font(.system(size: 14, weight: .semibold, design: .default))
                                        .foregroundColor(AppTheme.secondaryTextColor(colorScheme))

                                    if hasExistingKey && apiKey.isEmpty {
                                        HStack {
                                            Text(savedAPIKeyPreview)
                                                .font(.system(size: 14, weight: .regular, design: .monospaced))
                                                .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                                            Spacer()
                                            Text("已设置")
                                                .font(.system(size: 12, weight: .semibold, design: .default))
                                                .foregroundColor(AppTheme.successColor(colorScheme))
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 14)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .fill(AppTheme.inputFieldBackground(colorScheme))
                                        )
                                    }

                                    SecureField(
                                        hasExistingKey ? "输入新 Key 以替换（留空则保持不变）" : "输入这个配置专用的 API Key",
                                        text: $apiKey
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
                                }

                                VStack(spacing: 12) {
                                    PrimaryButton(
                                        title: isSaving ? "保存中..." : "保存更改",
                                        disabled: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving
                                    ) {
                                        updateProfile()
                                    }

                                    SecondaryButton(
                                        title: "取消",
                                        disabled: isSaving
                                    ) {
                                        dismiss()
                                    }
                                }
                                .padding(.top, 8)
                            }
                        }

                        Spacer()
                    }
                    .padding(20)
                }
                .scrollDismissesKeyboard(.interactively)
                .dismissKeyboardOnTap()
            }
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                name = profile.name
                baseURL = profile.baseURL ?? ""
                model = profile.model
                endpointMode = profile.endpointMode
                temperature = profile.temperature
                maxTokens = profile.maxTokens
                Task {
                    if let key = await viewModel.retrieveProfileAPIKey(for: profile), !key.isEmpty {
                        hasExistingKey = true
                        savedAPIKeyPreview = maskAPIKey(key)
                    }
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

    private func updateProfile() {
        isSaving = true
        Task {
            await viewModel.updateProfile(
                profile,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                baseURL: baseURL.isEmpty ? nil : baseURL,
                model: model,
                endpointMode: endpointMode,
                temperature: temperature,
                maxTokens: maxTokens,
                apiKey: apiKey.isEmpty ? nil : apiKey
            )
            isSaving = false
            onSave()
        }
    }
}

// MARK: - Shared form components

private struct APIProfileFormField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let colorScheme: ColorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .default))
                .foregroundColor(AppTheme.secondaryTextColor(colorScheme))

            TextField(placeholder, text: $text)
                .font(.system(size: 16, weight: .regular, design: .default))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
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
}

private struct APIProfileEndpointModePicker: View {
    @Binding var endpointMode: LLMAPIEndpointMode
    let colorScheme: ColorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("接口模式")
                .font(.system(size: 14, weight: .semibold, design: .default))
                .foregroundColor(AppTheme.secondaryTextColor(colorScheme))

            Menu {
                ForEach(LLMAPIEndpointMode.allCases, id: \.self) { mode in
                    Button {
                        endpointMode = mode
                    } label: {
                        HStack {
                            Text(mode.displayName)
                            if mode == endpointMode {
                                Image(systemName: "checkmark")
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
    }
}

private struct APIProfileTemperatureSlider: View {
    @Binding var temperature: Double
    let colorScheme: ColorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("温度参数")
                    .font(.system(size: 14, weight: .semibold, design: .default))
                    .foregroundColor(AppTheme.secondaryTextColor(colorScheme))

                Spacer()

                Text(String(format: "%.1f", temperature))
                    .font(.system(size: 14, weight: .semibold, design: .default))
                    .foregroundColor(AppTheme.adaptiveAccentColor(colorScheme))
            }

            Slider(value: $temperature, in: 0...1, step: 0.1)
                .accentColor(AppTheme.adaptiveAccentColor(colorScheme))
        }
    }
}

private struct APIProfileMaxTokensField: View {
    @Binding var maxTokens: Int
    let colorScheme: ColorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("最大令牌数")
                .font(.system(size: 14, weight: .semibold, design: .default))
                .foregroundColor(AppTheme.secondaryTextColor(colorScheme))

            TextField("2000", value: $maxTokens, format: .number)
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
        }
    }
}

#Preview {
    APIProfilesScreen(viewModel: PreviewFactory.appViewModel())
}
