import Foundation
import SwiftUI

@MainActor
final class ProfileFeature {
    private let service: any ProfileProviding
    private let logger: LoggingProviding
    init(profileService: any ProfileProviding, logger: LoggingProviding) { self.service = profileService; self.logger = logger }
    func loadUser() async -> UserProfileSnapshot { await service.loadUser() }
    func loadCharacter() async -> CharacterProfileSnapshot { await service.loadCharacter() }
    func updateUser(_ draft: UserProfileSnapshot) async throws { try await service.updateUser(draft) }
    func updateCharacter(_ draft: CharacterProfileSnapshot) async throws { try await service.updateCharacter(draft) }
}
