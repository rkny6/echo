//
//  Theme.swift
//  echo
//
//  Created by rkny6 on 4/18/26.
//

import SwiftUI
import Combine

// MARK: - Appearance Mode (Ensures Dark Mode Remains Available)
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    /// Nil means "follow the system"; otherwise force a specific scheme.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Theme Palette
/// A color palette with explicit light + dark variants. All app colors are
/// derived from the currently selected palette so the whole UI can be re-themed
/// without touching any view code.
struct ThemePalette: Identifiable, Equatable {
    let id: String
    let displayName: String

    // Accent
    let accentL: Color
    let accentD: Color

    // Surfaces / backgrounds
    let backgroundL: Color
    let backgroundD: Color
    let surfaceL: Color
    let surfaceD: Color

    // Message bubbles
    let userBubbleL: Color
    let userBubbleD: Color

    // Primary text
    let textL: Color
    let textD: Color

    /// A representative swatch color for the settings picker.
    var swatch: Color { accentL }

    func accent(_ scheme: ColorScheme) -> Color { scheme == .dark ? accentD : accentL }
    func background(_ scheme: ColorScheme) -> Color { scheme == .dark ? backgroundD : backgroundL }
    func surface(_ scheme: ColorScheme) -> Color { scheme == .dark ? surfaceD : surfaceL }
    func userBubble(_ scheme: ColorScheme) -> Color { scheme == .dark ? userBubbleD : userBubbleL }
    func text(_ scheme: ColorScheme) -> Color { scheme == .dark ? textD : textL }
}

// MARK: - Theme Presets
enum ThemePreset: String, CaseIterable, Identifiable {
    case warmPaper
    case burgundy
    case ocean
    case forest
    case rose

    var id: String { rawValue }

    var palette: ThemePalette {
        switch self {
        case .warmPaper:
            return ThemePalette(
                id: rawValue,
                displayName: "暖纸",
                accentL: Color(red: 0.55, green: 0.47, blue: 0.38),
                accentD: Color(red: 0.74, green: 0.65, blue: 0.54),
                backgroundL: Color(red: 0.945, green: 0.933, blue: 0.910),
                backgroundD: Color(red: 0.086, green: 0.082, blue: 0.075),
                surfaceL: Color(red: 1.0, green: 1.0, blue: 1.0),
                surfaceD: Color(red: 0.152, green: 0.145, blue: 0.133),
                userBubbleL: Color(red: 0.157, green: 0.149, blue: 0.137),
                userBubbleD: Color(red: 0.40, green: 0.34, blue: 0.27),
                textL: Color(red: 0.129, green: 0.118, blue: 0.106),
                textD: Color(red: 0.945, green: 0.933, blue: 0.910)
            )
        case .burgundy:
            return ThemePalette(
                id: rawValue,
                displayName: "酒红",
                accentL: Color(red: 0.59, green: 0.08, blue: 0.16),
                accentD: Color(red: 0.85, green: 0.40, blue: 0.55),
                backgroundL: Color(red: 0.945, green: 0.937, blue: 0.941),
                backgroundD: Color(red: 0.08, green: 0.075, blue: 0.078),
                surfaceL: Color(red: 1.0, green: 1.0, blue: 1.0),
                surfaceD: Color(red: 0.145, green: 0.135, blue: 0.140),
                userBubbleL: Color(red: 0.59, green: 0.08, blue: 0.16),
                userBubbleD: Color(red: 0.62, green: 0.20, blue: 0.32),
                textL: Color(red: 0.11, green: 0.10, blue: 0.10),
                textD: Color(red: 0.96, green: 0.95, blue: 0.95)
            )
        case .ocean:
            return ThemePalette(
                id: rawValue,
                displayName: "海蓝",
                accentL: Color(red: 0.18, green: 0.43, blue: 0.52),
                accentD: Color(red: 0.44, green: 0.68, blue: 0.78),
                backgroundL: Color(red: 0.918, green: 0.937, blue: 0.945),
                backgroundD: Color(red: 0.070, green: 0.082, blue: 0.090),
                surfaceL: Color(red: 1.0, green: 1.0, blue: 1.0),
                surfaceD: Color(red: 0.125, green: 0.145, blue: 0.160),
                userBubbleL: Color(red: 0.12, green: 0.24, blue: 0.31),
                userBubbleD: Color(red: 0.20, green: 0.37, blue: 0.46),
                textL: Color(red: 0.10, green: 0.13, blue: 0.15),
                textD: Color(red: 0.93, green: 0.95, blue: 0.96)
            )
        case .forest:
            return ThemePalette(
                id: rawValue,
                displayName: "森绿",
                accentL: Color(red: 0.24, green: 0.42, blue: 0.31),
                accentD: Color(red: 0.49, green: 0.68, blue: 0.55),
                backgroundL: Color(red: 0.922, green: 0.937, blue: 0.918),
                backgroundD: Color(red: 0.070, green: 0.082, blue: 0.074),
                surfaceL: Color(red: 1.0, green: 1.0, blue: 1.0),
                surfaceD: Color(red: 0.128, green: 0.148, blue: 0.132),
                userBubbleL: Color(red: 0.14, green: 0.25, blue: 0.18),
                userBubbleD: Color(red: 0.22, green: 0.38, blue: 0.28),
                textL: Color(red: 0.10, green: 0.14, blue: 0.11),
                textD: Color(red: 0.93, green: 0.96, blue: 0.93)
            )
        case .rose:
            return ThemePalette(
                id: rawValue,
                displayName: "玫瑰",
                accentL: Color(red: 0.69, green: 0.42, blue: 0.47),
                accentD: Color(red: 0.83, green: 0.58, blue: 0.63),
                backgroundL: Color(red: 0.953, green: 0.925, blue: 0.925),
                backgroundD: Color(red: 0.090, green: 0.078, blue: 0.080),
                surfaceL: Color(red: 1.0, green: 1.0, blue: 1.0),
                surfaceD: Color(red: 0.155, green: 0.140, blue: 0.142),
                userBubbleL: Color(red: 0.27, green: 0.17, blue: 0.19),
                userBubbleD: Color(red: 0.50, green: 0.30, blue: 0.34),
                textL: Color(red: 0.13, green: 0.11, blue: 0.11),
                textD: Color(red: 0.96, green: 0.94, blue: 0.94)
            )
        }
    }
}

// MARK: - Theme Manager (Persists preset + appearance in UserDefaults)
/// Lightweight, purely-cosmetic preference store. It uses UserDefaults so it
/// never touches the SwiftData schema or any app functionality.
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    private let presetKey = "app.theme.preset"
    private let appearanceKey = "app.theme.appearance"

    @Published var preset: ThemePreset {
        didSet { UserDefaults.standard.set(preset.rawValue, forKey: presetKey) }
    }

    @Published var appearanceMode: AppearanceMode {
        didSet { UserDefaults.standard.set(appearanceMode.rawValue, forKey: appearanceKey) }
    }

    private init() {
        let savedPreset = UserDefaults.standard.string(forKey: presetKey)
        self.preset = ThemePreset(rawValue: savedPreset ?? "") ?? .warmPaper

        let savedAppearance = UserDefaults.standard.string(forKey: appearanceKey)
        self.appearanceMode = AppearanceMode(rawValue: savedAppearance ?? "") ?? .system
    }

    var palette: ThemePalette { preset.palette }
}

// MARK: - Modern Theme with Enhanced Color Management
struct AppTheme {
    // The active palette, resolved from the user's selected preset.
    static var palette: ThemePalette { ThemeManager.shared.palette }

    // MARK: - Primary Accent Colors
    static var accentPrimary: Color { palette.accentL }
    static var accentLight: Color { palette.accentL.opacity(0.75) }
    static var accentDark: Color { palette.accentD }

    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [palette.accentL.opacity(0.85), palette.accentL],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Adaptive Accent Colors
    static func adaptiveAccentColor(_ colorScheme: ColorScheme) -> Color {
        palette.accent(colorScheme)
    }

    static func accentGradientAdaptive(_ colorScheme: ColorScheme) -> LinearGradient {
        let base = palette.accent(colorScheme)
        return LinearGradient(colors: [base.opacity(0.85), base], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: - Background Colors
    static func backgroundColor(_ colorScheme: ColorScheme) -> Color {
        palette.background(colorScheme)
    }

    static func secondaryBackgroundColor(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? palette.background(colorScheme).opacity(0.6)
            : palette.background(colorScheme)
    }

    // MARK: - Surface Colors (Cards, Containers)
    static func surfaceColor(_ colorScheme: ColorScheme) -> Color {
        palette.surface(colorScheme)
    }

    static func surfaceSecondaryColor(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? palette.surface(colorScheme).opacity(0.85)
            : palette.background(colorScheme).opacity(0.5)
    }

    // MARK: - Text Colors with Enhanced Hierarchy
    static func textColor(_ colorScheme: ColorScheme) -> Color {
        palette.text(colorScheme)
    }

    static func secondaryTextColor(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.68, green: 0.66, blue: 0.63)
            : Color(red: 0.42, green: 0.40, blue: 0.37)
    }

    static func tertiaryTextColor(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.52, green: 0.50, blue: 0.47)
            : Color(red: 0.60, green: 0.58, blue: 0.55)
    }

    // MARK: - Semantic Colors
    static func successColor(_ colorScheme: ColorScheme) -> Color {
        Color(red: 0.20, green: 0.70, blue: 0.40)
    }

    static func warningColor(_ colorScheme: ColorScheme) -> Color {
        Color(red: 0.95, green: 0.65, blue: 0.20)
    }

    static func errorColor(_ colorScheme: ColorScheme) -> Color {
        Color(red: 0.90, green: 0.20, blue: 0.30)
    }

    // MARK: - Border & Divider Colors
    static func borderColor(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.06)
    }

    static func dividerColor(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.06)
    }

    // MARK: - Shadow Colors (Soft & Subtle)
    static func softShadowColor(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.black.opacity(0.30)
            : Color.black.opacity(0.05)
    }

    static func cardShadowColor(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.black.opacity(0.25)
            : Color.black.opacity(0.04)
    }

    // MARK: - Input Field Colors
    static func inputFieldBackground(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? palette.surface(colorScheme).opacity(0.85)
            : palette.background(colorScheme).opacity(0.6)
    }

    static func inputFieldBorderColor(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.08)
    }

    // MARK: - Message Bubble Colors
    static func userMessageBackground(_ colorScheme: ColorScheme) -> Color {
        palette.userBubble(colorScheme)
    }

    static func assistantMessageBackground(_ colorScheme: ColorScheme) -> Color {
        palette.surface(colorScheme)
    }

    // MARK: - Chat Background
    static func chatBackgroundColor(_ colorScheme: ColorScheme) -> Color {
        palette.background(colorScheme)
    }
}

// MARK: - Gradient Extensions
extension LinearGradient {
    static func screenBackgroundGradient(_ colorScheme: ColorScheme) -> LinearGradient {
        // Simple solid color background derived from the active palette.
        let bgColor = AppTheme.chatBackgroundColor(colorScheme)
        return LinearGradient(colors: [bgColor, bgColor], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
