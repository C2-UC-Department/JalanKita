//
//  CloudKitNotificationParsing.swift
//  JalanKitaKit
//
//  Turns a raw remote-notification userInfo dict into a CKNotification, the
//  shared gate both platforms' AppDelegate -> CloudKitSyncEngine
//  notification-forwarding paths use before deciding to call syncNow().
//

import CloudKit
import Foundation

public enum CloudKitPushNotification {
    public enum Scope {
        case privateDatabase
        case sharedDatabase
        case zone(CKRecordZone.ID)
        case unknown
    }

    /// Parses a remote-notification userInfo dict (as delivered to
    /// didReceiveRemoteNotification on either platform) into a
    /// CKNotification — returns nil for anything that isn't a CloudKit
    /// push, so callers can ignore it rather than triggering a needless
    /// syncNow().
    public static func parse(userInfo: [AnyHashable: Any]) -> CKNotification? {
        guard let dict = userInfo as? [String: NSObject] else { return nil }
        return CKNotification(fromRemoteNotificationDictionary: dict)
    }

    /// What changed, as far as the notification itself says.
    public static func scope(for notification: CKNotification) -> Scope {
        if let dbNotification = notification as? CKDatabaseNotification {
            return dbNotification.databaseScope == .private ? .privateDatabase : .sharedDatabase
        }
        if let zoneNotification = notification as? CKRecordZoneNotification,
           let zoneID = zoneNotification.recordZoneID {
            return .zone(zoneID)
        }
        return .unknown
    }
}
