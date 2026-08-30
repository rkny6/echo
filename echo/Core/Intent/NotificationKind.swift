//
//  NotificationKind.swift
//  echo
//
//  Created by rkny6 on 4/22/26.
//

import Foundation

/// Type-safe notification kinds to replace string-based kinds
enum NotificationKind: String, Codable, Equatable {
    case sleep      // Morning/sleep-related notifications
    case activity   // Activity/movement-related notifications
    case contextual // General contextual observations
    case outing     // Location-based (going out) notifications
    
    var displayName: String {
        switch self {
        case .sleep:      return "Sleep"
        case .activity:   return "Activity"
        case .contextual: return "Contextual"
        case .outing:     return "Outing"
        }
    }
}
