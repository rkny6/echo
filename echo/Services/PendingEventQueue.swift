import Foundation
import SwiftData

/// Durable queue for life events that arrive during active conversations.
actor PendingEventQueue {
    private let modelContainer: ModelContainer
    private let modelContext: ModelContext
    private let logger: LoggingProviding

    // "State" style events (currently just outings, driven by SLC) should be
    // coalesced to their latest occurrence. "Point-in-time" events (birthday,
    // holiday, sleep, onlineGreeting, etc.) are each their own distinct happening and
    // should NOT be deduped this way.
    private static let coalescedEventTypes: Set<CompanionEventType> = [.outing]

    init(modelContainer: ModelContainer, logger: LoggingProviding) {
        self.modelContainer = modelContainer
        self.modelContext = ModelContext(modelContainer)
        self.logger = logger
    }

    func enqueue(_ event: CompanionEvent) async throws {
        // Event types like `.outing` represent "the user is currently out and
        // about" rather than a distinct one-off happening — if one is already
        // sitting unprocessed, a newer occurrence of the same type supersedes
        // it rather than being a separate thing to also mention later. Without
        // this, a run of SLC location-change events arriving while a
        // conversation is active builds up a queue of near-duplicate "outing"
        // entries that all eventually fire as separate, stale messages.
        if Self.coalescedEventTypes.contains(event.type) {
            let all = try modelContext.fetch(FetchDescriptor<PendingEvent>())
            for stale in all where stale.eventType == event.type {
                modelContext.delete(stale)
            }
        }

        let pending = PendingEvent(event: event)
        modelContext.insert(pending)
        try modelContext.save()
        let count = try await count()
        await logger.log(
            "Pending event queued: \(event.type.rawValue) priority=\(event.priority) (queue size: \(count))",
            level: .debug
        )
    }

    // How old a coalesced-type event (currently just outing) can be before
    // it's considered too stale to be worth a message — e.g. surfacing
    // "looks like you went out" three hours after the user is back home reads
    // as the character not paying attention, not as caring.
    private static let staleCoalescedEventMaxAge: TimeInterval = 3 * 60 * 60 // 3 hours

    func dequeueHighestPriority() async throws -> PendingEvent? {
        while true {
            var descriptor = FetchDescriptor<PendingEvent>(
                sortBy: [
                    SortDescriptor(\.priority, order: .reverse),
                    SortDescriptor(\.timestamp, order: .forward)
                ]
            )
            descriptor.fetchLimit = 1
            guard let event = try modelContext.fetch(descriptor).first else { return nil }
            modelContext.delete(event)
            try modelContext.save()

            if Self.coalescedEventTypes.contains(event.eventType),
               Date().timeIntervalSince(event.timestamp) > Self.staleCoalescedEventMaxAge {
                await logger.log(
                    "Discarding stale pending event: \(event.eventType.rawValue) (queued \(Int(Date().timeIntervalSince(event.timestamp)))s ago)",
                    level: .debug
                )
                continue
            }

            await logger.log(
                "Pending event dequeued: \(event.eventType.rawValue) priority=\(event.priority)",
                level: .debug
            )
            return event
        }
    }

    func count() async throws -> Int {
        try modelContext.fetch(FetchDescriptor<PendingEvent>()).count
    }
    
    func getAllPendingEvents() async throws -> [PendingEvent] {
        let descriptor = FetchDescriptor<PendingEvent>(
            sortBy: [
                SortDescriptor(\.priority, order: .reverse),
                SortDescriptor(\.timestamp, order: .forward)
            ]
        )
        return try modelContext.fetch(descriptor)
    }
    
    func clearAll() async throws {
        let events = try modelContext.fetch(FetchDescriptor<PendingEvent>())
        for event in events {
            modelContext.delete(event)
        }
        try modelContext.save()
        await logger.log("Cleared all pending events", level: .info)
    }
}
