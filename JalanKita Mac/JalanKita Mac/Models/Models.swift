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

    /// Detector confidence, or nil when the source didn't record one.
    ///
    /// Optional because provenance varies and a fabricated 0.87 is worse than a
    /// missing chip: the YOLO `.txt` labels under `data/local_prelabeled/labels/`
    /// are geometry only (`class cx cy w h`), so anything read from them has no
    /// confidence at all. Real values arrive via `outputs/quantify/per_box.csv`,
    /// the sidecar `quantify_damage.py` writes precisely to carry this.
    var confidence: Double?

    var mappedFromNote: String?

    /// Normalized (0...1) placement + extent used to draw the mask/box over the
    /// frame. Fed directly from the detector's normalized YOLO `xywh`, converted
    /// centre-origin -> top-left-origin by `RoadDamageDataset`. Per ADR-015 this
    /// vertical ships boxes, not masks, so there is deliberately no mask field.
    var frameRect: CGRect
}

struct SeverityDeduction: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let points: Int
}

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
struct ReviewFrame: Identifiable, Hashable {
    let id: String

    /// The clip this frame was sampled from, e.g. "IMG_0040.MOV" — stands in for
    /// a road name, which no source on disk actually knows.
    let sourceClip: String

    /// Real values from `frames_provenance.csv`: the decoder's own frame index
    /// and presentation timestamp, not a formatted guess.
    let frameNumber: String
    let timecode: String
    let capturedAt: String?

    let severity: Severity
    let score: Int

    /// True while the score comes from a detector that has never been validated
    /// against Indonesian box labels — see the domain-gap caveat in ADR-015.
    let isProvisional: Bool

    /// nil until a GPS log exists; segment/km binning needs one (severity.yaml's
    /// `segment_length_m` is unreachable without it).
    let segmentLabel: String?
    let kmMarker: String?
    let coordinate: String?
    let gpsAccuracyM: Int?

    let findings: [Finding]

    /// `startScore` minus `deductions` lands exactly on `score`, because both
    /// come from Python: `effective_deductions()` is the per-box split of the
    /// same sum `grade_segment()` turns into `condition`. Nothing is recomputed
    /// in Swift — the two implementations used to disagree (ADR-016).
    let startScore: Int
    let deductions: [SeverityDeduction]

    /// The frame on disk, plus its recorded pixel size so the canvas can lock the
    /// correct aspect ratio without decoding the image first.
    let imageURL: URL
    let imageWidth: Int
    let imageHeight: Int

    var aspectRatio: CGFloat {
        guard imageWidth > 0, imageHeight > 0 else { return 3.0 / 4.0 }
        return CGFloat(imageWidth) / CGFloat(imageHeight)
    }
}

/// One session's real parking-disturbance analysis — the "Tinjauan Parkir"
/// screen's unit of work. `bevPNGPath` is `var`: `AppModel.selectParkingVehicle`
/// updates it in place each time the user taps a different vehicle overlay,
/// re-rendering the BEV panel with that vehicle's share highlighted.
///
/// One session can now hold SEVERAL of these — one per car v13 found parked
/// in the source video (see AppModel.parkingAnalyses, `[Session.ID:
/// [ParkingAnalysis]]`) — so `id` is its own value, not the session id;
/// `sessionID` groups analyses that came from the same upload.
struct ParkingAnalysis: Identifiable {
    let id: String
    let sessionID: Session.ID
    let imageURL: URL
    let imageWidth: Int
    let imageHeight: Int
    let summary: DisturbanceSummary
    var bevPNGPath: String?

    /// nil for a plain manual photo upload (AppModel.uploadImage) — set only
    /// when this analysis came from a v13 car-detection candidate, carrying
    /// the context OFRSNet itself doesn't know about (which STOP_CLASS, the
    /// depth reading, whether it was inside a sign's zone).
    var carCandidate: CarCandidate?

    /// Vehicles with a measurable share, ranked by area descending —
    /// mirrors `src/disturbance.py`'s own `_print_report` ranking.
    var rankedVehicles: [VehicleSummary] {
        summary.vehicles
            .filter { ($0.areaM2 ?? 0) > 0 }
            .sorted { ($0.areaM2 ?? 0) > ($1.areaM2 ?? 0) }
    }

    /// Best default vehicle to select: v13's own candidate box matched by
    /// position against OFRSNet's independently-detected `vehicles`, not
    /// just whichever one OFRSNet ranks largest by area. That "largest area"
    /// default can silently point at the wrong object in a cluttered frame
    /// (confirmed on a real video: it picked a motorcycle+rider sliver
    /// instead of the actual flagged car, because that sliver's computed
    /// area happened to be bigger). Falls back to `rankedVehicles.first` --
    /// same as before -- when there's no carCandidate (manual photo upload)
    /// or nothing overlaps its box meaningfully.
    var bestMatchVehicleID: Int? {
        ParkingMetrics.bestMatchVehicleID(candidateBBox: carCandidate?.pixelBBox, vehicles: summary.vehicles)
            ?? rankedVehicles.first?.id
    }
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
