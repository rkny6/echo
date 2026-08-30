import Foundation

struct TokenEstimator {
    static let englishCharsPerToken = 4.0
    static let chineseCharsPerToken = 1.5
    
    static func estimateTokens(for text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        
        var chineseCount = 0
        var otherCount = 0
        
        for scalar in text.unicodeScalars {
            if scalar.isChinese {
                chineseCount += 1
            } else {
                otherCount += 1
            }
        }
        
        let chineseTokens = Double(chineseCount) / chineseCharsPerToken
        let otherTokens = Double(otherCount) / englishCharsPerToken
        
        return Int(ceil(chineseTokens + otherTokens))
    }
    
    static func estimateTokens(for messages: [ChatMessageSnapshot], userName: String, characterName: String) -> Int {
        var totalTokens = 0
        for message in messages {
            let speaker = message.role == .assistant ? characterName : userName
            let messageText = "\(speaker): \(message.content)"
            totalTokens += estimateTokens(for: messageText)
        }
        return totalTokens
    }
}

extension UnicodeScalar {
    var isChinese: Bool {
        return (0x4E00...0x9FFF).contains(self.value) ||
               (0x3400...0x4DBF).contains(self.value) ||
               (0x20000...0x2A6DF).contains(self.value) ||
               (0x2A700...0x2B73F).contains(self.value) ||
               (0x2B740...0x2B81F).contains(self.value) ||
               (0x2B820...0x2CEAF).contains(self.value)
    }
}
