import Foundation

struct TypingDelayCalculator {
    struct Configuration {
        var readingSpeed: Double = 0.075
        var typingSpeed: Double = 0.03
        var minReadingSpeed: Double = 0.05
        var maxReadingSpeed: Double = 0.10
        var minTypingSpeed: Double = 0.02
        var maxTypingSpeed: Double = 0.04
    }

    private let config: Configuration
    private let jitterFactor: Double = 0.20

    init(config: Configuration = .init()) {
        self.config = config
    }

    func totalDelay(forBatchMessages messages: [AccumulatedMessage], assistantResponse response: String) async -> TimeInterval {
        let renderedResponse = AssistantMessageDelivery.renderedText(from: response)
        let readingDelay = readingDelay(for: messages)
        let thinkingDelay = thinkingDelay(for: renderedResponse)
        let typingDelay = typingDelay(for: renderedResponse)

        let rawTotal = readingDelay + thinkingDelay + typingDelay
        return applyJitter(rawTotal)
    }

    func readingDelay(for messages: [AccumulatedMessage]) -> TimeInterval {
        let totalCharacters = messages.map { $0.content.count }.reduce(0, +)
        let speed = randomInRange(config.minReadingSpeed, config.maxReadingSpeed)
        return Double(totalCharacters) * speed
    }

    func thinkingDelay(for response: String) -> TimeInterval {
        let wordCount = response.split { $0.isWhitespace }.count
        switch wordCount {
        case 0...10:
            return randomInRange(0.5, 1.5)
        case 11...30:
            return randomInRange(1.5, 3.0)
        default:
            return randomInRange(2.5, 5.0)
        }
    }

    func typingDelay(for response: String) -> TimeInterval {
        let characterCount = response.count
        let speed = randomInRange(config.minTypingSpeed, config.maxTypingSpeed)
        return Double(characterCount) * speed
    }

    private func applyJitter(_ delay: TimeInterval) -> TimeInterval {
        let jitter = delay * jitterFactor
        let offset = randomInRange(-jitter, jitter)
        return max(0, delay + offset)
    }

    private func randomInRange(_ min: Double, _ max: Double) -> Double {
        if min == max { return min }
        return Double.random(in: min...max)
    }
}
