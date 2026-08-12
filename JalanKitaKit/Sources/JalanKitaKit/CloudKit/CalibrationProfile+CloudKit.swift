//
//  CalibrationProfile+CloudKit.swift
//  JalanKitaKit
//

import CloudKit
import Foundation

extension CalibrationProfile: CKRecordConvertible {
    public static var recordType: String { CloudKitSchema.RecordType.calibrationProfile }

    public func populate(_ record: CKRecord) {
        record[CloudKitSchema.CalibrationField.mountLabel] = mountLabel as CKRecordValue
        record[CloudKitSchema.CalibrationField.knownWidthMeters] = knownWidthMeters as CKRecordValue
        record[CloudKitSchema.CalibrationField.createdAt] = createdAt as CKRecordValue
        record[CloudKitSchema.CalibrationField.surveyorID] = surveyorID as CKRecordValue
    }

    /// `frameFilename` is per-device local staging, not itself a synced
    /// field — reconstructed here as empty; whichever sync engine
    /// downloads the `frameAsset` fills in a real local filename after.
    public init?(record: CKRecord) {
        guard
            let mountLabel = record[CloudKitSchema.CalibrationField.mountLabel] as? String,
            let knownWidthMeters = record[CloudKitSchema.CalibrationField.knownWidthMeters] as? Double,
            let createdAt = record[CloudKitSchema.CalibrationField.createdAt] as? Date,
            let surveyorID = record[CloudKitSchema.CalibrationField.surveyorID] as? String
        else { return nil }
        self.init(mountLabel: mountLabel, knownWidthMeters: knownWidthMeters, frameFilename: "",
                  createdAt: createdAt, surveyorID: surveyorID)
    }

    /// One calibration profile per surveyor in v1 — deterministic record ID.
    public func recordID(zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: "calibration-\(surveyorID)", zoneID: zoneID)
    }
}
