import Foundation

/// Protocol for secure credential storage
protocol KeychainProviding: Sendable {
    /// Store a value in the keychain
    func store(_ value: String, for key: String) async throws
    
    /// Retrieve a value from the keychain
    func retrieve(_ key: String) async throws -> String?
    
    /// Delete a value from the keychain
    func delete(_ key: String) async throws
}
