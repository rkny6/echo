import Foundation
import SwiftUI

@MainActor
final class APIProfileFeature {
    private let service: any APIProfileProviding
    private let keychain: KeychainProviding
    private let settings: SettingsProviding
    private let logger: LoggingProviding
    init(apiProfileService: any APIProfileProviding, keychain: KeychainProviding, settings: SettingsProviding, logger: LoggingProviding) {
        self.service = apiProfileService; self.keychain = keychain; self.settings = settings; self.logger = logger
    }
    func loadAll() async -> [APIProfileSnapshot] { await service.loadAll() }
    func create(name: String, baseURL: String?, model: String, endpointMode: LLMAPIEndpointMode, temperature: Double, maxTokens: Int, apiKey: String?) async -> APIProfileSnapshot? {
        do {
            let profile = try await service.create(name: name, provider: .customOpenAICompatible, baseURL: baseURL, model: model, endpointMode: endpointMode, temperature: temperature, maxTokens: maxTokens)
            if let apiKey, !apiKey.isEmpty { try await keychain.store(apiKey, for: profile.keychainKeyName) }
            return profile
        } catch { await logger.log("Failed to create API profile: \(error.localizedDescription)", level: .error); return nil }
    }
    func delete(_ profile: APIProfileSnapshot) async {
        try? await service.delete(id: profile.id)
        try? await keychain.delete(profile.keychainKeyName)
    }
    func applyKey(_ profile: APIProfileSnapshot) async -> Bool {
        do {
            if let key = try await keychain.retrieve(profile.keychainKeyName), !key.isEmpty {
                try await keychain.store(key, for: AppViewModel.activeAPIKeyName)
                return true
            }
        } catch {
            await logger.log("Failed to switch active key: \(error.localizedDescription)", level: .error)
            return false
        }
        try? await keychain.delete(AppViewModel.activeAPIKeyName)
        return false
    }
    func update(_ profile: APIProfileSnapshot, name: String, baseURL: String?, model: String, endpointMode: LLMAPIEndpointMode, temperature: Double, maxTokens: Int, apiKey: String?) async {
        do { try await service.update(id: profile.id, name: name, baseURL: baseURL, model: model, endpointMode: endpointMode, temperature: temperature, maxTokens: maxTokens) }
        catch { await logger.log("Failed to update API profile: \(error.localizedDescription)", level: .error) }
        guard let apiKey else { return }
        do {
            if apiKey.isEmpty { try await keychain.delete(profile.keychainKeyName) }
            else { try await keychain.store(apiKey, for: profile.keychainKeyName) }
        } catch { await logger.log("Failed to update API profile key: \(error.localizedDescription)", level: .error) }
    }
}
