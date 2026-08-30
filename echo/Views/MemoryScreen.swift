import SwiftUI

/// Unified memory hub: **关于她** (objective facts) + **日记** (character POV / relationship feel).
struct MemoryScreen: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) var dismiss

    @State private var selectedTab: MemoryHubTab = .aboutHer
    @State private var snapshot: UserFacingMemorySnapshot = .empty
    @State private var isLoadingFacts = true
    @State private var isBusy = false
    @State private var pendingClear: ClearTarget?
    @State private var statusMessage: String?

    /// Forwarded diary chrome actions (calendar / debug) while on the diary tab.
    @State private var diaryToolbar = DiaryEmbeddedToolbarState()

    private enum MemoryHubTab: String, CaseIterable, Identifiable {
        case aboutHer
        case diary

        var id: String { rawValue }

        var title: String {
            switch self {
            case .aboutHer: return "关于她"
            case .diary: return "日记"
            }
        }
    }

    private enum ClearTarget: Identifiable {
        case factsSummary
        case userProfile
        case allFacts

        var id: String {
            switch self {
            case .factsSummary: return "factsSummary"
            case .userProfile: return "userProfile"
            case .allFacts: return "allFacts"
            }
        }

        var title: String {
            switch self {
            case .factsSummary: return "删除关于她的事实摘要？"
            case .userProfile: return "删除提取的偏好档案？"
            case .allFacts: return "清空「关于她」？"
            }
        }

        var message: String {
            switch self {
            case .factsSummary:
                return "会清空系统归纳的客观事实摘要（喜好、习惯、承诺等）。聊天记录和日记不会删；之后聊得足够多仍可能重新生成。"
            case .userProfile:
                return "会清空从对话里自动提取的偏好/事实条目。不会改动你在「我的」页手动填写的档案。"
            case .allFacts:
                return "会清空事实摘要和自动提取的偏好档案。聊天记录与日记不受影响。"
            }
        }
    }

    private var characterName: String {
        viewModel.character.name
    }

    private var aboutHerIsEmpty: Bool {
        !snapshot.hasLongTermSummary && !snapshot.hasExtractedUserProfile
    }

    var body: some View {
        NavigationStack {
            ScreenBackground {
                VStack(spacing: 0) {
                    tabPicker
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 12)

                    Group {
                        switch selectedTab {
                        case .aboutHer:
                            aboutHerContent
                        case .diary:
                            DiaryScreen(viewModel: viewModel, presentation: .embedded(toolbar: $diaryToolbar))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
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

                if selectedTab == .aboutHer {
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: { Task { await reloadFacts() } }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .disabled(isBusy || isLoadingFacts)
                        .accessibilityLabel("刷新关于她")
                    }
                } else {
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: { diaryToolbar.onOpenDatePicker?() }) {
                            if diaryToolbar.isGeneratingForSelectedDay {
                                ProgressView()
                            } else {
                                Image(systemName: "calendar.badge.plus")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                        }
                        .disabled(diaryToolbar.isBusy)
                        .accessibilityLabel("按日期补写日记")
                    }
                    if viewModel.appSettings.debugModeEnabled {
                        ToolbarItem(placement: .primaryAction) {
                            Button(action: { diaryToolbar.onGenerateToday?() }) {
                                if diaryToolbar.isGeneratingToday {
                                    ProgressView()
                                } else {
                                    Image(systemName: "square.and.pencil")
                                        .font(.system(size: 16, weight: .semibold))
                                }
                            }
                            .disabled(diaryToolbar.isBusy)
                            .accessibilityLabel("调试：生成今天日记")
                        }
                    }
                }
            }
            .task { await reloadFacts() }
            .confirmationDialog(
                pendingClear?.title ?? "",
                isPresented: Binding(
                    get: { pendingClear != nil },
                    set: { if !$0 { pendingClear = nil } }
                ),
                presenting: pendingClear
            ) { target in
                Button("删除", role: .destructive) {
                    Task { await performClear(target) }
                }
                Button("取消", role: .cancel) { pendingClear = nil }
            } message: { target in
                Text(target.message)
            }
            .overlay(alignment: .bottom) {
                if let statusMessage {
                    Text(statusMessage)
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .foregroundColor(AppTheme.textColor(colorScheme))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            Capsule(style: .continuous)
                                .fill(AppTheme.surfaceColor(colorScheme))
                                .shadow(color: AppTheme.cardShadowColor(colorScheme), radius: 8, y: 2)
                        )
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: statusMessage)
        }
    }

    private var tabPicker: some View {
        Picker("记忆分区", selection: $selectedTab) {
            ForEach(MemoryHubTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - 关于她

    private var aboutHerContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 16) {
                aboutHerHeader

                if isLoadingFacts {
                    ProgressView()
                        .padding(.top, 40)
                } else if aboutHerIsEmpty {
                    aboutHerEmptyState
                } else {
                    factsSummaryCard
                    extractedProfileCard
                    clearAllFactsButton
                }

                aboutHerFootnote
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
        }
    }

    private var aboutHerHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("关于她")
                .font(.system(size: 22, weight: .bold, design: .default))
                .foregroundColor(AppTheme.textColor(colorScheme))

            Text("系统从聊天里归纳的客观事实：喜好、习惯、承诺等。聊得足够多才会生成；和「\(characterName)的日记」不同，这里不写关系心情。")
                .font(.system(size: 13, weight: .regular, design: .default))
                .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                .opacity(0.70)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var aboutHerEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.text.rectangle")
                .font(.system(size: 32, weight: .regular))
                .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                .opacity(0.5)

            Text("还没有关于她的事实摘要")
                .font(.system(size: 15, weight: .semibold, design: .default))
                .foregroundColor(AppTheme.textColor(colorScheme))

            Text(emptyFactsDetail)
                .font(.system(size: 13, weight: .regular, design: .default))
                .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                .opacity(0.70)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var emptyFactsDetail: String {
        if snapshot.totalMessagesProcessed > 0 {
            return "已累计处理约 \(snapshot.totalMessagesProcessed) 条消息，但还没触发事实摘要（需要聊得更长一些）。相处感受请看「日记」。"
        }
        return "继续聊天后，系统会在这里记下她喜欢什么、常做什么。相处感受请看「日记」。"
    }

    private var factsSummaryCard: some View {
        memoryCard(
            title: "事实摘要",
            subtitle: updatedLabel(snapshot.longTermLastUpdated, empty: "尚未生成"),
            bodyText: snapshot.hasLongTermSummary
                ? snapshot.longTermSummary
                : "暂无内容。继续聊天后会自动归纳喜好、习惯和承诺。",
            meta: snapshot.totalMessagesProcessed > 0
                ? "累计处理约 \(snapshot.totalMessagesProcessed) 条消息 · 待摘要 \(snapshot.unsummarizedMessageCount) 条"
                : nil,
            deleteEnabled: snapshot.hasLongTermSummary,
            onDelete: { pendingClear = .factsSummary }
        )
    }

    private var extractedProfileCard: some View {
        memoryCard(
            title: "提取的偏好",
            subtitle: "自动写入对话上下文，与「我的」页手动档案分开",
            bodyText: snapshot.hasExtractedUserProfile
                ? formattedProfile(snapshot.extractedUserProfile)
                : "暂无自动提取的偏好或事实条目。",
            meta: nil,
            deleteEnabled: snapshot.hasExtractedUserProfile,
            onDelete: { pendingClear = .userProfile }
        )
    }

    private var clearAllFactsButton: some View {
        Button(role: .destructive) {
            pendingClear = .allFacts
        } label: {
            HStack {
                Image(systemName: "trash")
                Text("清空关于她")
                    .font(.system(size: 15, weight: .semibold, design: .default))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .disabled(isBusy || aboutHerIsEmpty)
        .buttonStyle(.bordered)
        .tint(AppTheme.warningColor(colorScheme))
    }

    private var aboutHerFootnote: some View {
        Text("说明：删这里不会删聊天气泡或日记。日记在另一栏，记录的是\(characterName)的心情与相处感受。")
            .font(.system(size: 12, weight: .regular, design: .default))
            .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
            .opacity(0.65)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }

    private func memoryCard(
        title: String,
        subtitle: String,
        bodyText: String,
        meta: String?,
        deleteEnabled: Bool,
        onDelete: @escaping () -> Void
    ) -> some View {
        ModernCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.system(size: 16, weight: .semibold, design: .default))
                            .foregroundColor(AppTheme.textColor(colorScheme))
                        Text(subtitle)
                            .font(.system(size: 12, weight: .regular, design: .default))
                            .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                            .opacity(0.75)
                    }
                    Spacer()
                    if deleteEnabled {
                        Button(role: .destructive, action: onDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .disabled(isBusy)
                        .accessibilityLabel("删除\(title)")
                    }
                }

                Text(bodyText)
                    .font(.system(size: 15, weight: .regular, design: .default))
                    .foregroundColor(AppTheme.textColor(colorScheme))
                    .opacity(deleteEnabled ? 1 : 0.55)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if let meta {
                    Text(meta)
                        .font(.system(size: 12, weight: .regular, design: .default))
                        .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                        .opacity(0.7)
                }
            }
        }
    }

    private func reloadFacts() async {
        isLoadingFacts = true
        snapshot = await viewModel.loadUserFacingMemory()
        isLoadingFacts = false
    }

    private func performClear(_ target: ClearTarget) async {
        pendingClear = nil
        isBusy = true
        switch target {
        case .factsSummary:
            await viewModel.clearLongTermSummary()
            statusMessage = "已删除事实摘要"
        case .userProfile:
            await viewModel.clearExtractedUserProfileMemory()
            statusMessage = "已删除提取的偏好"
        case .allFacts:
            await viewModel.clearLongTermSummary()
            await viewModel.clearExtractedUserProfileMemory()
            statusMessage = "已清空关于她"
        }
        await reloadFacts()
        isBusy = false
        try? await Task.sleep(nanoseconds: 1_800_000_000)
        if statusMessage != nil {
            statusMessage = nil
        }
    }

    private func updatedLabel(_ date: Date?, empty: String) -> String {
        guard let date else { return empty }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "更新于 \(formatter.string(from: date))"
    }

    private func formattedProfile(_ profile: [String: String]) -> String {
        let keyMap: [String: String] = [
            "name": "姓名",
            "gender": "性别",
            "likes": "喜好",
            "dislikes": "厌恶",
            "important_dates": "重要日期",
            "personality": "性格",
            "goals": "目标"
        ]
        return profile
            .sorted { $0.key < $1.key }
            .map { key, value in
                let label = keyMap[key] ?? key
                return "\(label)：\(value)"
            }
            .joined(separator: "\n")
    }
}

// MARK: - Diary embedding bridge

/// Parent (MemoryScreen) owns nav chrome; diary content publishes busy flags + actions here.
struct DiaryEmbeddedToolbarState {
    var isBusy = false
    var isGeneratingToday = false
    var isGeneratingForSelectedDay = false
    var onOpenDatePicker: (() -> Void)?
    var onGenerateToday: (() -> Void)?
}

#Preview {
    MemoryScreen(viewModel: PreviewFactory.appViewModel())
}
