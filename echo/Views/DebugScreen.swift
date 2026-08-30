import SwiftUI
import SwiftData

/// Debug screen showing logs and testing tools with modern design
struct DebugScreen: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.colorScheme) var colorScheme
    @State private var selectedEventType: CompanionEventType = .outing
    @State private var isProcessing = false
    @State private var savedMessage = ""
    @State private var debugInfo: ConversationDebugInfo?
    @State private var scheduleDebugInfo: CharacterScheduleDebugInfo?
    @State private var pendingEvents: [PendingEvent] = []
    @State private var pendingResponses: [PendingResponseSnapshot] = []
    @State private var showEvents = false
    @State private var showResponses = false
    @State private var showScheduleWindows = true

    var body: some View {
        ScreenBackground {
            // Lock content to the available width so long unbroken log lines
            // (URLs, metadata dumps, etc.) cannot expand the page and enable
            // horizontal rubber-banding on narrow phones such as iPhone 13.
            GeometryReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 24) {
                    // Header
                    VStack(alignment: .leading, spacing: 8) {
                        Text("调试面板")
                            .font(.system(size: 28, weight: .bold, design: .default))
                            .foregroundColor(AppTheme.textColor(colorScheme))

                        Text("手动触发事件和查看系统日志")
                            .font(.system(size: 14, weight: .regular, design: .default))
                            .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                            .opacity(0.80)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                    // Event Testing Card
                    ModernCard {
                        VStack(spacing: 16) {
                            HStack(spacing: 10) {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(AppTheme.warningColor(colorScheme))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("事件测试")
                                        .font(.system(size: 16, weight: .semibold, design: .default))
                                        .foregroundColor(AppTheme.textColor(colorScheme))

                                    Text("手动触发伴侣事件")
                                        .font(.system(size: 12, weight: .regular, design: .default))
                                        .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                                        .opacity(0.70)
                                }

                                Spacer()
                            }

                            MinimalDivider()
                                .padding(.vertical, 8)

                            VStack(alignment: .leading, spacing: 12) {
                                Text("事件类型")
                                    .font(.system(size: 14, weight: .semibold, design: .default))
                                    .foregroundColor(AppTheme.secondaryTextColor(colorScheme))

                                Picker("事件类型", selection: $selectedEventType) {
                                    ForEach(CompanionEventType.allCases, id: \.self) { type in
                                        Text(type.rawValue).tag(type)
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

                            VStack(spacing: 12) {
                                PrimaryButton(
                                    title: "触发选中事件",
                                    disabled: isProcessing
                                ) {
                                    triggerEvent()
                                }

                                SecondaryButton(
                                    title: "检测所有事件",
                                    disabled: isProcessing
                                ) {
                                    detectEvents()
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, 20)

                    // Conversation State Card
                    ModernCard {
                        VStack(spacing: 12) {
                            HStack(spacing: 10) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(AppTheme.adaptiveAccentColor(colorScheme))

                                Text("对话状态")
                                    .font(.system(size: 16, weight: .semibold, design: .default))
                                    .foregroundColor(AppTheme.textColor(colorScheme))

                                Spacer()
                            }

                            MinimalDivider()
                                .padding(.vertical, 4)

                            if let info = debugInfo {
                                debugRow("状态", value: info.state.rawValue)
                                
                                HStack {
                                    debugRow("待处理事件", value: "\(info.pendingEventCount)")
                                    Spacer()
                                    if info.pendingEventCount > 0 {
                                        Button(action: { 
                                            withAnimation {
                                                showEvents.toggle()
                                            }
                                        }) {
                                            Image(systemName: showEvents ? "chevron.up" : "chevron.down")
                                                .font(.system(size: 14))
                                                .foregroundColor(AppTheme.adaptiveAccentColor(colorScheme))
                                        }
                                    }
                                }
                                
                                HStack {
                                    debugRow("待发送回复", value: "\(info.pendingResponseCount)")
                                    Spacer()
                                    if info.pendingResponseCount > 0 {
                                        Button(action: { 
                                            withAnimation {
                                                showResponses.toggle()
                                            }
                                        }) {
                                            Image(systemName: showResponses ? "chevron.up" : "chevron.down")
                                                .font(.system(size: 14))
                                                .foregroundColor(AppTheme.adaptiveAccentColor(colorScheme))
                                        }
                                    }
                                }
                                
                                if let id = info.currentConversationId {
                                    debugRow("会话 ID", value: String(id.uuidString.prefix(8)) + "…")
                                }
                                
                                MinimalDivider()
                                    .padding(.vertical, 4)
                                
                                // Action Buttons — adaptive grid avoids horizontal overflow on compact widths
                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 96), spacing: 8)],
                                    alignment: .leading,
                                    spacing: 8
                                ) {
                                    if !pendingEvents.isEmpty {
                                        Button(action: processPendingEvents) {
                                            Text("处理事件")
                                                .font(.system(size: 14, weight: .medium))
                                                .foregroundColor(.white)
                                                .frame(maxWidth: .infinity)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 8)
                                                .background(AppTheme.adaptiveAccentColor(colorScheme))
                                                .cornerRadius(8)
                                        }
                                        .disabled(isProcessing)
                                        
                                        Button(action: clearPendingEvents) {
                                            Text("清空事件")
                                                .font(.system(size: 14, weight: .medium))
                                                .foregroundColor(AppTheme.errorColor(colorScheme))
                                                .frame(maxWidth: .infinity)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 8)
                                                .background(AppTheme.errorColor(colorScheme).opacity(0.1))
                                                .cornerRadius(8)
                                        }
                                        .disabled(isProcessing)
                                    }
                                    
                                    if !pendingResponses.isEmpty {
                                        Button(action: deliverPendingResponses) {
                                            Text("发送回复")
                                                .font(.system(size: 14, weight: .medium))
                                                .foregroundColor(.white)
                                                .frame(maxWidth: .infinity)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 8)
                                                .background(AppTheme.successColor(colorScheme))
                                                .cornerRadius(8)
                                        }
                                        .disabled(isProcessing)
                                        
                                        Button(action: clearPendingResponses) {
                                            Text("清空回复")
                                                .font(.system(size: 14, weight: .medium))
                                                .foregroundColor(AppTheme.errorColor(colorScheme))
                                                .frame(maxWidth: .infinity)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 8)
                                                .background(AppTheme.errorColor(colorScheme).opacity(0.1))
                                                .cornerRadius(8)
                                        }
                                        .disabled(isProcessing)
                                    }
                                }
                                
                                // Pending Events List
                                if showEvents && !pendingEvents.isEmpty {
                                    MinimalDivider()
                                        .padding(.vertical, 4)
                                    
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("待处理事件列表:")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(AppTheme.textColor(colorScheme))
                                        
                                        ForEach(pendingEvents, id: \.id) { event in
                                            VStack(alignment: .leading, spacing: 4) {
                                                HStack {
                                                    Text("类型: \(event.eventType.rawValue)")
                                                        .font(.system(size: 13, weight: .medium))
                                                        .foregroundColor(AppTheme.textColor(colorScheme))
                                                    Spacer()
                                                    Text("优先级: \(event.priority)")
                                                        .font(.system(size: 12))
                                                        .foregroundColor(AppTheme.warningColor(colorScheme))
                                                }
                                                Text("时间: \(formatDateTime(event.timestamp))")
                                                    .font(.system(size: 11))
                                                    .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                                                if !event.metadata.isEmpty {
                                                    Text("元数据: \(event.metadata.description)")
                                                        .font(.system(size: 11))
                                                        .foregroundColor(AppTheme.tertiaryTextColor(colorScheme))
                                                        .lineLimit(2)
                                                        .truncationMode(.tail)
                                                        .frame(maxWidth: .infinity, alignment: .leading)
                                                        .fixedSize(horizontal: false, vertical: true)
                                                }
                                            }
                                            .padding(10)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(AppTheme.inputFieldBackground(colorScheme))
                                            .cornerRadius(8)
                                        }
                                    }
                                }
                                
                                // Pending Responses List
                                if showResponses && !pendingResponses.isEmpty {
                                    MinimalDivider()
                                        .padding(.vertical, 4)
                                    
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("待发送回复列表:")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(AppTheme.textColor(colorScheme))
                                        
                                        ForEach(pendingResponses, id: \.id) { response in
                                            VStack(alignment: .leading, spacing: 4) {
                                                if let eventType = response.eventType {
                                                    Text("事件: \(eventType.rawValue)")
                                                        .font(.system(size: 13, weight: .medium))
                                                        .foregroundColor(AppTheme.textColor(colorScheme))
                                                }
                                                Text(response.content)
                                                    .font(.system(size: 13))
                                                    .foregroundColor(AppTheme.textColor(colorScheme))
                                                    .lineLimit(3)
                                                    .truncationMode(.tail)
                                                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                                    .fixedSize(horizontal: false, vertical: true)
                                                HStack {
                                                    Text("计划发送: \(formatDateTime(response.scheduledDeliveryTime))")
                                                        .font(.system(size: 11))
                                                        .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                                                    Spacer()
                                                    if response.scheduledDeliveryTime < Date() {
                                                        Text("已过期")
                                                            .font(.system(size: 11, weight: .medium))
                                                            .foregroundColor(AppTheme.warningColor(colorScheme))
                                                    }
                                                }
                                            }
                                            .padding(10)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(AppTheme.inputFieldBackground(colorScheme))
                                            .cornerRadius(8)
                                        }
                                    }
                                }
                            } else {
                                Text("加载中…")
                                    .font(.system(size: 13))
                                    .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                            }
                        }
                    }
                    .padding(.horizontal, 20)

                    // Character Online Schedule Card
                    ModernCard {
                        VStack(spacing: 12) {
                            HStack(spacing: 10) {
                                Image(systemName: "calendar.badge.clock")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(AppTheme.successColor(colorScheme))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("角色在线日程")
                                        .font(.system(size: 16, weight: .semibold, design: .default))
                                        .foregroundColor(AppTheme.textColor(colorScheme))

                                    Text("今日计划窗口 + 临时 keep-online")
                                        .font(.system(size: 12, weight: .regular, design: .default))
                                        .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                                        .opacity(0.70)
                                }

                                Spacer()

                                Button(action: {
                                    Task { await refreshData() }
                                }) {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(AppTheme.adaptiveAccentColor(colorScheme))
                                }

                                Button(action: regenerateSchedule) {
                                    Image(systemName: "wand.and.stars")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(AppTheme.adaptiveAccentColor(colorScheme))
                                }
                                .disabled(isProcessing)
                                .accessibilityLabel("重新生成今日日程")
                            }

                            MinimalDivider()
                                .padding(.vertical, 4)

                            if let schedule = scheduleDebugInfo {
                                debugRow(
                                    "当前状态",
                                    value: schedule.currentStatus == .online ? "在线" : "离线"
                                )
                                debugRow(
                                    "对话 active",
                                    value: schedule.isConversationActive ? "是（抑制突然下线）" : "否"
                                )
                                debugRow(
                                    "最近上线类型",
                                    value: schedule.lastOnlineWasEarly ? "earlyOnline / keep-alive" : "scheduled / none"
                                )
                                debugRow("日程日", value: formatDay(schedule.dayStart))
                                debugRow("今日总在线", value: formatDurationHMM(schedule.totalOnlineSeconds))
                                if let next = schedule.nextTransition {
                                    debugRow("下次状态切换", value: formatDateTime(next))
                                } else {
                                    debugRow("下次状态切换", value: "—")
                                }
                                if let nextOnline = schedule.nextOnline {
                                    debugRow("下次上线估计", value: formatDateTime(nextOnline))
                                }
                                debugRow("窗口数", value: "\(schedule.windows.count)")
                                debugRow("快照时间", value: formatDateTime(schedule.capturedAt))

                                HStack {
                                    Text("窗口列表")
                                        .font(.system(size: 13, weight: .regular))
                                        .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                                    Spacer()
                                    Button(action: {
                                        withAnimation { showScheduleWindows.toggle() }
                                    }) {
                                        Image(systemName: showScheduleWindows ? "chevron.up" : "chevron.down")
                                            .font(.system(size: 14))
                                            .foregroundColor(AppTheme.adaptiveAccentColor(colorScheme))
                                    }
                                }

                                if showScheduleWindows {
                                    if schedule.windows.isEmpty {
                                        Text("今天没有 online 窗口")
                                            .font(.system(size: 13))
                                            .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                                    } else {
                                        VStack(alignment: .leading, spacing: 8) {
                                            ForEach(Array(schedule.windows.enumerated()), id: \.element.id) { index, window in
                                                HStack(alignment: .center, spacing: 10) {
                                                    Text("#\(index + 1)")
                                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                                        .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                                                        .frame(width: 28, alignment: .leading)

                                                    VStack(alignment: .leading, spacing: 2) {
                                                        Text("\(formatTime(window.start)) – \(formatTime(window.end))")
                                                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                                            .foregroundColor(AppTheme.textColor(colorScheme))
                                                        Text(windowDurationLabel(window.start, window.end))
                                                            .font(.system(size: 11))
                                                            .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                                                    }

                                                    Spacer()

                                                    if window.isActiveNow {
                                                        Text("进行中")
                                                            .font(.system(size: 11, weight: .semibold))
                                                            .foregroundColor(.white)
                                                            .padding(.horizontal, 8)
                                                            .padding(.vertical, 4)
                                                            .background(AppTheme.successColor(colorScheme))
                                                            .cornerRadius(6)
                                                    } else if window.end <= schedule.capturedAt {
                                                        Text("已结束")
                                                            .font(.system(size: 11, weight: .medium))
                                                            .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                                                    } else {
                                                        Text("未开始")
                                                            .font(.system(size: 11, weight: .medium))
                                                            .foregroundColor(AppTheme.adaptiveAccentColor(colorScheme))
                                                    }
                                                }
                                                .padding(10)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                        .fill(AppTheme.inputFieldBackground(colorScheme))
                                                )
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                        .stroke(
                                                            window.isActiveNow
                                                                ? AppTheme.successColor(colorScheme).opacity(0.5)
                                                                : Color.clear,
                                                            lineWidth: 1
                                                        )
                                                )
                                            }
                                        }
                                    }
                                }
                            } else {
                                Text("加载中…")
                                    .font(.system(size: 13))
                                    .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                            }
                        }
                    }
                    .padding(.horizontal, 20)

                    // Logs Card
                    ModernCard {
                        VStack(spacing: 16) {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(AppTheme.adaptiveAccentColor(colorScheme))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("系统日志")
                                        .font(.system(size: 16, weight: .semibold, design: .default))
                                        .foregroundColor(AppTheme.textColor(colorScheme))

                                    Text("共 \(viewModel.debugLogs.count) 条日志")
                                        .font(.system(size: 12, weight: .regular, design: .default))
                                        .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                                        .opacity(0.70)
                                }

                                Spacer(minLength: 8)

                                Button(action: clearLogs) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "trash.fill")
                                            .font(.system(size: 13, weight: .semibold))
                                        Text("清除")
                                            .font(.system(size: 13, weight: .semibold, design: .default))
                                            .lineLimit(1)
                                    }
                                    .foregroundColor(AppTheme.errorColor(colorScheme))
                                }
                                .layoutPriority(1)
                                .accessibilityLabel("清除全部日志")
                            }

                            MinimalDivider()
                                .padding(.vertical, 8)

                            if viewModel.debugLogs.isEmpty {
                                EmptyStateView(
                                    icon: "doc.fill",
                                    title: "没有日志",
                                    subtitle: nil
                                )
                            } else {
                                VStack(spacing: 8) {
                                    ForEach(viewModel.debugLogs.sorted(by: { $0.timestamp > $1.timestamp })) { log in
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack(spacing: 8) {
                                                Label(
                                                    log.level.rawValue.uppercased(),
                                                    systemImage: iconForLevel(log.level)
                                                )
                                                .font(.system(size: 11, weight: .semibold, design: .default))
                                                .foregroundColor(colorForLevel(log.level))
                                                .lineLimit(1)

                                                Spacer(minLength: 4)

                                                Text(formatDateTime(log.timestamp))
                                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                                    .foregroundColor(AppTheme.tertiaryTextColor(colorScheme))
                                                    .opacity(0.70)
                                                    .lineLimit(1)
                                                    .minimumScaleFactor(0.85)
                                            }

                                            Text(log.message)
                                                .font(.system(size: 13, weight: .regular, design: .default))
                                                .foregroundColor(AppTheme.textColor(colorScheme))
                                                .multilineTextAlignment(.leading)
                                                .lineLimit(3)
                                                .truncationMode(.tail)
                                                // minWidth: 0 is required so long unbroken tokens
                                                // (URLs, JSON blobs) wrap/truncate inside the card.
                                                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(AppTheme.inputFieldBackground(colorScheme))
                                        )
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            if !savedMessage.isEmpty {
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 13, weight: .semibold))

                                    Text(savedMessage)
                                        .font(.system(size: 12, weight: .regular, design: .default))

                                    Spacer()
                                }
                                .foregroundColor(AppTheme.successColor(colorScheme))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(AppTheme.successColor(colorScheme).opacity(0.10))
                                )
                                .transition(.move(edge: .top).combined(with: .opacity))
                            }
                        }
                    }
                    .padding(.horizontal, 20)

                    Spacer(minLength: 20)
                    }
                    .padding(.vertical, 20)
                    .frame(width: proxy.size.width, alignment: .top)
                }
                .scrollDismissesKeyboard(.interactively)
                .dismissKeyboardOnTap()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Task {
                await refreshData()
            }
        }
    }

    private func refreshData() async {
        await viewModel.refreshDebugLogs()
        debugInfo = await viewModel.refreshConversationDebugInfo()
        scheduleDebugInfo = await viewModel.refreshCharacterScheduleDebugInfo()
        pendingEvents = await viewModel.getAllPendingEvents()
        pendingResponses = await viewModel.getAllPendingResponses()
    }

    private func formatDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func windowDurationLabel(_ start: Date, _ end: Date) -> String {
        let minutes = max(0, Int(end.timeIntervalSince(start) / 60))
        if minutes >= 60 {
            let hours = minutes / 60
            let rem = minutes % 60
            return rem == 0 ? "时长 \(hours)h" : "时长 \(hours)h \(rem)m"
        }
        return "时长 \(minutes)m"
    }

    private func formatDurationHMM(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds / 60))
        let hours = total / 60
        let rem = total % 60
        return rem == 0 ? "\(hours)h" : "\(hours)h \(rem)m"
    }

    private func regenerateSchedule() {
        isProcessing = true
        Task {
            scheduleDebugInfo = await viewModel.regenerateCharacterScheduleForDebug()
            showSuccess("已重新生成今日日程")
            isProcessing = false
        }
    }
    
    private func debugRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(AppTheme.textColor(colorScheme))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func triggerEvent() {
        isProcessing = true
        Task {
            let event = CompanionEvent(
                type: selectedEventType,
                metadata: ["source": "manual_debug"]
            )
            await viewModel.startConversationForEvent(event)
            await refreshData()
            isProcessing = false

            withAnimation(.easeInOut(duration: 0.3)) {
                savedMessage = "事件已触发"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        savedMessage = ""
                    }
                }
            }
        }
    }

    private func detectEvents() {
        isProcessing = true
        Task {
            await viewModel.detectAndProcessEvents()
            await refreshData()
            isProcessing = false

            withAnimation(.easeInOut(duration: 0.3)) {
                savedMessage = "已检测所有事件"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        savedMessage = ""
                    }
                }
            }
        }
    }
    
    private func processPendingEvents() {
        isProcessing = true
        Task {
            await viewModel.forceProcessPendingEvents()
            await refreshData()
            showSuccess("待处理事件已处理")
            isProcessing = false
        }
    }
    
    private func deliverPendingResponses() {
        isProcessing = true
        Task {
            await viewModel.forceDeliverPendingResponses()
            await refreshData()
            showSuccess("待发送回复已发送")
            isProcessing = false
        }
    }
    
    private func clearPendingEvents() {
        isProcessing = true
        Task {
            await viewModel.clearAllPendingEvents()
            await refreshData()
            showSuccess("待处理事件已清空")
            isProcessing = false
        }
    }
    
    private func clearPendingResponses() {
        isProcessing = true
        Task {
            await viewModel.clearAllPendingResponses()
            await refreshData()
            showSuccess("待发送回复已清空")
            isProcessing = false
        }
    }
    
    private func showSuccess(_ message: String) {
        withAnimation(.easeInOut(duration: 0.3)) {
            savedMessage = message
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    savedMessage = ""
                }
            }
        }
    }

    private func clearLogs() {
        Task {
            await viewModel.clearDebugLogs()
            await refreshData()

            withAnimation(.easeInOut(duration: 0.3)) {
                savedMessage = "日志已清除"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        savedMessage = ""
                    }
                }
            }
        }
    }

    private func colorForLevel(_ level: LogLevel) -> Color {
        switch level {
        case .debug:
            return AppTheme.tertiaryTextColor(colorScheme)
        case .info:
            return AppTheme.adaptiveAccentColor(colorScheme)
        case .warning:
            return AppTheme.warningColor(colorScheme)
        case .error:
            return AppTheme.errorColor(colorScheme)
        }
    }

    private func iconForLevel(_ level: LogLevel) -> String {
        switch level {
        case .debug:
            return "bug"
        case .info:
            return "info.circle"
        case .warning:
            return "exclamationmark.triangle"
        case .error:
            return "xmark.circle"
        }
    }

    private func formatDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

#Preview {
    DebugScreen(viewModel: PreviewFactory.appViewModel())
}
