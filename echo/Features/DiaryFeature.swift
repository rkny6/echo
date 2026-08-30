import Foundation
import SwiftUI

@MainActor
final class DiaryFeature {
    private let service: DiaryService
    init(diaryService: DiaryService) { self.service = diaryService }
    func loadAll() async -> [DiaryEntrySnapshot] { await service.loadAllEntries() }
    func generateForDebug() async { await service.generateDiaryIfNeeded(bypassTimeGate: true) }
    func regenerate(for day: Date) async -> Bool { await service.regenerateDiary(for: day) }
    func delete(id: UUID) async { await service.deleteEntry(id: id) }
}
