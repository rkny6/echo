import Foundation

struct PlannedAssistantMessage: Equatable, Sendable {
    let content: String
    let delayFromPrevious: TimeInterval
    let shouldNotify: Bool
}

struct StructuredAssistantMessage: Equatable, Sendable {
    let content: String
    let delayMilliseconds: Int?
    let shouldNotify: Bool?
}

struct StructuredAssistantResponse: Equatable, Sendable {
    let messages: [StructuredAssistantMessage]
}

struct AssistantResponsePayloadParser {
    private let maxStructuredMessageCount: Int

    init(maxStructuredMessageCount: Int = 3) {
        self.maxStructuredMessageCount = maxStructuredMessageCount
    }

    func parse(_ rawText: String) -> StructuredAssistantResponse? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var validJSONButUnrecognizedShape: Any?

        for candidate in candidateJSONStrings(from: trimmed) {
            guard let data = candidate.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else {
                continue
            }

            guard let response = makeResponse(from: json) else {
                // It parsed as JSON, just not a shape we recognize (e.g. the
                // model used a field name outside our known list). Remember
                // it so we can still salvage readable text from it below,
                // rather than immediately falling through to the plain-text
                // segmenter — which would just chop the raw JSON syntax
                // itself into garbled "sentences" and show that to the user.
                if validJSONButUnrecognizedShape == nil {
                    validJSONButUnrecognizedShape = json
                }
                continue
            }

            // 加保险：如果解析到的任意一条消息内容又包含大段 JSON 结构（像 "{", "}" 很多），就放弃结构化解析，回退到断句
            let containsSuspectContent = response.messages.contains { message in
                let content = message.content
                let braceCount = content.filter { $0 == "{" || $0 == "}" }.count
                return braceCount > 2 // 简单的判断：如果内容里有 3 个以上的大括号，大概率是解析错了，内容里还有 JSON
            }

            if containsSuspectContent {
                continue
            }

            return response
        }

        if let json = validJSONButUnrecognizedShape,
           let salvaged = salvageReadableStrings(from: json), !salvaged.isEmpty {
            return StructuredAssistantResponse(
                messages: [StructuredAssistantMessage(content: salvaged, delayMilliseconds: nil, shouldNotify: nil)]
            )
        }

        return nil
    }

    /// Last-resort recovery for JSON that parsed fine but didn't match any
    /// schema we know about (wrong/unexpected field names, unusual nesting,
    /// etc). Walks the JSON tree and collects string leaves that look like
    /// actual message content — long enough to be a sentence, and not a
    /// short token like a delay value or a boolean-ish string — rather than
    /// showing the user the raw JSON.
    private func salvageReadableStrings(from json: Any) -> String? {
        var pieces: [String] = []

        func walk(_ value: Any) {
            switch value {
            case let string as String:
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                // Skip short/structural-looking values (keys like "delay_ms"
                // sometimes get stringified, booleans, IDs, etc.) — real
                // message content is virtually always longer than this.
                if trimmed.count >= 4, !isLikelyStructuralToken(trimmed) {
                    pieces.append(trimmed)
                }
            case let dictionary as [String: Any]:
                for value in dictionary.values { walk(value) }
            case let array as [Any]:
                for value in array { walk(value) }
            default:
                break
            }
        }

        walk(json)
        guard !pieces.isEmpty else { return nil }
        return pieces.joined(separator: " ")
    }

    private func isLikelyStructuralToken(_ value: String) -> Bool {
        if Int(value) != nil || Double(value) != nil { return true }
        let lowered = value.lowercased()
        return ["true", "false", "null"].contains(lowered)
    }

    func renderedText(from rawText: String) -> String {
        if let response = parse(rawText) {
            return response.messages.map(\.content).joined(separator: " ")
        }

        return rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func candidateJSONStrings(from text: String) -> [String] {
        var candidates = [String]()

        // 优先尝试从整个文本里抠出最干净的内嵌 JSON（只拿第一个 { 到最后一个 } 之间的内容）
        if let embeddedJSON = extractEmbeddedJSON(from: text) {
            candidates.append(embeddedJSON)
        }

        // 然后试试代码块包裹的 JSON
        if let fencedJSON = extractCodeFencePayload(from: text) {
            candidates.append(fencedJSON)
        }

        // 最后才试整个文本
        candidates.append(text)

        // 针对每个候选，再补一个修掉尾随逗号的版本——这是模型最常犯的 JSON 格式错误
        // （比如 [{"content": "a"}, {"content": "b"},]），JSONSerialization 对这种直接拒绝解析。
        candidates += candidates.compactMap(repairingTrailingCommas)

        // 去重
        return Array(NSOrderedSet(array: candidates)) as? [String] ?? candidates
    }

    private func repairingTrailingCommas(_ text: String) -> String? {
        // 匹配 ", " 后面紧跟 "}" 或 "]"（中间允许空白/换行）的情况，去掉那个多余的逗号
        guard let regex = try? NSRegularExpression(pattern: ",\\s*([}\\]])", options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let repaired = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1")
        return repaired == text ? nil : repaired
    }

    private func extractCodeFencePayload(from text: String) -> String? {
        guard let openingRange = text.range(of: "```") else { return nil }
        let suffix = text[openingRange.upperBound...]
        guard let closingRange = suffix.range(of: "```") else { return nil }

        let payload = suffix[..<closingRange.lowerBound]
        let cleaned = payload
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "json\n", with: "", options: [.anchored, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? nil : cleaned
    }

    private func extractEmbeddedJSON(from text: String) -> String? {
        guard let objectStart = text.firstIndex(where: { $0 == "{" || $0 == "[" }),
              let objectEnd = text.lastIndex(where: { $0 == "}" || $0 == "]" }),
              objectStart < objectEnd else {
            return nil
        }

        let candidate = String(text[objectStart...objectEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? nil : candidate
    }

    private func makeResponse(from json: Any) -> StructuredAssistantResponse? {
        let rawMessages: [Any]

        switch json {
        case let dictionary as [String: Any]:
            if let nested = dictionary["messages"] as? [Any] {
                rawMessages = nested
            } else if let nested = dictionary["replies"] as? [Any] {
                rawMessages = nested
            } else if let nested = dictionary["segments"] as? [Any] {
                rawMessages = nested
            } else if let message = makeMessage(from: dictionary) {
                return StructuredAssistantResponse(messages: [message])
            } else {
                return nil
            }
        case let array as [Any]:
            rawMessages = array
        case let string as String:
            rawMessages = [string]
        default:
            return nil
        }

        let messages = rawMessages
            .compactMap(makeMessage)
            .prefix(maxStructuredMessageCount)

        guard !messages.isEmpty else { return nil }
        return StructuredAssistantResponse(messages: Array(messages))
    }

    private func makeMessage(from rawValue: Any) -> StructuredAssistantMessage? {
        switch rawValue {
        case let message as StructuredAssistantMessage:
            return message

        case let content as String:
            let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return nil }
            return StructuredAssistantMessage(content: normalized, delayMilliseconds: nil, shouldNotify: nil)

        case let dictionary as [String: Any]:
            let contentKeys = ["content", "message", "text", "reply", "response", "answer", "body"]
            guard let rawContent = contentKeys.compactMap({ dictionary[$0] as? String }).first else {
                return nil
            }

            let normalizedContent = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedContent.isEmpty else { return nil }

            let delayKeys = ["delay_ms", "delayMs", "pause_ms", "delay"]
            let rawDelay = delayKeys.compactMap { key -> Int? in
                if let intValue = dictionary[key] as? Int {
                    return intValue
                }
                if let doubleValue = dictionary[key] as? Double {
                    return Int(doubleValue.rounded())
                }
                if let stringValue = dictionary[key] as? String,
                   let intValue = Int(stringValue) {
                    return intValue
                }
                return nil
            }.first

            let shouldNotify = (dictionary["should_notify"] as? Bool) ?? (dictionary["notify"] as? Bool)

            return StructuredAssistantMessage(
                content: normalizedContent,
                delayMilliseconds: rawDelay,
                shouldNotify: shouldNotify
            )

        default:
            return nil
        }
    }
}

struct AssistantMessageSequencePlanner {
    private let segmenter: AssistantMessageSegmenter
    private let payloadParser: AssistantResponsePayloadParser

    init(
        segmenter: AssistantMessageSegmenter = AssistantMessageSegmenter(),
        payloadParser: AssistantResponsePayloadParser = AssistantResponsePayloadParser()
    ) {
        self.segmenter = segmenter
        self.payloadParser = payloadParser
    }

    // Keep this in sync with AssistantResponsePayloadParser's maxStructuredMessageCount
    // and with the "最多3条" instruction in PromptBuilder's system prompt. The model
    // won't always follow the JSON-format instruction, so the plain-text fallback path
    // needs its own hard cap rather than trusting punctuation-based splitting alone.
    private static let maxFallbackMessageCount = 3

    func plan(from content: String) -> [PlannedAssistantMessage] {
        if let structuredResponse = payloadParser.parse(content) {
            return planStructuredMessages(structuredResponse.messages)
        }

        let segments = capSegmentCount(segmenter.split(content))
        guard !segments.isEmpty else { return [] }

        return segments.enumerated().map { index, segment in
            PlannedAssistantMessage(
                content: segment,
                delayFromPrevious: index == 0 ? 0 : pacingDelay(for: segment),
                shouldNotify: index == 0
            )
        }
    }

    func renderedText(from content: String) -> String {
        payloadParser.renderedText(from: content)
    }

    // Merges any overflow past the limit into the final bubble so we cap the
    // *count* of messages without silently dropping content. Join with empty
    // separator to preserve the segmenter's own spacing (Chinese sentences
    // already end with punctuation like 。 so no extra space is needed).
    private func capSegmentCount(_ segments: [String], limit: Int = AssistantMessageSequencePlanner.maxFallbackMessageCount) -> [String] {
        guard segments.count > limit, limit > 0 else { return segments }
        let head = Array(segments.prefix(limit - 1))
        let tail = segments.suffix(from: limit - 1).joined()
        return head + [tail]
    }

    private func planStructuredMessages(_ messages: [StructuredAssistantMessage]) -> [PlannedAssistantMessage] {
        messages.enumerated().map { index, message in
            PlannedAssistantMessage(
                content: message.content,
                delayFromPrevious: index == 0 ? 0 : delay(for: message),
                shouldNotify: message.shouldNotify ?? (index == 0)
            )
        }
    }

    private func delay(for message: StructuredAssistantMessage) -> TimeInterval {
        if let delayMilliseconds = message.delayMilliseconds {
            return max(0.35, min(3.5, Double(delayMilliseconds) / 1_000))
        }
        return pacingDelay(for: message.content)
    }

    // 打字延迟
    private func pacingDelay(for segment: String) -> TimeInterval {
        let length = segment.count
        let baseDelay = 0.55 + (Double(length) * 0.045)
        return min(1.8, baseDelay)
    }
}

struct AssistantMessageSegmenter {
    private let targetLength: Int
    private let secondaryTargetLength: Int
    private let minimumMergeLength: Int
    private let overflowTolerance: Int

    init(
        targetLength: Int = 32,
        secondaryTargetLength: Int = 22,
        minimumMergeLength: Int = 8,
        overflowTolerance: Int = 8
    ) {
        self.targetLength = targetLength
        self.secondaryTargetLength = secondaryTargetLength
        self.minimumMergeLength = minimumMergeLength
        self.overflowTolerance = overflowTolerance
    }

    func split(_ text: String) -> [String] {
        let normalized = normalizeWhitespace(in: text)
        guard !normalized.isEmpty else { return [] }

        let primarySegments = splitByPrimaryBoundary(normalized)
        let secondarySegments = primarySegments.flatMap(splitOversizedSegment)
        return mergeShortSegments(secondarySegments)
    }

    private func normalizeWhitespace(in text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(whereSeparator: \.isNewline)
            .map { line in
                line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func splitByPrimaryBoundary(_ text: String) -> [String] {
        var segments: [String] = []
        var buffer = ""
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            buffer.append(character)

            if character == "\n" {
                flush(&buffer, into: &segments)
                index += 1
                continue
            }

            if isPrimaryBoundary(character, characters: characters, index: index) {
                while index + 1 < characters.count, isTrailingClosure(characters[index + 1]) {
                    index += 1
                    buffer.append(characters[index])
                }
                flush(&buffer, into: &segments)
            }

            index += 1
        }

        flush(&buffer, into: &segments)
        return segments
    }

    private func splitOversizedSegment(_ segment: String) -> [String] {
        guard segment.count > targetLength else { return [segment] }

        var chunks: [String] = []
        var buffer: [Character] = []
        var lastSecondaryBoundaryIndex: Int?

        for character in segment {
            buffer.append(character)

            if isSecondaryBoundary(character), buffer.count >= secondaryTargetLength {
                lastSecondaryBoundaryIndex = buffer.count - 1
            }

            guard buffer.count >= targetLength else { continue }

            if let boundaryIndex = lastSecondaryBoundaryIndex {
                let chunk = String(buffer[...boundaryIndex])
                chunks.append(chunk.trimmingCharacters(in: .whitespacesAndNewlines))
                buffer = Array(buffer[(boundaryIndex + 1)...])
            } else if buffer.count >= targetLength + overflowTolerance {
                let chunk = String(buffer)
                chunks.append(chunk.trimmingCharacters(in: .whitespacesAndNewlines))
                buffer.removeAll(keepingCapacity: true)
            } else {
                continue
            }

            lastSecondaryBoundaryIndex = nil
            if !buffer.isEmpty {
                for (index, bufferedCharacter) in buffer.enumerated() where isSecondaryBoundary(bufferedCharacter) {
                    lastSecondaryBoundaryIndex = index
                }
            }
        }

        let remainder = String(buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty {
            chunks.append(remainder)
        }
        return chunks
    }

    private func mergeShortSegments(_ segments: [String]) -> [String] {
        var merged: [String] = []

        for segment in segments {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if var previous = merged.last,
               trimmed.count < minimumMergeLength,
               previous.count + trimmed.count <= targetLength + minimumMergeLength,
               !endsWithStrongPunctuation(previous),
               !endsWithStrongPunctuation(trimmed) {
                previous += connector(between: previous, and: trimmed) + trimmed
                merged[merged.count - 1] = previous
            } else {
                merged.append(trimmed)
            }
        }

        return merged
    }

    private func flush(_ buffer: inout String, into segments: inout [String]) {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            segments.append(trimmed)
        }
        buffer.removeAll(keepingCapacity: true)
    }

    private func isPrimaryBoundary(_ character: Character, characters: [Character], index: Int) -> Bool {
        if "。！？!?…".contains(character) {
            return true
        }

        guard character == "." else { return false }

        let previous = index > 0 ? characters[index - 1] : nil
        let next = index + 1 < characters.count ? characters[index + 1] : nil
        let isDecimalPoint = previous?.isNumber == true && next?.isNumber == true
        return !isDecimalPoint
    }

    private func isTrailingClosure(_ character: Character) -> Bool {
        "”’」』）》】）)]\"' ".contains(character)
    }

    private func isSecondaryBoundary(_ character: Character) -> Bool {
        "，、；：,: ".contains(character)
    }

    private func endsWithStrongPunctuation(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return "。！？!?…".contains(last)
    }

    private func connector(between previous: String, and next: String) -> String {
        guard let last = previous.last, let first = next.first else { return "" }
        if isASCII(last) && isASCII(first) && !last.isWhitespace && !first.isWhitespace {
            return " "
        }
        return ""
    }

    private func isASCII(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(\.isASCII)
    }
}
