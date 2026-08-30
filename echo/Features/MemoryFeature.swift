import Foundation
import SwiftUI

@MainActor
final class MemoryFeature {
    private let service: MemoryManaging
    init(memoryManager: MemoryManaging) { self.service = memoryManager }
    func load() async -> UserFacingMemorySnapshot { await service.loadUserFacingMemory() }
    func clearSummary() async { await service.clearLongTermSummary() }
    func clearProfile() async { await service.clearExtractedUserProfile() }
    func removeMessages(_ ids: Set<UUID>) async { await service.removeMessages(ids) }
}
