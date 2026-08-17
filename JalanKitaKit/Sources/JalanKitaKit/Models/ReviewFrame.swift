//
//  ReviewFrame.swift
//  JalanKitaKit
//

import Foundation
import CoreGraphics

/// One sampled video frame carrying real road-damage findings (YOLO11s boxes,
/// ADR-015). Parking-disturbance results go to `ParkingAnalysis` instead — the two
/// verticals share a session and a timeline but never a record.
///
/// ⚠️ The standalone Peninjauan screen this type was built for no longer exists.
/// Road damage is now stage 3 of the video pipeline and is reviewed alongside the
/// parking results, which is why `sessionRelativeSeconds` exists.
///
/// Every field here has a source on disk. Where one doesn't exist the field is
/// optional and renders as "tidak tersedia" rather than carrying an invented
/// value — `coordinate` is nil whenever the session's extraction had no GPS
/// track to join (`frames_provenance.csv`'s `gps_source=none`), populated with
/// a real `"lat,lon"` when it did (`RoadDamageFrameProvenance`). `gpsAccuracyM`
/// stays nil always — no source on disk carries an accuracy figure yet.
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

    /// The human-readable provenance caveat that belongs beside this frame's score.
    ///
    /// Per-frame rather than per-screen, because a session's frames genuinely mix
    /// sources — a banner at the top of the screen would caveat the wrong ones. It
    /// reaches the app straight off the wire (`RoadDamageResponse.warnings`), so a
    /// reviewer never has to know which path produced what they are looking at.
    ///
    /// `isProvisional` is the alarm; this is the reason. The two travel together.
    public let warnings: String?

    /// Where this frame sits on the session's video timeline, in seconds from the
    /// start of the *session* — not of the clip.
    ///
    /// Parsed from the `t<ms>` field `video_frames.py` stamps into the filename,
    /// then offset by the same `clipOffsets` running total `runSyncedSessionAnalysis`
    /// uses for `ParkingAnalysis.sessionRelativeSeconds`. Both verticals therefore
    /// land on one shared axis and can be drawn on the same timeline. nil when the
    /// frame did not come from a sampled clip.
    public let sessionRelativeSeconds: Double?

    /// nil until a GPS log exists; segment/km binning needs one (severity.yaml's
    /// `segment_length_m` is unreachable without it).
    public let segmentLabel: String?
    public let kmMarker: String?
    public let coordinate: String?
    public let gpsAccuracyM: Int?

    public let findings: [Finding]

    /// `startScore` minus `deductions` lands on `score` — ALMOST. Both come from
    /// Python (`effective_deductions()` is the per-box split of the same sum
    /// `grade_segment()` turns into `condition`) and nothing is recomputed in
    /// Swift, which is what ADR-016 settled. But two things sit between the sum
    /// and the published number, and any panel has to show both or it prints an
    /// equation that does not balance:
    ///
    /// - Python rounds the total once (`int(round(100.0 - total))`), so a residual
    ///   of up to ±0,5 is expected and self-evident from the subtotal on screen.
    /// - Python then CLAMPS to `[2, 98]` (`severity.py:163`, a literal there and
    ///   deliberately not in `severity.yaml`). That bites hard at the top: a frame
    ///   with no defects at all scores 98, not 100 — which is 722 of the 958 real
    ///   Surabaya frames — and once at the bottom, on `IMG_0044_f000540_t0018000`,
    ///   whose deductions sum to 98,46 and would otherwise score 1,54.
    ///
    /// `startScore` stays 100 because 100 is genuinely where `100.0 - total`
    /// starts; the 98 is a ceiling applied afterwards. The clamp belongs on its
    /// own row in whatever draws this, which is the only place it can go without
    /// either lying about the start or duplicating Python's bounds in Swift.
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
                severity: Severity, score: Int, isProvisional: Bool, warnings: String? = nil,
                sessionRelativeSeconds: Double? = nil, segmentLabel: String? = nil,
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
        self.warnings = warnings
        self.sessionRelativeSeconds = sessionRelativeSeconds
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
