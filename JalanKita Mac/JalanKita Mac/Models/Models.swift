//
//  Models.swift
//  JalanKita Mac
//
//  Data shapes for the desk console. This is UI-only scaffolding: the app
//  ingests sessions the phone already recorded and displays results the
//  backend pipeline already computed (see MOBILE_APP_METAPROMPT.md
//  Appendix C). Nothing here runs a model — it renders one's output.
//

import Foundation
import CoreGraphics

struct Surveyor: Identifiable, Hashable {
    let id: String
    let name: String
}

/// One recorded drive, somewhere between "just landed on disk" and
/// "fully processed and reported."
struct Session: Identifiable, Hashable {
    let id: String
    var roadName: String
    var kmMarker: String?
    var date: String
    var surveyor: Surveyor
    var clipCount: Int
    var duration: String
    var distanceKm: Double
    var gpsAccuracyM: Int?
    var gpsHz: Double?
    var gpsGapNote: String?
    var sizeGB: Double
    var status: SessionStatus
    var segmentCount: Int?
    var selectedForBatch: Bool = false
}

struct PipelineStep: Identifiable, Hashable {
    enum State: Hashable { case done, active, waiting }

    let id: Int
    let title: String
    var state: State
    var detail: String
    var stats: String
    var warning: String?
    var subProgress: Double?
}

struct LogLine: Identifiable, Hashable {
    let id = UUID()
    let time: String
    let message: String
    let isWarning: Bool
}

/// A single AI finding on one video frame, awaiting human verification —
/// this is the read-only review surface from §6.6, never an editing tool.
struct Finding: Identifiable, Hashable {
    let id: String
    var defectType: DefectType
    var areaSqm: Double?
    var percentOfSurface: Double?
    var vehicleNote: String?
    var confidence: Double
    var mappedFromNote: String?

    /// Normalized (0...1) placement + extent used to draw the mask/box
    /// over the mock frame illustration.
    var frameRect: CGRect
}

struct SeverityDeduction: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let points: Int
}

/// A reviewed frame: the unit of work on the Peninjauan Temuan screen.
struct ReviewFrame: Identifiable, Hashable {
    let id: String
    let roadName: String
    let indexInQueue: Int
    let totalInQueue: Int
    let frameNumber: String
    let timecode: String
    let severity: Severity
    let score: Int
    let isProvisional: Bool
    let segmentLabel: String
    let kmMarker: String
    let coordinate: String
    let gpsAccuracyM: Int
    let findings: [Finding]
    let startScore: Int
    let deductions: [SeverityDeduction]
}

/// One 10-metre road segment as reported back by the pipeline — the
/// reporting unit per Appendix A.4, never an individual defect count.
struct SegmentResult: Identifiable, Hashable {
    let id: String
    let severity: Severity
    let score: Int
    let roadName: String
    let kmMarker: String
    let segmentLabel: String
    let date: String
    let defectTypes: [DefectType]
    let hasBlockedParking: Bool
    let areaSqm: Double
}
