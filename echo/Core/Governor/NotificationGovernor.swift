//
//  NotificationGovernor.swift
//  echo
//

import Foundation

/// Shared budget for any proactive assistant outreach (health, online greeting, …).
enum ProactiveSendSource: String, Sendable {
    case health
    case onlineGreeting
    case eveningCheckIn
    case dateEvent
}

final class NotificationGovernor {

    // MARK: - Constants

    private let hardBlockWindow: TimeInterval = 10 * 60
    private let softBlockWindow: TimeInterval = 2 * 60 * 60
    private let globalCooldown: TimeInterval = 60 * 60

    private static let lastSentTimeKey = "NotificationGovernor.lastSentTime"
    private static let lastSentSourceKey = "NotificationGovernor.lastSentSource"

    // MARK: - Persisted State

    private var lastSentTime: Date? {
        get { UserDefaults.standard.object(forKey: Self.lastSentTimeKey) as? Date }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: Self.lastSentTimeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.lastSentTimeKey)
            }
        }
    }

    private var lastSentSource: ProactiveSendSource? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Self.lastSentSourceKey) else { return nil }
            return ProactiveSendSource(rawValue: raw)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.rawValue, forKey: Self.lastSentSourceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.lastSentSourceKey)
            }
        }
    }

    // MARK: - Decision Making

    /// Shared proactive policy: global cooldown + quiet window after user chat.
    /// `debugFastMode` shrinks all windows to a few seconds/tens of seconds so
    /// proactive outreach can be exercised quickly during manual testing —
    /// driven by the same "调试模式" toggle already used elsewhere in Settings.
    func shouldSendProactive(
        source: ProactiveSendSource,
        lastUserMessageDate: Date?,
        debugFastMode: Bool = false
    ) -> (allowed: Bool, reason: String) {
        let hardBlockWindow = debugFastMode ? 5.0 : self.hardBlockWindow
        let softBlockWindow = debugFastMode ? 15.0 : self.softBlockWindow
        let globalCooldown = debugFastMode ? 20.0 : self.globalCooldown

        if let last = lastSentTime,
           Date().timeIntervalSince(last) < globalCooldown {
            let secondsLeft = Int(globalCooldown - Date().timeIntervalSince(last)) + 1
            let via = lastSentSource?.rawValue ?? "unknown"
            return (false, "Global cooldown active (\(secondsLeft)s remaining, last=\(via), want=\(source.rawValue))")
        }

        if let lastUserMsg = lastUserMessageDate {
            let elapsed = Date().timeIntervalSince(lastUserMsg)
            if elapsed < hardBlockWindow {
                return (false, String(format: "Hard block: active conversation (%.0f sec ago)", elapsed))
            }
            if elapsed < softBlockWindow {
                return (false, String(format: "Quiet window: recent conversation (%.0f sec ago)", elapsed))
            }
        }

        return (true, "Proactive \(source.rawValue) allowed")
    }

    /// Stricter policy for health proactive: no soft-block lottery.
    func shouldSendHealthProactive(lastUserMessageDate: Date?, debugFastMode: Bool = false) -> (allowed: Bool, reason: String) {
        shouldSendProactive(source: .health, lastUserMessageDate: lastUserMessageDate, debugFastMode: debugFastMode)
    }

    func isInGlobalCooldown() -> Bool {
        guard let last = lastSentTime else { return false }
        return Date().timeIntervalSince(last) < globalCooldown
    }

    func recordSend(source: ProactiveSendSource) {
        lastSentTime = Date()
        lastSentSource = source
    }

    func recordSend(_ intent: NotificationIntent) {
        recordSend(source: .health)
    }
}
