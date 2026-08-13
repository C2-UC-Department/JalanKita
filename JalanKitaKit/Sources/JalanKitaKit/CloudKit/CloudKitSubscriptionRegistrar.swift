//
//  CloudKitSubscriptionRegistrar.swift
//  JalanKitaKit
//
//  Idempotent CKSubscription registration, mirroring the "check a
//  UserDefaults flag, create once, set the flag" pattern each platform's
//  CloudKitSyncEngine already uses for zone provisioning.
//

import CloudKit
import Foundation

public enum CloudKitSubscriptionRegistrar {
    public static func ensureSubscription(
        _ subscription: CKSubscription,
        database: CKDatabase,
        idempotencyKey: String
    ) async throws {
        guard !UserDefaults.standard.bool(forKey: idempotencyKey) else { return }
        _ = try await database.modifySubscriptions(saving: [subscription], deleting: [])
        UserDefaults.standard.set(true, forKey: idempotencyKey)
    }
}

extension CKSubscription.NotificationInfo {
    /// Silent/background push — no alert/sound/badge, just wakes the app to
    /// call syncNow(). Both platforms' subscriptions use this exclusively.
    public static var silentContentAvailable: CKSubscription.NotificationInfo {
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        return info
    }
}
