//
//  AppDelegate.swift
//  echo
//
//  Created by rkny6 on 4/17/26.
//

import UIKit
import UserNotifications
import BackgroundTasks

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BackgroundTaskService.shared.registerBackgroundTasks()
        // Single process-wide notification owner (see NotificationDelegate).
        // Do not assign a second delegate from NotificationService later.
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        return true
    }
}
