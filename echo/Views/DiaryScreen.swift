import SwiftUI

/// Lets the user browse the character's daily diary/朋友圈-style entries —
/// see DiaryService for how these get generated and later retrieved as
/// searchable memory.
///
/// Can open standalone (legacy sheet) or embedded inside MemoryScreen
/// under the「日记」tab.
struct DiaryScreen: View {
    enum Presentation {
        case standalone
        case embedded(toolbar: Binding<DiaryEmbeddedToolbarState>)
    }

    @ObservedObject var viewModel: AppViewModel
    var presentation: Presentation = .standalone

    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) var dismiss

    @State private var entries: [DiaryEntrySnapshot] = []
    @State private var isGenerating = false
    @State private var regeneratingEntryID: UUID?
    @State private var entryPendingDelete: DiaryEntrySnapshot?
    @State private var entryPendingRegenerate: DiaryEntrySnapshot?
    @State private var regenerateErrorMessage: String?
    @State private var showingDatePicker = false
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    /// When generating from the date picker (including deleted days with no card).
    @State private var isGeneratingForSelectedDay = false

    private var characterName: String {
        viewModel.character.name
    }

    private var isBusy: Bool {
        isGenerating || regeneratingEntryID != nil || isGeneratingForSelectedDay
    }

    private var isEmbedded: Bool {
        if case .embedded = presentation { return true }
        return false
    }

    private var earliestSelectableDay: Date {
        Calendar.current.date(byAdding: .year, value: -2, to: Date()) ?? Date.distantPast
    }

    private var latestSelectableDay: Date {
        Calendar.current.startOfDay(for: Date())
    }

    var body: some View {
        Group {
            if isEmbedded {
                diaryBody
            } else {
                NavigationStack {
                    ScreenBackground {
                        diaryBody
                    }
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { standaloneToolbar }
                }
            }
        }
        .task {
            await reload()
            publishEmbeddedToolbar()
        }
        .onChange(of: isBusy) { _ in publishEmbeddedToolbar() }
        .onChange(of: isGenerating) { _ in publishEmbeddedToolbar() }
        .onChange(of: isGeneratingForSelectedDay) { _ in publishEmbeddedToolbar() }
        .sheet(isPresented: $showingDatePicker) {
            datePickerSheet
        }
        .alert("删除这篇日记？", isPresented: Binding(
            get: { entryPendingDelete != nil },
            set: { if !$0 { entryPendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { entryPendingDelete = nil }
            Button("删除", role: .destructive) {
                if let entry = entryPendingDelete {
                    entryPendingDelete = nil
                    Task {
                        await viewModel.deleteDiaryEntry(entry)
                        await reload()
                    }
                }
            }
        }
        .alert("重新生成这篇日记？", isPresented: Binding(
            get: { entryPendingRegenerate != nil },
            set: { if !$0 { entryPendingRegenerate = nil } }
        )) {
            Button("取消", role: .cancel) { entryPendingRegenerate = nil }
            Button("重新生成") {
                if let entry = entryPendingRegenerate {
                    entryPendingRegenerate = nil
                    regenerate(day: entry.date, entryID: entry.id)
                }
            }
        } message: {
            Text("会用当天的聊天记录重新写一篇，当前内容会被替换。")
        }
        .alert(
            "生成失败",
            isPresented: Binding(
                get: { regenerateErrorMessage != nil },
                set: { if !$0 { regenerateErrorMessage = nil } }
            )
        ) {
            Button("好的", role: .cancel) { regenerateErrorMessage = nil }
        } message: {
            Text(regenerateErrorMessage ?? "")
        }
    }

    private var diaryBody: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(isEmbedded ? "日记" : "\(characterName)的日记")
                        .font(.system(size: isEmbedded ? 22 : 24, weight: .bold, design: .default))
                        .foregroundColor(AppTheme.textColor(colorScheme))

                    Text(diarySubtitle)
                        .font(.system(size: 13, weight: .regular, design: .default))
                        .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                        .opacity(0.70)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, isEmbedded ? 0 : 12)

                if entries.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 14) {
                        ForEach(entries) { entry in
                            DiaryEntryCard(
                                entry: entry,
                                colorScheme: colorScheme,
                                isRegenerating: regeneratingEntryID == entry.id,
                                actionsDisabled: isBusy,
                                onRegenerate: { entryPendingRegenerate = entry },
                                onDelete: { entryPendingDelete = entry }
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.bottom, 20)
        }
    }

    private var diarySubtitle: String {
        if isEmbedded {
            return "\(characterName)用自己的话记下的相处与心情。聊过的日子过了零点可能会自动写；也可按日期补写。相关片段会在对话里被检索引用。"
        }
        return "每天如果聊过天，\(characterName)可能会在这里留下一点自己的心情。删掉的日记也可以按日期补写。"
    }

    @ToolbarContentBuilder
    private var standaloneToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button(action: openDatePicker) {
                if isGeneratingForSelectedDay {
                    ProgressView()
                } else {
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 16, weight: .semibold))
                }
            }
            .disabled(isBusy)
            .accessibilityLabel("按日期补写日记")
        }
        if viewModel.appSettings.debugModeEnabled {
            ToolbarItem(placement: .primaryAction) {
                Button(action: generateToday) {
                    if isGenerating {
                        ProgressView()
                    } else {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                .disabled(isBusy)
                .accessibilityLabel("调试：生成今天日记")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "book.closed")
                .font(.system(size: 32, weight: .regular))
                .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                .opacity(0.5)

            Text("还没有日记")
                .font(.system(size: 15, weight: .semibold, design: .default))
                .foregroundColor(AppTheme.textColor(colorScheme))

            Text("聊过天之后，过了零点\(characterName)可能会自己写一篇。也可以点右上角日历，按日期补写已删除或漏写的日记。")
                .font(.system(size: 13, weight: .regular, design: .default))
                .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                .opacity(0.70)
                .multilineTextAlignment(.center)

            Button(action: openDatePicker) {
                Text("按日期补写")
                    .font(.system(size: 14, weight: .semibold, design: .default))
            }
            .disabled(isBusy)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var datePickerSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("选择要补写或重新生成的日期。若该天已有日记会先替换；若已删除则按当天聊天记录重新写一篇。当天必须有过聊天。")
                    .font(.system(size: 14, weight: .regular, design: .default))
                    .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                DatePicker(
                    "日期",
                    selection: $selectedDay,
                    in: earliestSelectableDay...latestSelectableDay,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .padding(.horizontal, 12)

                Spacer()
            }
            .navigationTitle("按日期补写日记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showingDatePicker = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("生成") {
                        showingDatePicker = false
                        regenerate(day: selectedDay, entryID: nil)
                    }
                    .disabled(isBusy)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func reload() async {
        entries = await viewModel.loadDiaryEntries()
    }

    private func openDatePicker() {
        selectedDay = latestSelectableDay
        showingDatePicker = true
    }

    private func generateToday() {
        isGenerating = true
        publishEmbeddedToolbar()
        Task {
            await viewModel.generateDiaryForDebug()
            isGenerating = false
            await reload()
            publishEmbeddedToolbar()
        }
    }

    /// Regenerates for a calendar day. `entryID` is set when rewriting from a
    /// card; nil when filling a deleted/missing day from the date picker.
    private func regenerate(day: Date, entryID: UUID?) {
        if let entryID {
            regeneratingEntryID = entryID
        } else {
            isGeneratingForSelectedDay = true
        }
        publishEmbeddedToolbar()
        Task {
            let success = await viewModel.regenerateDiary(for: day)
            regeneratingEntryID = nil
            isGeneratingForSelectedDay = false
            await reload()
            publishEmbeddedToolbar()
            if !success {
                regenerateErrorMessage = "当天没有可用的聊天记录，或生成失败，请稍后再试。"
            }
        }
    }

    private func publishEmbeddedToolbar() {
        guard case .embedded(let binding) = presentation else { return }
        binding.wrappedValue.isBusy = isBusy
        binding.wrappedValue.isGeneratingToday = isGenerating
        binding.wrappedValue.isGeneratingForSelectedDay = isGeneratingForSelectedDay
        binding.wrappedValue.onOpenDatePicker = { openDatePicker() }
        binding.wrappedValue.onGenerateToday = { generateToday() }
    }
}

private struct DiaryEntryCard: View {
    let entry: DiaryEntrySnapshot
    let colorScheme: ColorScheme
    let isRegenerating: Bool
    let actionsDisabled: Bool
    let onRegenerate: () -> Void
    let onDelete: () -> Void

    private var dateLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月d日 EEEE"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: entry.date)
    }

    var body: some View {
        ModernCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(dateLabel)
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .foregroundColor(AppTheme.secondaryTextColor(colorScheme))

                    Spacer()

                    if isRegenerating {
                        ProgressView()
                            .controlSize(.small)
                            .padding(6)
                    } else {
                        Menu {
                            Button(action: onRegenerate) {
                                Label("重新生成", systemImage: "arrow.clockwise")
                            }
                            Button(role: .destructive, action: onDelete) {
                                Label("删除", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                                .padding(6)
                        }
                        .disabled(actionsDisabled)
                    }
                }

                Text(entry.content)
                    .font(.system(size: 15, weight: .regular, design: .default))
                    .foregroundColor(AppTheme.textColor(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(isRegenerating ? 0.45 : 1)
            }
        }
    }
}

#Preview("Standalone") {
    DiaryScreen(viewModel: PreviewFactory.appViewModel())
}

#Preview("Embedded") {
    NavigationStack {
        DiaryScreen(
            viewModel: PreviewFactory.appViewModel(),
            presentation: .embedded(toolbar: .constant(DiaryEmbeddedToolbarState()))
        )
    }
}
