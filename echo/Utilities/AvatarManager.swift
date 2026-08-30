import SwiftUI
import UIKit

/// Avatar storage and management utility
class AvatarManager {
    static let shared = AvatarManager()
    
    private let fileManager = FileManager.default
    private let avatarsDirectory: URL
    
    private init() {
        // Get the documents directory
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        avatarsDirectory = documentsPath.appendingPathComponent("avatars", isDirectory: true)
        
        // Create avatars directory if it doesn't exist
        try? fileManager.createDirectory(at: avatarsDirectory, withIntermediateDirectories: true)
    }
    
    /// Save avatar image to disk
    /// - Parameters:
    ///   - image: The image to save
    ///   - identifier: Unique identifier for the avatar
    /// - Returns: The filename of the saved avatar
    func saveAvatar(_ image: UIImage, identifier: String) -> String {
        let filename = "\(identifier)_\(UUID().uuidString).jpg"
        let fileURL = avatarsDirectory.appendingPathComponent(filename)
        
        if let jpegData = image.jpegData(compressionQuality: 0.8) {
            try? jpegData.write(to: fileURL)
        }
        
        return filename
    }
    
    /// Load avatar image from disk
    /// - Parameter filename: The filename of the avatar
    /// - Returns: The loaded image, or nil if not found
    func loadAvatar(filename: String) -> UIImage? {
        // Check if it's a default avatar first
        if filename == "user_default" || filename == "character_default" {
            return nil // Will use system default in views
        }
        
        let fileURL = avatarsDirectory.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        
        return UIImage(contentsOfFile: fileURL.path)
    }
    
    /// Delete avatar from disk
    /// - Parameter filename: The filename of the avatar to delete
    func deleteAvatar(filename: String) {
        let fileURL = avatarsDirectory.appendingPathComponent(filename)
        try? fileManager.removeItem(at: fileURL)
    }
    
    /// Get SwiftUI Image for avatar
    /// - Parameters:
    ///   - filename: The filename of the avatar
    ///   - isUser: Whether it's a user avatar or character avatar
    /// - Returns: SwiftUI Image
    func avatarImage(filename: String, isUser: Bool) -> Image {
        if let uiImage = loadAvatar(filename: filename) {
            return Image(uiImage: uiImage)
        }
        
        // Default avatar
        let systemName = isUser ? "person.circle.fill" : "person.circle.fill"
        return Image(systemName: systemName)
    }
}
