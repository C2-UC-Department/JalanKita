//
//  SyncedParkingResult.swift
//  JalanKitaKit
//
//  Real pipeline output, Mac -> cloud -> iPhone. Distinct from
//  `ParkingAnalysis` (whose `imageURL`/`bevPNGPath` are local file paths
//  on whichever machine produced them) — this is the CKRecord-shaped
//  projection of one, built by the Mac after a real analysis completes.
//
//  `summaryJSON` is a deliberate blob exception to this schema's usual
//  discriminator-fields approach (see `SessionStatus+CloudKit.swift`):
//  `DisturbanceSummary` already mirrors a stable JSON shape from the
//  Python worker, is Mac-written only, and iPhone-read-only — none of the
//  bidirectional-write conflict concerns that ruled out a blob for
//  `SessionStatus` apply here.
//

import CloudKit
import Foundation

public struct SyncedParkingResult: Identifiable, Sendable {
    public let sessionID: String
    public let candidateID: String
    public var sourceKind: String
    public var carTrackID: Int?
    /// Mirrors `CarCandidate.disturbance` (v13's own PARKED/violation call) —
    /// nil for a manual photo upload, which has no `CarCandidate` behind it.
    public var disturbance: Bool?
    public var imageWidth: Int
    public var imageHeight: Int
    public var summaryJSON: String
    public var createdAt: Date

    public var id: String { "\(sessionID)#\(candidateID)" }

    public init(sessionID: String, candidateID: String, sourceKind: String, carTrackID: Int? = nil,
                disturbance: Bool? = nil, imageWidth: Int, imageHeight: Int, summaryJSON: String, createdAt: Date = Date()) {
        self.sessionID = sessionID
        self.candidateID = candidateID
        self.sourceKind = sourceKind
        self.carTrackID = carTrackID
        self.disturbance = disturbance
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.summaryJSON = summaryJSON
        self.createdAt = createdAt
    }
}

extension SyncedParkingResult: CKRecordConvertible {
    public static var recordType: String { CloudKitSchema.RecordType.parkingResult }

    public func populate(_ record: CKRecord) {
        record[CloudKitSchema.ParkingResultField.session] = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: sessionID, zoneID: record.recordID.zoneID),
            action: .deleteSelf
        )
        record[CloudKitSchema.ParkingResultField.sourceKind] = sourceKind as CKRecordValue
        record[CloudKitSchema.ParkingResultField.carTrackID] = carTrackID as CKRecordValue?
        record[CloudKitSchema.ParkingResultField.disturbance] = disturbance as CKRecordValue?
        record[CloudKitSchema.ParkingResultField.imageWidth] = imageWidth as CKRecordValue
        record[CloudKitSchema.ParkingResultField.imageHeight] = imageHeight as CKRecordValue
        record[CloudKitSchema.ParkingResultField.summaryJSON] = summaryJSON as CKRecordValue
        record[CloudKitSchema.ParkingResultField.createdAt] = createdAt as CKRecordValue
    }

    public init?(record: CKRecord) {
        guard
            let sessionRef = record[CloudKitSchema.ParkingResultField.session] as? CKRecord.Reference,
            let sourceKind = record[CloudKitSchema.ParkingResultField.sourceKind] as? String,
            let imageWidth = record[CloudKitSchema.ParkingResultField.imageWidth] as? Int,
            let imageHeight = record[CloudKitSchema.ParkingResultField.imageHeight] as? Int,
            let summaryJSON = record[CloudKitSchema.ParkingResultField.summaryJSON] as? String,
            let createdAt = record[CloudKitSchema.ParkingResultField.createdAt] as? Date
        else { return nil }
        let candidateID = record.recordID.recordName.split(separator: "#", maxSplits: 1).last
            .map(String.init) ?? record.recordID.recordName
        self.init(
            sessionID: sessionRef.recordID.recordName,
            candidateID: candidateID,
            sourceKind: sourceKind,
            carTrackID: record[CloudKitSchema.ParkingResultField.carTrackID] as? Int,
            disturbance: record[CloudKitSchema.ParkingResultField.disturbance] as? Bool,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            summaryJSON: summaryJSON,
            createdAt: createdAt
        )
    }

    public func recordID(zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: id, zoneID: zoneID)
    }
}
