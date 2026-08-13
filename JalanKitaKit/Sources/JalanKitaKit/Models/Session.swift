//
//  Session.swift
//  JalanKitaKit
//
//  One recorded drive, somewhere between "just landed on disk" and "fully
//  processed and reported." Shared between JalanKita Mac (desk console) and
//  JalanKita iOS (recording app) so both speak the same session vocabulary.
//

import Foundation

public struct Session: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var roadName: String
    public var kmMarker: String?
    public var date: String
    public var surveyor: Surveyor
    public var clipCount: Int
    public var duration: String
    public var distanceKm: Double
    public var gpsAccuracyM: Int?
    public var gpsHz: Double?
    public var gpsGapNote: String?
    public var sizeGB: Double
    public var status: SessionStatus
    public var segmentCount: Int?
    public var selectedForBatch: Bool = false

    /// Canonical values behind the `date`/`duration` display strings, used
    /// for CloudKit sync and any locale-independent computation — `date`/
    /// `duration` are pre-formatted for display and are NOT synced
    /// verbatim (see `CloudKitSchema.SessionField`), so each platform can
    /// format its own display string from these. `nil` for sessions that
    /// predate this field (mock/manual-upload sessions) or haven't synced.
    public var recordedDate: Date?
    public var durationSeconds: Double?

    public init(id: String, roadName: String, kmMarker: String? = nil, date: String, surveyor: Surveyor,
                clipCount: Int, duration: String, distanceKm: Double, gpsAccuracyM: Int? = nil,
                gpsHz: Double? = nil, gpsGapNote: String? = nil, sizeGB: Double, status: SessionStatus,
                segmentCount: Int? = nil, selectedForBatch: Bool = false, recordedDate: Date? = nil,
                durationSeconds: Double? = nil) {
        self.id = id
        self.roadName = roadName
        self.kmMarker = kmMarker
        self.date = date
        self.surveyor = surveyor
        self.clipCount = clipCount
        self.duration = duration
        self.distanceKm = distanceKm
        self.gpsAccuracyM = gpsAccuracyM
        self.gpsHz = gpsHz
        self.gpsGapNote = gpsGapNote
        self.sizeGB = sizeGB
        self.status = status
        self.segmentCount = segmentCount
        self.selectedForBatch = selectedForBatch
        self.recordedDate = recordedDate
        self.durationSeconds = durationSeconds
    }
}

extension Session {
    /// Indonesian-formatted duration string, shared by every place a
    /// `Session`'s `durationSeconds` becomes display text. A sub-minute
    /// recording (a quick test clip, a short segment) previously fell
    /// straight to "0 m" — indistinguishable from missing data.
    public static func formattedDuration(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        let total = Int(seconds)
        if total < 60 { return "\(total) dtk" }
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h) j \(m) m" : "\(m) m"
    }
}
