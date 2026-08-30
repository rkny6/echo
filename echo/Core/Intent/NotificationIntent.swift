//
//  NotificationIntent.swift
//  echo
//
//  Created by rkny6 on 4/21/26.
//

import Foundation

struct NotificationIntent {
    let kind: NotificationKind  // Type-safe notification kind
    let priority: Int           // Priority for conflict control
    let context: String         // Context for message generation
    let source: String          // Source for debugging
    let timestamp: Date         // When intent was created
    
    init(
        kind: NotificationKind,
        priority: Int = 1,
        context: String = "",
        source: String = "",
        timestamp: Date = Date()
    ) {
        self.kind = kind
        self.priority = priority
        self.context = context
        self.source = source
        self.timestamp = timestamp
    }
}
