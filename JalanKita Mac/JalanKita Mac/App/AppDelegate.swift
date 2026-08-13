//
//  AppDelegate.swift
//  JalanKita Mac
//
//  Handles the automatic half of CKShare acceptance: macOS can route a
//  clicked icloud.com/share/... link (e.g. opened from Mail or Messages
//  on the Mac itself) to this delegate method. That OS-level attribution
//  is an undocumented heuristic with no reliable way to test
//  deterministically, so this is a secondary path — the primary,
//  relied-upon path for v1 is the "paste invite link" field in
//  CloudSyncSettingsView. Both funnel into the same
//  `CloudKitSyncEngine.acceptShare` logic via a notification, since this
//  delegate is constructed before `AppModel`/the sync engine exist (see
//  `JalanKita_MacApp.swift`) and so can't hold a direct reference.
//

import AppKit
import CloudKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let remoteNotificationReceivedNotification = Notification.Name("AppDelegate.remoteNotificationReceived")
    static let userInfoKey = "userInfo"

    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        NotificationCenter.default.post(
            name: CloudKitSyncEngine.shareAcceptedNotification,
            object: nil,
            userInfo: [CloudKitSyncEngine.shareMetadataUserInfoKey: metadata]
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.registerForRemoteNotifications()
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[AppDelegate/Mac] didFailToRegisterForRemoteNotificationsWithError: \(error)")
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        NotificationCenter.default.post(
            name: Self.remoteNotificationReceivedNotification,
            object: nil,
            userInfo: [Self.userInfoKey: userInfo]
        )
    }
}
