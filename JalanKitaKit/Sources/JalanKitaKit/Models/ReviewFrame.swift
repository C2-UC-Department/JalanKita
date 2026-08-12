//
//  ReviewFrame.swift
//  JalanKitaKit
//

import Foundation
import CoreGraphics

/// A reviewed frame: the unit of work on the Peninjauan Temuan screen. Real
/// road-damage findings (YOLO11s boxes, ADR-015) — parking-disturbance results
/// go to ParkingAnalysis/"Tinjauan Parkir" instead.
///
/// Every field here has a source on disk. Where one doesn't exist the field is
/// optional and renders as "tidak tersedia" rather than carrying an invented
/// value — `indexInQueue`/`totalInQueue` are gone entirely (they were hardcoded
/// 12/41 and are now derived from the queue's actual contents), and `coordinate`
/// / `gpsAccuracyM` are nil because `frames_provenance.csv` records
/// `gps_source=none` with empty lat/lon for all 958 Surabaya frames.
public struct ReviewFrame: Identifiable, Hashable, Codable, Sendable {
    public let id: String

    /// The clip this frame was sampled from, e.g. "IMG_0040.MOV" — stands in for
    /// a road name, which no source on disk actually knows.
    public let sourceClip: String

    /// Real values from `frames_provenance.csv`: the decoder's own frame index
    /// and presentation timestamp, not a formatted guess.
    public let frameNumber: String
    public let timecode: String
    public let capturedAt: String?

    public let severity: Severity
    public let score: Int

    /// True while the score comes from a detector that has never been validated
    /// against Indonesian box labels — see the domain-gap caveat in ADR-015.
    public let isProvisional: Bool

    /// nil until a GPS log exists; segment/km binning needs one (severity.yaml's
    /// `segment_length_m` is unreachable without it).
    public let segmentLabel: String?
    public let kmMarker: String?
    public let coordinate: String?
    public let gpsAccuracyM: Int?

    public let findings: [Finding]

    /// `startScore` minus `deductions` lands exactly on `score`, because both
    /// come from Python: `effective_deductions()` is the per-box split of the
    /// same sum `grade_segment()` turns into `condition`. Nothing is recomputed
    /// in Swift — the two implementations used to disagree (ADR-016).
    public let startScore: Int
    public let deductions: [SeverityDeduction]

    /// The frame on disk, plus its recorded pixel size so the canvas can lock the
    /// correct aspect ratio without decoding the image first.
    public let imageURL: URL
    public let imageWidth: Int
    public let imageHeight: Int

    public var aspectRatio: CGFloat {
        guard imageWidth > 0, imageHeight > 0 else { return 3.0 / 4.0 }
        return CGFloat(imageWidth) / CGFloat(imageHeight)
    }

    public init(id: String, sourceClip: String, frameNumber: String, timecode: String, capturedAt: String? = nil,
                severity: Severity, score: Int, isProvisional: Bool, segmentLabel: String? = nil,
                kmMarker: String? = nil, coordinate: String? = nil, gpsAccuracyM: Int? = nil, findings: [Finding],
                startScore: Int, deductions: [SeverityDeduction], imageURL: URL, imageWidth: Int, imageHeight: Int) {
        self.id = id
        self.sourceClip = sourceClip
        self.frameNumber = frameNumber
        self.timecode = timecode
        self.capturedAt = capturedAt
        self.severity = severity
        self.score = score
        self.isProvisional = isProvisional
        self.segmentLabel = segmentLabel
        self.kmMarker = kmMarker
        self.coordinate = coordinate
        self.gpsAccuracyM = gpsAccuracyM
        self.findings = findings
        self.startScore = startScore
        self.deductions = deductions
        self.imageURL = imageURL
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }
}
