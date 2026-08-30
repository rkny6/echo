import Foundation

/// Protocol for app settings management
protocol SettingsProviding: Sendable {
    /// Get current app settings
    func getSettings() async throws -> AppSettings
    
    /// Update app settings
    func updateSettings(_ settings: AppSettings) async throws
    
    /// Get a specific setting value
    func getSetting<T>(_ key: String) async throws -> T?
    
    /// Update a specific setting value
    func setSetting<T>(_ key: String, value: T) async throws
}
