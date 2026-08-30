import Foundation
import SwiftData

@Model
final class LongTermMemory: @unchecked Sendable {
    @Attribute(.unique) var id: UUID
    
    var globalSummary: String
    var userProfileData: Data?
    var lastSummaryUpdate: Date
    var totalMessagesProcessed: Int
    var tokenBudgetPercentage: Double
    var slidingWindowSize: Int
    
    var userProfile: [String: String] {
        get {
            guard let data = userProfileData,
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                return [:]
            }
            return dict
        }
        set {
            userProfileData = try? JSONSerialization.data(withJSONObject: newValue)
        }
    }
    
    init(
        id: UUID = UUID(),
        globalSummary: String = "",
        userProfile: [String: String] = [:],
        lastSummaryUpdate: Date = Date(),
        totalMessagesProcessed: Int = 0,
        tokenBudgetPercentage: Double = 0.6,
        slidingWindowSize: Int = 20
    ) {
        self.id = id
        self.globalSummary = globalSummary
        self.lastSummaryUpdate = lastSummaryUpdate
        self.totalMessagesProcessed = totalMessagesProcessed
        self.tokenBudgetPercentage = tokenBudgetPercentage
        self.slidingWindowSize = slidingWindowSize
        self.userProfileData = try? JSONSerialization.data(withJSONObject: userProfile)
    }
}
