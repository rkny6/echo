import SwiftUI
import SwiftData

/// Root view with modern tab navigation
struct RootView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var notificationRouter = NotificationRouter.shared
    @State private var selectedTab: Int = 0
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        TabView(selection: $selectedTab) {
            ChatScreen(viewModel: viewModel)
                .tabItem {
                    Label("聊天", systemImage: "message.circle.fill")
                        .font(.system(size: 26)) // 放大图标
                }
                .tag(0)

            CharacterProfileScreen(viewModel: viewModel)
                .tabItem {
                    Label("角色", systemImage: "heart.circle.fill")
                        .font(.system(size: 26))
                }
                .tag(1)

            UserProfileScreen(viewModel: viewModel)
                .tabItem {
                    Label("我的", systemImage: "person.circle.fill")
                        .font(.system(size: 26))
                }
                .tag(2)

            NavigationStack {
                SettingsScreen(viewModel: viewModel)
            }
            .tabItem {
                Label("设置", systemImage: "gearshape.fill")
                    .font(.system(size: 26))
            }
            .tag(3)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear
                .frame(height: 20)  // 底部留白，视觉抬高
                .accessibilityHidden(true)
        }
        .preferredColorScheme(themeManager.appearanceMode.colorScheme)
        .tint(AppTheme.adaptiveAccentColor(colorScheme))
        .onAppear {
            configureTabBarAppearance()
        }
        .onChange(of: colorScheme) { _ in
            configureTabBarAppearance()
        }
        .onChange(of: themeManager.preset) { _ in
            configureTabBarAppearance()
        }
        // Notification tap → chat tab + history refresh (see NotificationRouter).
        .onChange(of: notificationRouter.openChatToken) { _ in
            selectedTab = 0
            Task {
                await viewModel.handleNotificationOpen(
                    conversationId: notificationRouter.conversationId,
                    responseId: notificationRouter.responseId
                )
            }
        }
    }

    private func configureTabBarAppearance() {
        let appearance = UITabBarAppearance()
        
        // 1. 毛玻璃背景（自动适配深色/浅色）
        appearance.configureWithDefaultBackground()
        appearance.backgroundEffect = UIBlurEffect(style: .systemMaterial)
        appearance.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.85)
        
        // 2. 柔和的顶部阴影线（替代默认分隔线）
        appearance.shadowColor = UIColor.separator.withAlphaComponent(0.3)
        appearance.shadowImage = UIImage()

        let itemAppearance = UITabBarItemAppearance()
        
        // ----- 未选中状态 -----
        itemAppearance.normal.iconColor = .secondaryLabel
        itemAppearance.normal.titleTextAttributes = [
            .foregroundColor: UIColor.secondaryLabel,
            .font: UIFont.systemFont(ofSize: 11, weight: .medium)
        ]
        itemAppearance.normal.titlePositionAdjustment = UIOffset(horizontal: 0, vertical: 2)
        
        // ----- 选中状态 -----
        let accentColor = UIColor(AppTheme.adaptiveAccentColor(colorScheme))
        itemAppearance.selected.iconColor = accentColor
        itemAppearance.selected.titleTextAttributes = [
            .foregroundColor: accentColor,
            .font: UIFont.systemFont(ofSize: 11, weight: .semibold)
        ]
        itemAppearance.selected.titlePositionAdjustment = UIOffset(horizontal: 0, vertical: 2)

        appearance.stackedLayoutAppearance = itemAppearance
        appearance.inlineLayoutAppearance = itemAppearance
        appearance.compactInlineLayoutAppearance = itemAppearance

        let tabBar = UITabBar.appearance()
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
        tabBar.tintColor = accentColor
        tabBar.unselectedItemTintColor = .secondaryLabel
    }
}

#Preview {
    RootView(viewModel: PreviewFactory.appViewModel())
}
