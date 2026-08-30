import Foundation
import UIKit

/// Decides how to turn an incoming image into a text description the LLM
/// prompt can use: try the cloud (Agnes) recognizer if enabled in settings,
/// fall back to the on-device Vision-based recognizer (with a timeout), and
/// fall back further to a generic placeholder if both fail.
///
/// Extracted from `ConversationManager`, where this logic (plus its two
/// dedicated recognizer dependencies) lived as three private methods with
/// no other coupling to the rest of the class. Behavior is unchanged — this
/// is a pure extraction, not a rewrite.
actor ImageMessageProcessor {
    private let optimizedImageRecognizer: OptimizedImageRecognizer
    private let agnesImageRecognitionService: AgnesImageRecognitionService
    private let settingsService: SettingsProviding
    private let logger: LoggingProviding

    init(
        optimizedImageRecognizer: OptimizedImageRecognizer = OptimizedImageRecognizer(),
        agnesImageRecognitionService: AgnesImageRecognitionService = AgnesImageRecognitionService(),
        settingsService: SettingsProviding,
        logger: LoggingProviding
    ) {
        self.optimizedImageRecognizer = optimizedImageRecognizer
        self.agnesImageRecognitionService = agnesImageRecognitionService
        self.settingsService = settingsService
        self.logger = logger
    }

    /// Moved verbatim from `ConversationManager.recognizeImageForConversation(_:)`.
    func recognize(_ imageData: Data) async -> (description: String, formattedLabels: String) {
        do {
            guard let image = UIImage(data: imageData) else {
                await logger.log("Image recognition failed: invalid image data (\(imageData.count) bytes)", level: .warning)
                throw NSError(domain: "InvalidImageData", code: -1)
            }

            let settings = try await settingsService.getSettings()
            // Only use Agnes cloud when explicitly enabled via settings (debug only)
            if settings.useAgnesCloudImageRecognition {
                do {
                    let cloudDescription = try await agnesImageRecognitionService.recognizeDescription(from: image)
                    await logger.log("Image recognition (cloud) ok: \(cloudDescription)", level: .debug)
                    return (cloudDescription, "agnes-cloud")
                } catch {
                    await logger.log(
                        "Image recognition cloud failed, falling back to on-device: \(error.localizedDescription)",
                        level: .warning
                    )
                }
            }

            let resultItems = try await withTimeout(seconds: 3) {
                try await self.optimizedImageRecognizer.recognize(image: image)
            }

            let description = formatImageDescription(from: resultItems)
            let formattedLabels = resultItems
                .map { item in
                    "\(item.label)(\(String(format: "%.2f", item.confidence)))"
                }
                .joined(separator: ", ")

            await logger.log(
                "Image recognition (on-device) ok: labels=\(formattedLabels)",
                level: .debug
            )
            return (description, formattedLabels)
        } catch {
            await logger.log("Image recognition failed: \(error.localizedDescription)", level: .warning)
            return ("用户发了一张图片", "none")
        }
    }

    /// Moved verbatim from `ConversationManager.formatImageDescription(from:)`.
    private func formatImageDescription(from items: [OptimizedImageRecognizer.ResultItem]) -> String {
        guard !items.isEmpty else {
            return "这是一张图片，但我还不能确定里面的具体内容。"
        }

        let labels = items.map { $0.label }
        let primaryLabel = labels.first ?? ""
        let secondaryLabels = Array(labels.dropFirst())

        if secondaryLabels.isEmpty {
            return "这张图片里可能有\(primaryLabel)。"
        }

        let secondaryDescription = secondaryLabels.joined(separator: "、")
        return "这张图片里可能有\(primaryLabel)，还包含\(secondaryDescription)。"
    }

    /// Moved verbatim from `ConversationManager.withTimeout(seconds:operation:)`.
    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }

            guard let value = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return value
        }
    }
}
