import UIKit

/// Wraps a `UIApplication.beginBackgroundTask` assertion.
///
/// Without this, work kicked off right as the user backgrounds/quits the app
/// (e.g. an in-flight LLM request for a message they just sent) gets cut off
/// within seconds — iOS suspends the process and any in-flight network
/// request dies with NSURLErrorNetworkConnectionLost (-1005), silently, with
/// no reply ever generated. Wrapping that work in a background task
/// assertion buys extra execution time (Apple typically grants ~30s) for it
/// to actually finish before the process gets suspended.
///
/// `begin()`/`end()` are idempotent and safe to call from any actor context;
/// the UIApplication calls themselves are hopped onto the main actor
/// internally.
@MainActor
final class BackgroundTaskAssertion: @unchecked Sendable {
    private var taskID: UIBackgroundTaskIdentifier = .invalid

    func begin(name: String) {
        guard taskID == .invalid else { return }
        taskID = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // Expiration handler: the OS is about to force-suspend us —
            // release the assertion so we don't get penalized for
            // overstaying, even though the underlying work may not have
            // finished. There's nothing more useful to do here; any pending
            // work (e.g. a still-in-flight request) will fail on its own and
            // hit the normal error/retry path next time the app is opened.
            self?.end()
        }
    }

    func end() {
        guard taskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskID)
        taskID = .invalid
    }
}
