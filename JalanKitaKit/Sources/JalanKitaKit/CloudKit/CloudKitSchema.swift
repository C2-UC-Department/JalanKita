//
//  CloudKitSchema.swift
//  JalanKitaKit
//
//  Record-type and field-key string constants shared by both targets, so
//  iOS (writer of Session/Clip/GPSTrack/CalibrationProfile) and Mac
//  (writer of ParkingResult/SegmentResult, reader of everything) never
//  drift on a key spelling. Plain Foundation, no CloudKit import — both
//  targets that DO import CloudKit reference these by name.
//
//  All record types for one surveyor live in one custom CKRecordZone
//  (`zoneName(surveyorID:)`), so a single zone-wide CKShare (Phase 2 step
//  2) covers every record that surveyor ever creates — no per-session or
//  per-record re-invite.
//

import Foundation

public enum CloudKitSchema {
    public static let containerIdentifier = "iCloud.com.biru.JalanKita"

    public static func zoneName(surveyorID: String) -> String {
        "Surveyor-\(surveyorID)"
    }

    public enum RecordType {
        public static let session = "Session"
        public static let clip = "Clip"
        public static let gpsTrack = "GPSTrack"
        public static let calibrationProfile = "CalibrationProfile"
        public static let parkingResult = "ParkingResult"
        public static let segmentResult = "SegmentResult"
    }

    public enum SubscriptionID {
        public static func iOSPrivateZone(surveyorID: String) -> String {
            "sub-zone-\(zoneName(surveyorID: surveyorID))"
        }
        public static let macPrivateDatabase = "sub-mac-private-db"
        public static let macSharedDatabase = "sub-mac-shared-db"
    }

    /// `Session.date`/`.duration` are locale-formatted display strings and are
    /// deliberately NOT synced verbatim — `recordedDate`/`durationSeconds` are
    /// the canonical values; each platform formats its own display string
    /// locally from those.
    public enum SessionField {
        public static let roadName = "roadName"
        public static let kmMarker = "kmMarker"
        public static let recordedDate = "recordedDate"
        public static let durationSeconds = "durationSeconds"
        public static let surveyorID = "surveyorID"
        public static let surveyorName = "surveyorName"
        public static let clipCount = "clipCount"
        public static let distanceKm = "distanceKm"
        public static let gpsAccuracyM = "gpsAccuracyM"
        public static let gpsHz = "gpsHz"
        public static let gpsGapNote = "gpsGapNote"
        public static let sizeGB = "sizeGB"
        public static let segmentCount = "segmentCount"
        public static let schemaVersion = "schemaVersion"
        /// See `SessionStatus+CloudKit.swift` — discriminator + payload, not a blob.
        public static let statusCase = "statusCase"
        public static let statusProgress = "statusProgress"
        public static let statusReason = "statusReason"
    }

    public enum ClipField {
        public static let session = "session"
        public static let clipIndex = "clipIndex"
        public static let videoAsset = "videoAsset"
        public static let durationSeconds = "durationSeconds"
    }

    public enum GPSTrackField {
        public static let session = "session"
        public static let csvAsset = "csvAsset"
        public static let pointCount = "pointCount"
        public static let minLatitude = "minLatitude"
        public static let minLongitude = "minLongitude"
        public static let maxLatitude = "maxLatitude"
        public static let maxLongitude = "maxLongitude"
    }

    public enum CalibrationField {
        public static let mountLabel = "mountLabel"
        public static let knownWidthMeters = "knownWidthMeters"
        public static let frameAsset = "frameAsset"
        public static let createdAt = "createdAt"
        public static let surveyorID = "surveyorID"
    }

    public enum ParkingResultField {
        public static let session = "session"
        public static let sourceKind = "sourceKind"
        public static let carTrackID = "carTrackID"
        public static let disturbance = "disturbance"
        public static let imageAsset = "imageAsset"
        public static let imageWidth = "imageWidth"
        public static let imageHeight = "imageHeight"
        public static let bevAsset = "bevAsset"
        public static let summaryJSON = "summaryJSON"
        public static let createdAt = "createdAt"
    }

    /// Schema-only stub — no producer exists yet (the road-damage pipeline is
    /// still mock data on the Mac). Created now for forward-compatibility.
    public enum SegmentResultField {
        public static let session = "session"
        public static let severityRaw = "severityRaw"
        public static let score = "score"
        public static let roadName = "roadName"
        public static let kmMarker = "kmMarker"
        public static let segmentLabel = "segmentLabel"
        public static let date = "date"
        public static let defectTypesRaw = "defectTypesRaw"
        public static let hasBlockedParking = "hasBlockedParking"
        public static let areaSqm = "areaSqm"
    }
}
