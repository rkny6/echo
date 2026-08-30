import SwiftUI
import SwiftData

/// Character profile editing screen with modern design
struct CharacterProfileScreen: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.colorScheme) var colorScheme
    @State private var name: String
    @State private var avatarName: String
    @State private var personality: String
    @State private var background: String
    @State private var speakingStyle: String
    @State private var relationship: RelationshipType
    @State private var customRelationship: String
    @State private var isSaving = false
    @State private var savedMessage = ""
    @State private var isSaved = false
    @State private var showingMemory = false

    private var hasChanges: Bool {
        name != viewModel.character.name ||
        avatarName != viewModel.character.avatarName ||
        personality != viewModel.character.personality ||
        background != viewModel.character.background ||
        speakingStyle != viewModel.character.speakingStyle ||
        relationship != (viewModel.character.relationship ?? .companion) ||
        customRelationship != (viewModel.character.customRelationshipDescription ?? "")
    }

    private var saveButtonTitle: String {
        isSaved && !hasChanges ? "已保存" : "保存角色档案"
    }

    private func clearSaveState() {
        if isSaved || !savedMessage.isEmpty {
            isSaved = false
            savedMessage = ""
        }
    }

    var body: some View {
        ScreenBackground {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 24) {
                    // Header Section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("角色")
                            .font(.system(size: 32, weight: .bold, design: .default))
                            .foregroundColor(AppTheme.textColor(colorScheme))

                        Text("定义你的助手身份、叙事风格和交流方式")
                            .font(.system(size: 15, weight: .regular, design: .default))
                            .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                            .opacity(0.80)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                    Button(action: { showingMemory = true }) {
                        HStack(spacing: 10) {
                            Image(systemName: "brain.head.profile")
                                .font(.system(size: 14, weight: .semibold))

                            Text("查看记忆")
                                .font(.system(size: 16, weight: .semibold, design: .default))

                            Spacer()

                            Text("关于她 · 日记")
                                .font(.system(size: 13, weight: .regular, design: .default))
                                .opacity(0.70)

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
                    .padding(.horizontal, 20)

                    // Form Content
                    VStack(spacing: 20) {
                        ModernCard {
                            VStack(spacing: 20) {
                                // Avatar Picker
                                VStack(spacing: 16) {
                                    AvatarPicker(
                                        avatarName: $avatarName,
                                        isUser: false,
                                        onAvatarChanged: { newName in
                                            clearSaveState()
                                        }
                                    )
                                    MinimalDivider()
                                        .padding(.vertical, 4)
                                }
                                
                                ProfileTextField(
                                    title: "角色名字",
                                    placeholder: "输入角色的名字",
                                    text: $name
                                )
                                .onChange(of: name) { _ in clearSaveState() }

                                ProfileTextEditor(
                                    title: "性格",
                                    prompt: "描述人格、关系和行为特征...",
                                    text: $personality,
                                    minHeight: 160
                                )
                                .onChange(of: personality) { _ in clearSaveState() }

                                ProfileTextEditor(
                                    title: "背景故事",
                                    prompt: "设置助手的背景故事和历史背景...",
                                    text: $background,
                                    minHeight: 140
                                )
                                .onChange(of: background) { _ in clearSaveState() }

                                VStack(alignment: .leading, spacing: 12) {
                                    Text("角色与用户的关系")
                                        .font(.system(size: 14, weight: .semibold, design: .default))
                                        .foregroundColor(AppTheme.secondaryTextColor(colorScheme))

                                    Picker("关系", selection: $relationship) {
                                        ForEach(RelationshipType.allCases, id: \.self) { type in
                                            Text(type.displayName).tag(type)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .font(.system(size: 16, weight: .regular, design: .default))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 14)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(AppTheme.inputFieldBackground(colorScheme))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(AppTheme.inputFieldBorderColor(colorScheme), lineWidth: 1)
                                    )
                                }
                                .onChange(of: relationship) { _ in clearSaveState() }

                                if relationship == .custom {
                                    ProfileTextField(
                                        title: "自定义关系描述",
                                        placeholder: "描述角色与用户的具体关系",
                                        text: $customRelationship
                                    )
                                    .onChange(of: customRelationship) { _ in clearSaveState() }
                                }

                                ProfileTextEditor(
                                    title: "说话方式",
                                    prompt: "描述讲话风格、节奏和语气特征...",
                                    text: $speakingStyle,
                                    minHeight: 140
                                )
                                .onChange(of: speakingStyle) { _ in clearSaveState() }

                                PrimaryButton(
                                    title: saveButtonTitle,
                                    disabled: isSaving || !hasChanges
                                ) {
                                    saveProfile()
                                }
                                .padding(.top, 8)
                            }
                        }
                    }
                    .padding(.horizontal, 20)

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
        .onChange(of: viewModel.character) { newValue in
            name = newValue.name
            avatarName = newValue.avatarName
            personality = newValue.personality
            background = newValue.background
            speakingStyle = newValue.speakingStyle
            relationship = newValue.relationship ?? .companion
            customRelationship = newValue.customRelationshipDescription ?? ""
            clearSaveState()
        }
        .sheet(isPresented: $showingMemory) {
            MemoryScreen(viewModel: viewModel)
        }
    }

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        _name = State(initialValue: viewModel.character.name)
        _avatarName = State(initialValue: viewModel.character.avatarName)
        _personality = State(initialValue: viewModel.character.personality)
        _background = State(initialValue: viewModel.character.background)
        _speakingStyle = State(initialValue: viewModel.character.speakingStyle)
        _relationship = State(initialValue: viewModel.character.relationship ?? .companion)
        _customRelationship = State(initialValue: viewModel.character.customRelationshipDescription ?? "")
    }

    private func saveProfile() {
        isSaving = true
        var draft = viewModel.character
        draft.name = name
        draft.avatarName = avatarName
        draft.personality = personality
        draft.background = background
        draft.speakingStyle = speakingStyle
        draft.relationship = relationship
        draft.customRelationshipDescription = relationship == .custom ? customRelationship : nil
        draft.updatedAt = Date()

        Task {
            await viewModel.updateCharacterProfile(draft)
            withAnimation(.easeInOut(duration: 0.3)) {
                savedMessage = "已保存"
                isSaved = true
            }
            isSaving = false

            // Auto-dismiss notification after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    savedMessage = ""
                }
            }
        }
    }
}

#Preview {
    CharacterProfileScreen(viewModel: PreviewFactory.appViewModel())
}
