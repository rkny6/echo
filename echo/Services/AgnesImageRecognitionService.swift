import Foundation
import UIKit

/// Cloud image understanding service backed by Agnes AI's OpenAI-compatible endpoint.
/// It prefers Base64 data URLs for the image payload so no temporary upload step is required.
final class AgnesImageRecognitionService {
    enum AgnesError: LocalizedError {
        case missingAPIKey
        case invalidImage
        case invalidResponse
        case requestFailed(String)
        case decodingFailed(String)
        case timeout
        case missingImgBBAPIKey

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Agnes AI API Key 未配置。请在 Info.plist 或 UserDefaults 中提供 agnes_ai_api_key。"
            case .invalidImage:
                return "图片数据无效，无法进行云端识别。"
            case .invalidResponse:
                return "Agnes AI 返回了无效响应。"
            case .requestFailed(let message):
                return "Agnes AI 请求失败：\(message)"
            case .decodingFailed(let message):
                return "Agnes AI 响应解析失败：\(message)"
            case .timeout:
                return "Agnes AI 请求超时。"
            case .missingImgBBAPIKey:
                return "ImgBB API Key 未配置。请在 Info.plist 中提供 IMGBB_API_KEY 以启用 Agnes 云端图像理解。"
            }
        }
    }

    private static let endpoint = URL(string: "https://apihub.agnes-ai.com/v1/chat/completions")!
    private static let defaultModel = "agnes-2.0-flash"
    private static let defaultPrompt = "请用中文简洁描述这张图片的内容"
    private static var sharedImgBBAPIKey: String?

    private let apiKey: String?
    private let imgbbAPIKey: String?
    private let session: URLSession
    private let timeoutInterval: TimeInterval
    private let cache = NSCache<NSString, NSString>()

    init(apiKey: String? = nil, imgbbAPIKey: String? = nil, session: URLSession = .shared, timeoutInterval: TimeInterval = 20) {
        self.apiKey = apiKey ?? Self.resolveAPIKey()
        self.imgbbAPIKey = imgbbAPIKey ?? Self.resolveImgBBAPIKey()
        self.session = session
        self.timeoutInterval = timeoutInterval
    }

    /// Recognize an image and return a concise Chinese description.
    func recognizeDescription(from image: UIImage, prompt: String? = nil) async throws -> String {
        guard let imageData = compressedJPEGData(from: image) else {
            throw AgnesError.invalidImage
        }

        let promptText = prompt ?? Self.defaultPrompt

        let cacheKey = NSString(string: "\(imageData.count):\(image.size.width)x\(image.size.height)")
        if let cached = cache.object(forKey: cacheKey) {
            return cached as String
        }

        guard let apiKey else {
            throw AgnesError.missingAPIKey
        }

        guard let imgbbAPIKey else {
            throw AgnesError.missingImgBBAPIKey
        }

        let publicURL = try await uploadImageToImgBB(imageData, apiKey: imgbbAPIKey, mimeType: "image/jpeg")
        let requestBody = try makeRequestBody(prompt: promptText, imageDataURL: publicURL)
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeoutInterval
        request.httpBody = requestBody

        do {
            let (data, response) = try await withTimeout(seconds: timeoutInterval) {
                try await self.session.data(for: request)
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw AgnesError.invalidResponse
            }

            if httpResponse.statusCode >= 400 {
                let message = String(data: data, encoding: .utf8) ?? "未知错误"
                throw AgnesError.requestFailed("HTTP \(httpResponse.statusCode): \(message)")
            }

            guard String(data: data, encoding: .utf8) != nil else {
                throw AgnesError.decodingFailed("响应体不是 UTF-8 文本")
            }

            guard let description = parseDescription(from: data) else {
                throw AgnesError.invalidResponse
            }

            cache.setObject(NSString(string: description), forKey: cacheKey)
            return description
        } catch let error as AgnesError {
            AppLog.warning("AgnesImageRecognition", error.localizedDescription)
            throw error
        } catch is CancellationError {
            AppLog.warning("AgnesImageRecognition", "request timed out")
            throw AgnesError.timeout
        } catch {
            AppLog.warning("AgnesImageRecognition", error.localizedDescription)
            throw AgnesError.requestFailed(error.localizedDescription)
        }
    }

    /// Validate that the configured Agnes API key and endpoint respond correctly.
    func testConnection() async throws {
        guard let apiKey else {
            throw AgnesError.missingAPIKey
        }

        let body: [String: Any] = [
            "model": Self.defaultModel,
            "messages": [[
                "role": "user",
                "content": [["type": "text", "text": "请回复“连接成功”"]]
            ]]
        ]

        let requestBody = try JSONSerialization.data(withJSONObject: body, options: [])
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeoutInterval
        request.httpBody = requestBody

        let (data, response) = try await withTimeout(seconds: timeoutInterval) {
            try await self.session.data(for: request)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgnesError.invalidResponse
        }

        if httpResponse.statusCode >= 400 {
            let message = String(data: data, encoding: .utf8) ?? "未知错误"
            throw AgnesError.requestFailed("HTTP \(httpResponse.statusCode): \(message)")
        }

        guard let _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgnesError.invalidResponse
        }
    }

    /// Build a data URL using Base64 JSON payload. This is the preferred path for Agnes-compatible endpoints.
    func makeDataURL(from data: Data, mimeType: String = "image/jpeg") -> String? {
        let base64 = data.base64EncodedString()
        return "data:\(mimeType);base64,\(base64)"
    }

    /// Compress a UIImage to JPEG data while staying below the target size.
    func compressedJPEGData(from image: UIImage, maxBytes: Int = 900_000) -> Data? {
        guard let original = image.jpegData(compressionQuality: 0.95) else {
            return nil
        }
        if original.count <= maxBytes {
            return original
        }

        var quality: CGFloat = 0.8
        var data = original
        while data.count > maxBytes && quality > 0.2 {
            quality -= 0.1
            data = image.jpegData(compressionQuality: quality) ?? data
        }

        if data.count > maxBytes {
            let scaledSize = CGSize(width: image.size.width * 0.8, height: image.size.height * 0.8)
            UIGraphicsBeginImageContextWithOptions(scaledSize, false, 1.0)
            image.draw(in: CGRect(origin: .zero, size: scaledSize))
            let scaledImage = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()
            if let scaledImage,
               let scaledData = scaledImage.jpegData(compressionQuality: quality) {
                return scaledData
            }
        }

        return data
    }

    /// Optional helper for the URL-based fallback path.
    func uploadImageToImgBB(_ imageData: Data, apiKey: String, mimeType: String = "image/jpeg") async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        let boundaryText = "--\(boundary)\r\n"
        body.append(boundaryText.data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"key\"\r\n\r\n\(apiKey)\r\n".data(using: .utf8)!)
        body.append(boundaryText.data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"image.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: URL(string: "https://api.imgbb.com/1/upload")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AgnesError.requestFailed("ImgBB 上传失败")
        }

        guard let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataDict = jsonObject["data"] as? [String: Any],
              let url = dataDict["url"] as? String else {
            throw AgnesError.decodingFailed("ImgBB 响应缺少上传 URL")
        }

        return url
    }

    /// Configure the shared ImgBB API key used to upload images before sending to Agnes.
    static func configure(imgbbAPIKey: String?) {
        Self.sharedImgBBAPIKey = imgbbAPIKey
    }

    private static func resolveAPIKey() -> String? {
        if let bundleValue = Bundle.main.object(forInfoDictionaryKey: "AGNES_AI_API_KEY") as? String,
           !bundleValue.isEmpty {
            return bundleValue
        }

        if let defaultsValue = UserDefaults.standard.string(forKey: "agnes_ai_api_key"),
           !defaultsValue.isEmpty {
            return defaultsValue
        }

        return nil
    }

    private static func resolveImgBBAPIKey() -> String? {
        if let shared = Self.sharedImgBBAPIKey, !shared.isEmpty {
            return shared
        }
        if let bundleValue = Bundle.main.object(forInfoDictionaryKey: "IMGBB_API_KEY") as? String,
           !bundleValue.isEmpty {
            return bundleValue
        }
        if let defaultsValue = UserDefaults.standard.string(forKey: "imgbb_api_key"),
           !defaultsValue.isEmpty {
            return defaultsValue
        }
        return nil
    }

    private func makeRequestBody(prompt: String, imageDataURL: String) throws -> Data {
        let body: [String: Any] = [
            "model": Self.defaultModel,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": prompt],
                    ["type": "image_url", "image_url": ["url": imageDataURL]]
                ]
            ]]
        ]

        return try JSONSerialization.data(withJSONObject: body, options: [])
    }

    private func parseDescription(from data: Data) -> String? {
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard let choices = jsonObject["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            return nil
        }

        if let content = message["content"] as? String, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let contentBlocks = message["content"] as? [[String: Any]] {
            let textParts = contentBlocks.compactMap { block in
                block["text"] as? String
            }
            let concatenated = textParts.joined(separator: "\n")
            if !concatenated.isEmpty {
                return concatenated
            }
        }

        return nil
    }

    private func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @Sendable @escaping () async throws -> T) async throws -> T {
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
