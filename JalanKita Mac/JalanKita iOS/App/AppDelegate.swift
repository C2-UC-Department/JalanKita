//
//  AppDelegate.swift
//  JalanKita iOS
//
//  Minimal delegate whose only job is registering for silent remote
//  notifications and forwarding CloudKit pushes to CloudKitSyncEngine via
//  NotificationCenter — the engine is constructed inside AppModel, created
//  after this delegate (see JalanKita_iOSApp.swift), so it can't hold a
//  direct reference at callback time. Same decoupling shape as the Mac's
//  AppDelegate -> CloudKitSyncEngine.shareAcceptedNotification.
//

import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    static let remoteNotificationReceivedNotification = Notification.Name("AppDelegate.remoteNotificationReceived")
    static let userInfoKey = "userInfo"
    static let completionHandlerKey = "completionHandler"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[AppDelegate/iOS] didFailToRegisterForRemoteNotificationsWithError: \(error)")
    }

    /// Consulted by the system on every rotation attempt — see
    /// `OrientationLock`'s header comment for why the recording screen locks
    /// this to `.landscape` while it's on screen.
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        NotificationCenter.default.post(
            name: Self.remoteNotificationReceivedNotification,
            object: nil,
            userInfo: [Self.userInfoKey: userInfo, Self.completionHandlerKey: completionHandler]
        )
    }
}
