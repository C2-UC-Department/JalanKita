//
//  SyncedClip.swift
//  JalanKitaKit
//
//  One `clip_<index>.mov` file, referencing its parent Session. A child
//  record per clip (not one multi-asset Session record) because
//  CaptureSessionController already produces an independent file per
//  pause/resume boundary and Session.clipCount already models a session
//  as N clips — each clip uploads/downloads and retries independently,
//  and the Mac can verify `clipCount` against the fetched Clip record
//  count to detect a partial sync.
//
//  The video itself is a CKAsset, attached/read by each sync engine (not
//  by this type — building a CKAsset requires a local file on disk).
//

import CloudKit
import Foundation

public struct SyncedClip: Identifiable, Sendable {
    public let sessionID: String
    public let clipIndex: Int
    public var durationSeconds: Double?

    public var id: String { "\(sessionID)#\(clipIndex)" }

    public init(sessionID: String, clipIndex: Int, durationSeconds: Double? = nil) {
        self.sessionID = sessionID
        self.clipIndex = clipIndex
        self.durationSeconds = durationSeconds
    }
}

extension SyncedClip: CKRecordConvertible {
    public static var recordType: String { CloudKitSchema.RecordType.clip }

    public func populate(_ record: CKRecord) {
        record[CloudKitSchema.ClipField.session] = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: sessionID, zoneID: record.recordID.zoneID),
            action: .deleteSelf
        )
        record[CloudKitSchema.ClipField.clipIndex] = clipIndex as CKRecordValue
        record[CloudKitSchema.ClipField.durationSeconds] = durationSeconds as CKRecordValue?
    }

    public init?(record: CKRecord) {
        guard
            let sessionRef = record[CloudKitSchema.ClipField.session] as? CKRecord.Reference,
            let clipIndex = record[CloudKitSchema.ClipField.clipIndex] as? Int
        else { return nil }
        self.init(
            sessionID: sessionRef.recordID.recordName,
            clipIndex: clipIndex,
            durationSeconds: record[CloudKitSchema.ClipField.durationSeconds] as? Double
        )
    }

    /// Deterministic record ID so re-uploading the same clip updates rather
    /// than duplicates.
    public func recordID(zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: id, zoneID: zoneID)
    }
}
