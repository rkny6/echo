import SwiftUI
import SwiftData

/// User profile editing screen with modern design
struct UserProfileScreen: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.colorScheme) var colorScheme
    @State private var name: String
    @State private var avatarName: String
    @State private var personality: String
    @State private var background: String
    @State private var birthday: Date?
    @State private var showBirthdayPicker = false
    @State private var isSaving = false
    @State private var savedMessage = ""
    @State private var isSaved = false

    private var hasChanges: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        return trimmedName != viewModel.user.name ||
            avatarName != viewModel.user.avatarName ||
            personality != viewModel.user.personality ||
            background != (viewModel.user.background ?? "") ||
            birthday != viewModel.user.birthday
    }

    private var saveButtonTitle: String {
        isSaved && !hasChanges ? "已保存" : "保存信息"
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
                        Text("我的信息")
                            .font(.system(size: 32, weight: .bold, design: .default))
                            .foregroundColor(AppTheme.textColor(colorScheme))

                        Text("更新你的个人信息，帮助助手更好地理解你")
                            .font(.system(size: 15, weight: .regular, design: .default))
                            .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                            .opacity(0.80)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                    // Form Content
                    VStack(spacing: 20) {
                        ModernCard {
                            VStack(spacing: 20) {
                                // Avatar Picker
                                VStack(spacing: 16) {
                                    AvatarPicker(
                                        avatarName: $avatarName,
                                        isUser: true,
                                        onAvatarChanged: { newName in
                                            clearSaveState()
                                        }
                                    )
                                    MinimalDivider()
                                        .padding(.vertical, 4)
                                }
                                
                                ProfileTextField(
                                    title: "用户名",
                                    placeholder: "输入你的名字",
                                    text: $name
                                )
                                .onChange(of: name) { _ in clearSaveState() }

                                ProfileTextEditor(
                                    title: "性格特点",
                                    prompt: "描述你的个性、偏好和表达方式...",
                                    text: $personality,
                                    minHeight: 120
                                )
                                .onChange(of: personality) { _ in clearSaveState() }
                                
                                // 生日选择器
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("生日")
                                        .font(.system(size: 14, weight: .semibold, design: .default))
                                        .foregroundColor(AppTheme.textColor(colorScheme))
                                    
                                    Button(action: {
                                        showBirthdayPicker = true
                                    }) {
                                        HStack {
                                            Text(birthday.map { formatDate($0) } ?? "选择你的生日")
                                                .font(.system(size: 16, weight: .regular, design: .default))
                                                .foregroundColor(birthday != nil ? AppTheme.textColor(colorScheme) : AppTheme.secondaryTextColor(colorScheme))
                                            
                                            Spacer()
                                            
                                            Image(systemName: birthday != nil ? "calendar.circle.fill" : "calendar.circle")
                                                .font(.system(size: 20))
                                                .foregroundColor(AppTheme.adaptiveAccentColor(colorScheme))
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 14)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .fill(AppTheme.surfaceColor(colorScheme))
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                        .stroke(AppTheme.borderColor(colorScheme), lineWidth: 1)
                                                )
                                        )
                                    }
                                }
                                .onChange(of: birthday) { _ in clearSaveState() }

                                PrimaryButton(
                                    title: saveButtonTitle,
                                    disabled: isSaving || name.trimmingCharacters(in: .whitespaces).isEmpty || !hasChanges
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
        .onChange(of: viewModel.user) { newValue in
            name = newValue.name
            avatarName = newValue.avatarName
            personality = newValue.personality
            background = newValue.background ?? ""
            birthday = newValue.birthday
            clearSaveState()
        }
        .sheet(isPresented: $showBirthdayPicker) {
            BirthdayPickerView(
                selectedDate: $birthday,
                isPresented: $showBirthdayPicker
            )
        }
    }

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        _name = State(initialValue: viewModel.user.name)
        _avatarName = State(initialValue: viewModel.user.avatarName)
        _personality = State(initialValue: viewModel.user.personality)
        _background = State(initialValue: viewModel.user.background ?? "")
        _birthday = State(initialValue: viewModel.user.birthday)
    }
    
    // 日期格式化
    private func formatDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MM月dd日"   // 只显示月日，无年份
    formatter.locale = Locale(identifier: "zh_CN")
    return formatter.string(from: date)
}

    private func saveProfile() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        isSaving = true
        var draft = viewModel.user
        draft.name = trimmedName
        draft.avatarName = avatarName
        draft.personality = personality
        draft.background = background.isEmpty ? nil : background
        draft.birthday = birthday
        draft.updatedAt = Date()

        Task {
            await viewModel.updateUserProfile(draft)
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
    UserProfileScreen(viewModel: PreviewFactory.appViewModel())
}
