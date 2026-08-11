//
//  Session+CloudKit.swift
//  JalanKitaKit
//

import CloudKit
import Foundation

extension Session: CKRecordConvertible {
    public static var recordType: String { CloudKitSchema.RecordType.session }

    public func populate(_ record: CKRecord) {
        record[CloudKitSchema.SessionField.roadName] = roadName as CKRecordValue
        record[CloudKitSchema.SessionField.kmMarker] = kmMarker as CKRecordValue?
        record[CloudKitSchema.SessionField.recordedDate] = recordedDate as CKRecordValue?
        record[CloudKitSchema.SessionField.durationSeconds] = durationSeconds as CKRecordValue?
        record[CloudKitSchema.SessionField.surveyorID] = surveyor.id as CKRecordValue
        record[CloudKitSchema.SessionField.surveyorName] = surveyor.name as CKRecordValue
        record[CloudKitSchema.SessionField.clipCount] = clipCount as CKRecordValue
        record[CloudKitSchema.SessionField.distanceKm] = distanceKm as CKRecordValue
        record[CloudKitSchema.SessionField.gpsAccuracyM] = gpsAccuracyM as CKRecordValue?
        record[CloudKitSchema.SessionField.gpsHz] = gpsHz as CKRecordValue?
        record[CloudKitSchema.SessionField.gpsGapNote] = gpsGapNote as CKRecordValue?
        record[CloudKitSchema.SessionField.sizeGB] = sizeGB as CKRecordValue
        record[CloudKitSchema.SessionField.segmentCount] = segmentCount as CKRecordValue?
        record[CloudKitSchema.SessionField.schemaVersion] = 1 as CKRecordValue
        record[CloudKitSchema.SessionField.statusCase] = status.cloudKitCaseTag as CKRecordValue
        record[CloudKitSchema.SessionField.statusProgress] = status.cloudKitProgress as CKRecordValue?
        record[CloudKitSchema.SessionField.statusReason] = status.cloudKitReason as CKRecordValue?
    }

    public init?(record: CKRecord) {
        guard
            let roadName = record[CloudKitSchema.SessionField.roadName] as? String,
            let surveyorID = record[CloudKitSchema.SessionField.surveyorID] as? String,
            let surveyorName = record[CloudKitSchema.SessionField.surveyorName] as? String,
            let clipCount = record[CloudKitSchema.SessionField.clipCount] as? Int,
            let distanceKm = record[CloudKitSchema.SessionField.distanceKm] as? Double,
            let sizeGB = record[CloudKitSchema.SessionField.sizeGB] as? Double,
            let statusCase = record[CloudKitSchema.SessionField.statusCase] as? String,
            let status = SessionStatus(
                cloudKitCaseTag: statusCase,
                progress: record[CloudKitSchema.SessionField.statusProgress] as? Double,
                reason: record[CloudKitSchema.SessionField.statusReason] as? String
            )
        else { return nil }

        let recordedDate = record[CloudKitSchema.SessionField.recordedDate] as? Date
        let durationSeconds = record[CloudKitSchema.SessionField.durationSeconds] as? Double

        self.init(
            id: record.recordID.recordName,
            roadName: roadName,
            kmMarker: record[CloudKitSchema.SessionField.kmMarker] as? String,
            date: Session.displayDate(recordedDate),
            surveyor: Surveyor(id: surveyorID, name: surveyorName),
            clipCount: clipCount,
            duration: Session.displayDuration(durationSeconds),
            distanceKm: distanceKm,
            gpsAccuracyM: record[CloudKitSchema.SessionField.gpsAccuracyM] as? Int,
            gpsHz: record[CloudKitSchema.SessionField.gpsHz] as? Double,
            gpsGapNote: record[CloudKitSchema.SessionField.gpsGapNote] as? String,
            sizeGB: sizeGB,
            status: status,
            segmentCount: record[CloudKitSchema.SessionField.segmentCount] as? Int,
            recordedDate: recordedDate,
            durationSeconds: durationSeconds
        )
    }

    /// `date`/`duration` are locale-formatted display strings, not synced
    /// verbatim (see `CloudKitSchema.SessionField`) — this reformats the
    /// canonical `recordedDate`/`durationSeconds` locally on whichever
    /// platform just fetched the record.
    private static func displayDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func displayDuration(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h) j \(m) m" : "\(m) m"
    }
}
