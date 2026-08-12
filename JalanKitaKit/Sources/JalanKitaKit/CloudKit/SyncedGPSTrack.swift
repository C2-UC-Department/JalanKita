//
//  SyncedGPSTrack.swift
//  JalanKitaKit
//
//  One session's GPS log — this is the artifact the whole app exists to
//  produce (see the iOS app's LocationTracker doc-comments): with no
//  manual damage/blocked flagging, this track is the only thing that lets
//  the desk pipeline attach a location to whatever it detects. Synced as
//  a CKAsset (a 1-3hr session at >=1Hz is ~10k rows) plus cheap
//  denormalized summary fields so a session-list refresh never has to
//  download the whole CSV just to show a preview.
//

import CloudKit
import Foundation

public struct SyncedGPSTrack: Codable, Sendable {
    public let sessionID: String
    public var pointCount: Int
    public var minLatitude: Double
    public var minLongitude: Double
    public var maxLatitude: Double
    public var maxLongitude: Double

    public init(sessionID: String, pointCount: Int, minLatitude: Double, minLongitude: Double,
                maxLatitude: Double, maxLongitude: Double) {
        self.sessionID = sessionID
        self.pointCount = pointCount
        self.minLatitude = minLatitude
        self.minLongitude = minLongitude
        self.maxLatitude = maxLatitude
        self.maxLongitude = maxLongitude
    }
}

extension SyncedGPSTrack: CKRecordConvertible {
    public static var recordType: String { CloudKitSchema.RecordType.gpsTrack }

    public func populate(_ record: CKRecord) {
        record[CloudKitSchema.GPSTrackField.session] = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: sessionID, zoneID: record.recordID.zoneID),
            action: .deleteSelf
        )
        record[CloudKitSchema.GPSTrackField.pointCount] = pointCount as CKRecordValue
        record[CloudKitSchema.GPSTrackField.minLatitude] = minLatitude as CKRecordValue
        record[CloudKitSchema.GPSTrackField.minLongitude] = minLongitude as CKRecordValue
        record[CloudKitSchema.GPSTrackField.maxLatitude] = maxLatitude as CKRecordValue
        record[CloudKitSchema.GPSTrackField.maxLongitude] = maxLongitude as CKRecordValue
    }

    public init?(record: CKRecord) {
        guard
            let sessionRef = record[CloudKitSchema.GPSTrackField.session] as? CKRecord.Reference,
            let pointCount = record[CloudKitSchema.GPSTrackField.pointCount] as? Int,
            let minLatitude = record[CloudKitSchema.GPSTrackField.minLatitude] as? Double,
            let minLongitude = record[CloudKitSchema.GPSTrackField.minLongitude] as? Double,
            let maxLatitude = record[CloudKitSchema.GPSTrackField.maxLatitude] as? Double,
            let maxLongitude = record[CloudKitSchema.GPSTrackField.maxLongitude] as? Double
        else { return nil }
        self.init(sessionID: sessionRef.recordID.recordName, pointCount: pointCount, minLatitude: minLatitude,
                  minLongitude: minLongitude, maxLatitude: maxLatitude, maxLongitude: maxLongitude)
    }

    /// One GPS track per session — deterministic record ID.
    public func recordID(zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(sessionID)#gps", zoneID: zoneID)
    }
}
