//
//  CKRecordConvertible.swift
//  JalanKitaKit
//
//  A small shared mapping pattern so both targets build/read CKRecords for
//  the same type identically instead of each hand-rolling field access.
//  Deliberately scoped to scalar/reference fields only — CKAsset fields
//  (video clips, GPS CSV, calibration frame) are handled separately by
//  each sync engine, since building a CKAsset requires a local file on
//  disk that this protocol has no business owning.
//

import CloudKit
import Foundation

public protocol CKRecordConvertible: Sendable {
    static var recordType: String { get }

    /// Writes this value's scalar/reference fields onto `record`. Callers
    /// attach any CKAsset fields separately.
    func populate(_ record: CKRecord)

    /// Reconstructs the scalar/reference-only portion of this value from a
    /// fetched record. Callers read any CKAsset fields off the same record
    /// separately.
    init?(record: CKRecord)
}

extension CKRecordConvertible {
    public func makeRecord(recordID: CKRecord.ID) -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        populate(record)
        return record
    }
}
