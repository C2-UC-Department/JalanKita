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

    /// Percentage of the frame a segmentation model calls damage *inside this
    /// finding's box* — the same unit as `percentOfSurface`, so the two can sit
    /// side by side.
    ///
    /// `percentOfSurface` is the box's own footprint, which over-states a thin
    /// diagonal crack by construction. This is the measured extent. 🚫 It does not
    /// feed the condition score: severity is still computed in Python from box
    /// area, and Stage 0 has no extent column, so making this authoritative means
    /// moving both stages together (ADR-021). Defaults to nil — Stage 0 findings
    /// and every mock in `SampleData` simply do not have one.
    var extentPercent: Double? = nil
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

/// One row of the severity arithmetic, straight from Python's
/// `effective_deductions()`. Signed — always negative in practice.
///
/// `points` is a `Double`, and that is load-bearing rather than fussy. It used to
/// be `Int`, built with `-Int(deduct_effective.rounded())`, which threw away the
/// fraction at construction while the published `condition` came from Python's
/// sum of the UNROUNDED values. Measured over the real Stage 0 CSVs, the rows
/// then failed to add up to the total on **27 of the 236 damaged frames** — 14 low
/// by a point, 13 high, and never by more than one. For example
/// `IMG_0044_f000390_t0013000`: rows 5.854 / 7.741 / 4.682 / 39.682 rendered as
/// −6 −8 −5 −40 = 59, so the panel showed 41 where Python had published 42. Carry
/// the full precision and round only for display, at one decimal, and every one
/// of those closes — verified by replaying all 958 frames through the panel's
/// arithmetic, 0 remaining.
struct SeverityDeduction: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let points: Double
}

/// A reviewer's verdict on one `Finding`.
///
/// Two cases, not a `Bool` and not a `Set` of "seen" ids, because Terima and Tolak
/// mean opposite things and the panel used to record them identically — both
/// buttons called the same `decide()` and both rendered the same green checkmark,
/// while the footer copy promised rejections were being collected. Whatever the
/// storage, the distinction has to survive it.
enum ReviewDecision: Hashable {
    case accepted
    case rejected
}

/// Peninjauan's status filter. Lives here rather than inside the sidebar that
/// draws it because `AppModel` owns the selection and does the filtering — the
/// previous version was a `private enum` bound to view-local `@State`, which is
/// precisely why picking a row changed nothing.
///
/// `all` is the default and is a new case. With only the original three, the
/// natural default (`unseen`) would make every frame vanish the moment the
/// reviewer decided on it — a behaviour change wearing a bug fix's clothes.
enum ReviewStatusFilter: String, CaseIterable, Identifiable {
    case all = "Semua"
    case unseen = "Belum dilihat"
    case accepted = "Terverifikasi"
    case rejected = "Ditolak"

    var id: String { rawValue }

    /// Does a finding with this decision belong under this filter?
    func matches(_ decision: ReviewDecision?) -> Bool {
        switch self {
        case .all: true
        case .unseen: decision == nil
        case .accepted: decision == .accepted
        case .rejected: decision == .rejected
        }
    }
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

    /// The human-readable provenance caveat that belongs beside this frame's score.
    ///
    /// Per-frame rather than per-screen, because the queue genuinely mixes sources:
    /// `analyzeRoadDamage` inserts a live Stage 1 result at index 0 of a queue
    /// otherwise full of Stage 0 rows, so a banner at the top of the screen would
    /// caveat the wrong frames. It reaches Stage 1 straight off the wire
    /// (`RoadDamageResponse.warnings`) and Stage 0 from the mirrored constant, so a
    /// reviewer never has to know which path produced what they are looking at.
    ///
    /// `isProvisional` is the alarm; this is the reason. The two travel together.
    let warnings: String?

    /// nil until a GPS log exists; segment/km binning needs one (severity.yaml's
    /// `segment_length_m` is unreachable without it).
    let segmentLabel: String?
    let kmMarker: String?
    let coordinate: String?
    let gpsAccuracyM: Int?

    let findings: [Finding]

    /// `startScore` minus `deductions` lands on `score` — ALMOST. Both come from
    /// Python (`effective_deductions()` is the per-box split of the same sum
    /// `grade_segment()` turns into `condition`) and nothing is recomputed in
    /// Swift, which is what ADR-016 settled. But two things sit between the sum
    /// and the published number, and the panel has to show both or it prints an
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
    /// starts; the 98 is a ceiling applied afterwards. The clamp is rendered as
    /// its own row instead (see `ReviewFindingsPanel`), which is the only place it
    /// can go without either lying about the start or duplicating Python's bounds
    /// in Swift.
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
