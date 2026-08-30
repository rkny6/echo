
import SwiftUI
import SwiftData

/// Main chat screen showing conversation with the companion
struct ChatScreen: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.colorScheme) var colorScheme
    @State private var selectedMessages = Set<UUID>()
    @State private var showDeleteConfirmation = false
    @State private var unreadCount: Int = 0
    @State private var earliestUnreadMessageId: UUID?
    /// Whether the user is currently stuck to the latest message.
    /// Keyboard / layout resizes must not auto-scroll when reading history.
    @State private var isPinnedToBottom = true
    /// True only while the user is actively dragging / decelerating the list.
    /// Container-height changes from the keyboard must not clear the pin.
    @State private var isUserDraggingScroll = false
    /// Latest measured distance from the true content bottom (negative while
    /// rubber-banding past the end). Used to correct residual bounce offset.
    @State private var distanceFromBottom: CGFloat = 0

    /// Stable sentinel below the last bubble so scroll-to-bottom aligns to the
    /// real content end (including trailing padding), not mid-bubble bounds.
    private let chatBottomAnchorId = "chat-bottom-anchor"

    // WeChat-style date formatter
    private func formatWeChatDate(_ date: Date) -> String {
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            return "今天"
        } else if calendar.isDateInYesterday(date) {
            return "昨天"
        } else {
            let dateFormatter = DateFormatter()
            if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
                dateFormatter.dateFormat = "M月d日"
            } else {
                dateFormatter.dateFormat = "yyyy年M月d日"
            }
            return dateFormatter.string(from: date)
        }
    }
    
    private func formatSimpleTime(_ date: Date) -> String {
        let calendar = Calendar.current

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        
        var prefix = ""
        if calendar.isDateInToday(date) {
            let hour = calendar.component(.hour, from: date)
            if hour < 6 {
                prefix = "凌晨"
            } else if hour < 12 {
                prefix = "上午"
            } else if hour < 18 {
                prefix = "下午"
            } else {
                prefix = "晚上"
            }
        } else if calendar.isDateInYesterday(date) {
            prefix = "昨天"
        }
        
        return prefix + timeFormatter.string(from: date)
    }

    private var hasSelections: Bool {
        !selectedMessages.isEmpty
    }

    var body: some View {
        ScreenBackground {
            VStack(spacing: 0) {
                headerPanel

                if viewModel.chatMessages.isEmpty {
                    EmptyStateView(
                        icon: "bubble.right",
                        title: "没有聊天记录",
                        subtitle: "与你的虚拟伴侣开始对话吧"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    messageListView
                        .background(AppTheme.chatBackgroundColor(colorScheme))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // Composer as safe-area inset so the message list (and empty
            // state) shrink when the keyboard rises, instead of sitting
            // under a fixed VStack bottom bar.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Group {
                    if hasSelections {
                        selectionToolbar
                    } else {
                        ChatComposerView(viewModel: viewModel)
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            .animation(.easeInOut(duration: 0.2), value: hasSelections)
            .animation(.easeInOut(duration: 0.2), value: currentStatus)
            .onTapGesture {
                hideKeyboard()
            }
        }
        .navigationTitle("")
        .navigationBarHidden(true)
        .confirmationDialog(
            "删除消息",
            isPresented: $showDeleteConfirmation,
            presenting: selectedMessages.count
        ) { count in
            Button("删除 \(count) 条消息", role: .destructive) {
                Task {
                    do {
                        try await viewModel.deleteMessages(selectedMessages)
                        selectedMessages.removeAll()
                    } catch {
                        await viewModel.handleError("删除消息失败：\(error.localizedDescription)")
                    }
                }
            }
        } message: { count in
            Text("确定要删除选中的 \(count) 条消息吗？此操作无法撤销。")
        }
    }

    private var messageListView: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView(.vertical, showsIndicators: false) {
                    messagesContent
                }
                .coordinateSpace(name: "scrollView")
                // Grow / shrink toward the newest edge. Viewport-height changes
                // (keyboard) still need an explicit re-pin below.
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onScrollPhaseChange { _, newPhase in
                    let wasDragging = isUserDraggingScroll
                    isUserDraggingScroll = (newPhase == .interacting || newPhase == .decelerating)

                    // Rubber-band overscroll at the bottom can settle a few pt
                    // short of the true end. Only correct that residual gap —
                    // not intentional near-bottom scroll (still within 120pt).
                    if newPhase == .idle,
                       wasDragging,
                       isPinnedToBottom,
                       shouldCorrectBottomBounceResidual(distanceFromBottom) {
                        scrollToLatestMessage(proxy: proxy, animated: false, deferred: true)
                    }
                }
                .onScrollGeometryChange(for: ChatScrollMetrics.self) { geometry in
                    // visibleRect tracks rubber-band overscroll (negative
                    // distance) without fighting composer safe-area insets.
                    let distance = geometry.contentSize.height - geometry.visibleRect.maxY
                    return ChatScrollMetrics(
                        distanceFromBottom: distance,
                        nearBottom: distance <= 120,
                        nearTop: geometry.visibleRect.minY <= 80,
                        containerHeight: geometry.containerSize.height.rounded()
                    )
                } action: { oldMetrics, metrics in
                    distanceFromBottom = metrics.distanceFromBottom

                    // Keyboard shrinks the container without a user gesture and
                    // temporarily inflates distance-from-bottom. Only unstick
                    // when the user is actually dragging the list.
                    if metrics.nearBottom {
                        if !isPinnedToBottom {
                            isPinnedToBottom = true
                        }
                    } else if isUserDraggingScroll, isPinnedToBottom {
                        isPinnedToBottom = false
                    }

                    // Keep the latest bubble glued above the composer while the
                    // keyboard animates the safe-area. Use non-animated scrollTo
                    // so we ride the system keyboard curve instead of fighting it.
                    // Safe with eager VStack (LazyVStack used to blank here).
                    if isPinnedToBottom,
                       abs(oldMetrics.containerHeight - metrics.containerHeight) >= 1 {
                        scrollToLatestMessage(proxy: proxy, animated: false, deferred: false)
                    }

                    // Eager VStack lays out the load-older header immediately,
                    // so we cannot rely on its onAppear. Trigger pagination
                    // only when the user has scrolled up (near top but not still
                    // pinned at the bottom of a short transcript).
                    if metrics.nearTop,
                       !metrics.nearBottom,
                       viewModel.hasMoreChatHistory,
                       !viewModel.isLoadingMoreChatHistory {
                        isPinnedToBottom = false
                        Task { await viewModel.loadOlderChatHistory() }
                    }
                }
                .onChange(of: viewModel.chatMessages) { oldMessages, newMessages in
                    // Only auto-scroll when the newest bubble changes (new
                    // delivery / send). Loading older history prepends and
                    // must not yank the user back to the bottom.
                    let newestChanged = oldMessages.last?.id != newMessages.last?.id
                    if newestChanged, isPinnedToBottom || isUserOwnedMessage(newMessages.last) {
                        isPinnedToBottom = true
                        scrollToLatestMessage(proxy: proxy, animated: true)
                    }
                    updateUnreadState()
                }
                .onAppear {
                    isPinnedToBottom = true
                    updateUnreadState()
                    scrollToLatestMessage(proxy: proxy, animated: false)
                }

                // Floating actions while reading history (and unread jump).
                VStack(spacing: 10) {
                    if unreadCount > 0 {
                        unreadMessagesButton(proxy: proxy)
                    }
                    if !isPinnedToBottom {
                        jumpToLatestButton(proxy: proxy)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 14)
                .padding(.bottom, 12)
                .animation(.easeInOut(duration: 0.2), value: isPinnedToBottom)
                .animation(.easeInOut(duration: 0.2), value: unreadCount)
            }
        }
    }

    private func isUserOwnedMessage(_ message: ChatMessageSnapshot?) -> Bool {
        message?.role == .user
    }

    /// Residual gap left after bottom rubber-band settles (a few pt high),
    /// or still slightly past the content end. Intentionally small so a
    /// deliberate near-bottom scroll is not yanked back.
    private func shouldCorrectBottomBounceResidual(_ distance: CGFloat) -> Bool {
        distance < -0.5 || (distance > 0.5 && distance < 12)
    }

    private func scrollToLatestMessage(
        proxy: ScrollViewProxy,
        animated: Bool,
        deferred: Bool = true
    ) {
        guard viewModel.chatMessages.last?.id != nil else { return }
        let action = {
            // Scroll to the trailing sentinel (not the last bubble id) so the
            // list settles flush with content end + bottom padding.
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(chatBottomAnchorId, anchor: .bottom)
                }
            } else {
                // Match keyboard / safe-area animation; don't add a second curve.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(chatBottomAnchorId, anchor: .bottom)
                }
            }
        }

        if deferred {
            // Wait one turn so a newly inserted bubble exists before scrollTo.
            DispatchQueue.main.async(execute: action)
        } else {
            action()
        }
    }

    private var messagesContent: some View {
        // Eager VStack (not LazyVStack). Chat is already paged (~60 rows), and
        // LazyVStack unloads off-screen bubbles — during keyboard safe-area
        // changes that produced a blank transcript until the user scrolled.
        VStack(spacing: 0) {
            if viewModel.hasMoreChatHistory || viewModel.isLoadingMoreChatHistory {
                loadOlderHistoryHeader
                    .id("chat-load-older")
            }

            let groupedMessages = Dictionary(grouping: viewModel.chatMessages) {
                Calendar.current.startOfDay(for: $0.timestamp)
            }
            let sortedDates = groupedMessages.keys.sorted()

            ForEach(sortedDates, id: \.self) { date in
                dayMessagesView(
                    for: date,
                    messages: groupedMessages[date] ?? []
                )
            }

            // End-of-list scroll target (real content, not background).
            // Height is the visible gap above the composer when pinned.
            Color.clear
                .frame(height: 5)
                .id(chatBottomAnchorId)
        }
        .padding(.top, 12)
    }

    private struct ChatScrollMetrics: Equatable {
        let distanceFromBottom: CGFloat
        let nearBottom: Bool
        let nearTop: Bool
        let containerHeight: CGFloat
    }

    private var loadOlderHistoryHeader: some View {
        HStack {
            Spacer()
            if viewModel.isLoadingMoreChatHistory {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text("上拉加载更早消息")
                    .font(.system(size: 12, weight: .regular, design: .default))
                    .foregroundStyle(AppTheme.secondaryTextColor(colorScheme))
                    .opacity(0.70)
            }
            Spacer()
        }
        .padding(.vertical, 12)
    }

    private func dayMessagesView(for date: Date, messages: [ChatMessageSnapshot]) -> some View {
        VStack(spacing: 0) {
            dateSeparatorView(for: date)
            messagesListView(for: date, messages: messages)
        }
    }

    private func dateSeparatorView(for date: Date) -> some View {
        let dateStr = formatWeChatDate(date)
        guard !dateStr.isEmpty else {
            return AnyView(EmptyView())
        }

        return AnyView(
            HStack {
                Spacer()
                Text(dateStr)
                    .font(.system(size: 12, weight: .regular, design: .default))
                    .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                    .opacity(0.60)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(AppTheme.surfaceColor(colorScheme).opacity(0.90))
                    )
                Spacer()
            }
            .padding(.vertical, 16)
        )
    }

    private func messagesListView(for date: Date, messages: [ChatMessageSnapshot]) -> some View {
        VStack(spacing: 12) {
            ForEach(Array(messages.enumerated()), id: \.element.id) { index, msg in
                messageView(msg, at: index, allMessages: messages)
            }
        }
        .padding(.horizontal, 12)
    }

    private func messageView(
        _ msg: ChatMessageSnapshot,
        at index: Int,
        allMessages: [ChatMessageSnapshot]
    ) -> some View {
        let isLast = index == allMessages.count - 1

        return messageBubbleView(msg, showTime: true)
            // Day-last row trailing space; gap to the composer is mainly
            // owned by the bottom scroll anchor.
            .padding(.bottom, isLast ? 6 : 0)
            .id(msg.id)
            .onAppear {
                if !msg.isRead && msg.role == .assistant {
                    let messageId = msg.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        viewModel.markMessageAsRead(messageId)
                        updateUnreadState()
                    }
                }
            }
    }

    private func messageBubbleView(_ msg: ChatMessageSnapshot, showTime: Bool = true) -> some View {
        let isUser = msg.role == .user
        let isSelected = selectedMessages.contains(msg.id)
        let isUnread = !msg.isRead && msg.role == .assistant
        let showAvatar = isUser ? viewModel.appSettings.showUserAvatar : viewModel.appSettings.showCharacterAvatar
        let avatarName = isUser ? viewModel.user.avatarName : viewModel.character.avatarName
        let bubbleOffset: CGFloat = !showAvatar ? (isUser ? 10 : -10) : 0

        return HStack(alignment: .top, spacing: 10) {
            if !isUser {
                if showAvatar {
                    AvatarView(avatarName: avatarName, isUser: isUser, size: 43)
                } else {
                    Spacer().frame(width: 4)
                }
            } else {
                Spacer(minLength: 12)
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                HStack(alignment: .bottom, spacing: 8) {
                    if isUser && isMessageFailed(msg) {
                        retryButton(for: msg)
                    }

                    Group {
                        if msg.hasImage {
                            userImageBubble(msg, isUser: isUser, isSelected: isSelected, isUnread: isUnread)
                        } else {
                            userTextBubble(msg, isUser: isUser, isSelected: isSelected, isUnread: isUnread)
                        }
                    }
                    .contentShape(Rectangle())
                    .onLongPressGesture {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            _ = selectedMessages.insert(msg.id)
                        }
                    }
                    .onTapGesture {
                        if !selectedMessages.isEmpty {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if selectedMessages.contains(msg.id) {
                                    _ = selectedMessages.remove(msg.id)
                                } else {
                                    _ = selectedMessages.insert(msg.id)
                                }
                            }
                        }
                    }
                }

                HStack(spacing: 4) {
                    if isUser { Spacer() }
                    if isUser && isMessageFailed(msg) {
                        Button {
                            Task { await viewModel.resendMessage(msg) }
                        } label: {
                            Text("发送失败，点击重试")
                                .font(.system(size: 11, weight: .medium, design: .default))
                                .foregroundStyle(AppTheme.errorColor(colorScheme))
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isSendingMessage)
                    }
                    if showTime {
                        Text(formatSimpleTime(msg.timestamp))
                            .font(.system(size: 12, weight: .regular, design: .default))
                            .foregroundStyle(AppTheme.secondaryTextColor(colorScheme))
                            .opacity(0.6)
                    }
                }
            }
            .frame(maxWidth: 280, alignment: isUser ? .trailing : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            .offset(x: bubbleOffset)

            if isUser {
                if showAvatar {
                    AvatarView(avatarName: avatarName, isUser: isUser, size: 43)
                } else {
                    Spacer().frame(width: 4)
                }
            } else {
                Spacer(minLength: 12)
            }
        }
        .padding(.horizontal, 12)
        .opacity(isSelected ? 0.85 : 1.0)
        .onAppear {
            if !msg.isRead && msg.role == .assistant {
                let messageId = msg.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    viewModel.markMessageAsRead(messageId)
                    updateUnreadState()
                }
            }
        }
    }
    
private func userImageBubble(_ msg: ChatMessageSnapshot, isUser: Bool, isSelected: Bool, isUnread: Bool) -> some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 8) {
            if let imageData = msg.imageData, let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 220)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .cornerRadius(16)
            }

            if !msg.content.isEmpty {
                Text(msg.content)
                    .font(.system(size: 15, weight: .regular, design: .default))
                    .foregroundStyle(isUser ? .white : AppTheme.textColor(colorScheme))
                    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            }

            if msg.status == .recognizing {
                Text("正在分析图片…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryTextColor(colorScheme))
            } else if isMessageFailed(msg) {
                Text("发送失败")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.errorColor(colorScheme).opacity(0.9))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(isUser ? AppTheme.userMessageBackground(colorScheme) : AppTheme.assistantMessageBackground(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(
                    isMessageFailed(msg)
                        ? AppTheme.errorColor(colorScheme).opacity(0.55)
                        : (isSelected ? AppTheme.adaptiveAccentColor(colorScheme).opacity(0.30) : Color.clear),
                    lineWidth: (isMessageFailed(msg) || isSelected) ? 2 : 0
                )
        )
        .shadow(
            color: isUser ? Color.clear : AppTheme.softShadowColor(colorScheme),
            radius: isUser ? 0 : 10,
            x: 0,
            y: isUser ? 0 : 4
        )
    }
    
    private func userTextBubble(_ msg: ChatMessageSnapshot, isUser: Bool, isSelected: Bool, isUnread: Bool) -> some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 0) {
            if !msg.content.isEmpty {
                Text(msg.content)
                    .font(.system(size: 16, weight: .regular, design: .default))
                    .lineSpacing(3)
                    .foregroundStyle(isUser ? .white : AppTheme.textColor(colorScheme))
                    .multilineTextAlignment(isUser ? .trailing : .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(isUser ? AppTheme.userMessageBackground(colorScheme) : AppTheme.assistantMessageBackground(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(
                    isMessageFailed(msg)
                        ? AppTheme.errorColor(colorScheme).opacity(0.55)
                        : (isSelected ? AppTheme.adaptiveAccentColor(colorScheme).opacity(0.30) : Color.clear),
                    lineWidth: (isMessageFailed(msg) || isSelected) ? 2 : 0
                )
        )
        .shadow(
            color: isUser ? Color.clear : AppTheme.softShadowColor(colorScheme),
            radius: isUser ? 0 : 10,
            x: 0,
            y: isUser ? 0 : 4
        )
    }

    private func isMessageFailed(_ msg: ChatMessageSnapshot) -> Bool {
        msg.role == .user && (msg.isFailed == true || msg.status == .failed)
    }

    private func retryButton(for msg: ChatMessageSnapshot) -> some View {
        Button {
            Task {
                await viewModel.resendMessage(msg)
            }
        } label: {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(AppTheme.errorColor(colorScheme))
                .accessibilityLabel("重试发送")
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isSendingMessage)
        .opacity(viewModel.isSendingMessage ? 0.45 : 1)
    }

    // MARK: - Floating Scroll Helpers

    private func jumpToLatestButton(proxy: ScrollViewProxy) -> some View {
        Button {
            isPinnedToBottom = true
            scrollToLatestMessage(proxy: proxy, animated: true)
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.secondaryTextColor(colorScheme))
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(AppTheme.surfaceColor(colorScheme))
                        .shadow(
                            color: AppTheme.softShadowColor(colorScheme),
                            radius: 4,
                            x: 0,
                            y: 2
                        )
                )
                .overlay(
                    Circle()
                        .stroke(AppTheme.inputFieldBorderColor(colorScheme), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("回到最新消息")
        .transition(.scale.combined(with: .opacity))
    }

    private func unreadMessagesButton(proxy: ScrollViewProxy) -> some View {
        Button(action: {
            scrollToEarliestUnreadMessage(proxy: proxy)
        }) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                Text(unreadCount == 1 ? "1 条新消息" : "\(unreadCount) 条新消息")
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(AppTheme.adaptiveAccentColor(colorScheme))
                    .shadow(color: Color.black.opacity(0.15), radius: 4, x: 0, y: 2)
            )
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .transition(.scale.combined(with: .opacity))
    }

    private func updateUnreadState() {
        let unreadMessages = viewModel.chatMessages.filter { !$0.isRead && $0.role == .assistant }
        unreadCount = unreadMessages.count
        earliestUnreadMessageId = unreadMessages.first?.id
    }

    private func markAllAsRead() {
        viewModel.markAllAssistantMessagesAsRead()
        updateUnreadState()
    }

    private func scrollToEarliestUnreadMessage(proxy: ScrollViewProxy) {
        if let targetId = earliestUnreadMessageId {
            isPinnedToBottom = false
            withAnimation {
                proxy.scrollTo(targetId, anchor: .top)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                markAllAsRead()
            }
        } else {
            isPinnedToBottom = true
            scrollToLatestMessage(proxy: proxy, animated: true)
            markAllAsRead()
        }
    }


    private var headerPanel: some View {
        VStack(spacing: 0) {
            ZStack {
                // 角色名 - 绝对居中
                VStack(spacing: 2) {
                    Text(viewModel.character.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppTheme.textColor(colorScheme))
                }
                
                // 右侧状态点
                HStack {
                    Spacer()
                    Circle()
                        .fill(viewModel.isCharacterOnline ? AppTheme.successColor(colorScheme) : Color.gray.opacity(0.5))
                        .frame(width: 8, height: 8)
                        .padding(.trailing, 12)
                }
            }
            .frame(height: 60)
            .padding(.horizontal, 12)
            .padding(.top, 4)

            Divider()
                .background(AppTheme.dividerColor(colorScheme))
        }
        .background(AppTheme.chatBackgroundColor(colorScheme))
    }

    private var currentStatus: String? {
        guard viewModel.isCharacterOnline else { return nil }

        if viewModel.isCharacterReading && viewModel.conversationState == .waitingForResponse {
            return "正在输入…"
        }

        if viewModel.conversationState == .waitingForResponse {
            return "正在输入…"
        }

        if viewModel.isGeneratingReply {
            return "正在输入…"
        }

        return nil
    }

    private var selectionToolbar: some View {
        VStack(spacing: 0) {
            Divider()
                .background(AppTheme.dividerColor(colorScheme))

            HStack(spacing: 12) {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedMessages.removeAll()
                    }
                }) {
                    Text("取消")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(AppTheme.textColor(colorScheme))
                }

                Spacer()

                Text("\(selectedMessages.count) 条已选择")
                    .font(.system(size: 16, weight: .medium, design: .default))
                    .foregroundStyle(AppTheme.textColor(colorScheme))

                Spacer()

                Button(action: { showDeleteConfirmation = true }) {
                    Text("删除")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(AppTheme.errorColor(colorScheme))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(AppTheme.surfaceColor(colorScheme))
    }

}

#Preview {
    ChatScreen(viewModel: PreviewFactory.appViewModel())
}

