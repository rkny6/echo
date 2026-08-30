import Foundation

/// Runtime feature flags used for gradual rollout and testing.
enum FeatureFlags {
    /// When true, clicking the disabled image-send button shows an inline hint guiding the user
    /// to enable image sending and configure the Agnes API in settings.
    static let enableImageSendRestrictionHint = true
}
