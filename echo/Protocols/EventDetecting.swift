import Foundation

/// Protocol for detecting companion events from raw data
protocol EventDetecting: Sendable {
    /// Detect events based on current health and location data
    func detectEvents() async throws -> [CompanionEvent]

    /// Detect extreme health-only events for proactive LLM notifications
    func detectExtremeHealthEvents() async throws -> [CompanionEvent]

    func detectDateBasedEvents() async throws -> [CompanionEvent]
    
    /// Manually trigger an event for testing
    func triggerEventForTesting(_ type: CompanionEventType) async throws
}
