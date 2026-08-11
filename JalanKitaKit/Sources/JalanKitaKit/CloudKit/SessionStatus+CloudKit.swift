//
//  SessionStatus+CloudKit.swift
//  JalanKitaKit
//
//  SessionStatus is a payload enum (.segmenting(progress:), .degraded(reason:),
//  .failed(reason:)), so it can't map to one native CKRecord field. This maps
//  it to a discriminator string plus two optional payload fields instead of
//  blobbing it into JSON — deliberately, since both iOS and Mac write to this
//  record over time (iOS sets readyToProcess/degraded at creation, Mac owns
//  the transition through segmenting/done/failed) and a real field per
//  concern makes that write-authority split and CKError.serverRecordChanged
//  conflict handling legible, instead of two writers racing to replace one
//  opaque blob.
//

import Foundation

extension SessionStatus {
    private enum Case {
        static let readyToProcess = "readyToProcess"
        static let segmenting = "segmenting"
        static let degraded = "degraded"
        static let done = "done"
        static let failed = "failed"
    }

    /// Discriminator for `CloudKitSchema.SessionField.statusCase`.
    public var cloudKitCaseTag: String {
        switch self {
        case .readyToProcess: Case.readyToProcess
        case .segmenting: Case.segmenting
        case .degraded: Case.degraded
        case .done: Case.done
        case .failed: Case.failed
        }
    }

    /// Payload for `CloudKitSchema.SessionField.statusProgress` — populated
    /// only when `cloudKitCaseTag == "segmenting"`.
    public var cloudKitProgress: Double? {
        if case .segmenting(let progress) = self { progress } else { nil }
    }

    /// Payload for `CloudKitSchema.SessionField.statusReason` — populated for
    /// `.degraded`/`.failed` (mutually exclusive by discriminator, so one
    /// field safely serves both).
    public var cloudKitReason: String? {
        switch self {
        case .degraded(let reason): reason
        case .failed(let reason): reason
        default: nil
        }
    }

    /// Reconstructs a `SessionStatus` from the three CKRecord fields above.
    public init?(cloudKitCaseTag: String, progress: Double?, reason: String?) {
        switch cloudKitCaseTag {
        case Case.readyToProcess: self = .readyToProcess
        case Case.segmenting: self = .segmenting(progress: progress ?? 0)
        case Case.degraded: self = .degraded(reason: reason ?? "")
        case Case.done: self = .done
        case Case.failed: self = .failed(reason: reason ?? "")
        default: return nil
        }
    }
}
