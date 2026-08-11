//
//  InferenceModels.swift
//  JalanKitaKit
//
//  Swift mirror of the NDJSON protocol spoken by `python -m src.disturbance
//  --serve` (AmodalRoadSegmentation, src/disturbance.py). One JSON object per
//  line each direction over the worker's stdin/stdout; `WorkerEvent` mirrors
//  the separate structured-progress JSON objects the worker writes to stderr.
//  Field names/shape were captured directly off a live `--serve` run (2
//  requests against IMG_0885.jpg / IMG_0864.jpg), not guessed from the CLI's
//  `_print_report`.
//
//  Decodable types only decode the keys this app actually uses — extra keys
//  the Python side emits (e.g. `scale.per_vehicle`, `measures`) are ignored
//  by JSONDecoder rather than mirrored 1:1, so the worker can grow its report
//  without breaking decoding here.
//
//  Lives in JalanKitaKit (not just the Mac target) because the iOS app needs
//  to *display* `DisturbanceSummary`/`VehicleSummary` once results sync back
//  from the Mac's pipeline, even though only the Mac ever talks to the
//  worker process directly (WorkerRequest/RenderBEVRequest are unused on iOS
//  but harmless to share).
//

import CoreGraphics
import Foundation

/// One line written to the worker's stdin, requesting a full `analyze()` run.
public struct WorkerRequest: Encodable, Sendable {
    public var id: String
    public var imagePath: String
    public var cameraHeightM: Double?
    public var threshold: Double?
    public var minScore: Double?
    public var ppm: Double?
    public var maxM2PerPx: Double?
    public var noHeightPrior: Bool?
    public var noAutoHeight: Bool?

    public init(id: String, imagePath: String, cameraHeightM: Double? = nil, threshold: Double? = nil,
                minScore: Double? = nil, ppm: Double? = nil, maxM2PerPx: Double? = nil,
                noHeightPrior: Bool? = nil, noAutoHeight: Bool? = nil) {
        self.id = id
        self.imagePath = imagePath
        self.cameraHeightM = cameraHeightM
        self.threshold = threshold
        self.minScore = minScore
        self.ppm = ppm
        self.maxM2PerPx = maxM2PerPx
        self.noHeightPrior = noHeightPrior
        self.noAutoHeight = noAutoHeight
    }

    enum CodingKeys: String, CodingKey {
        case id, type
        case imagePath = "image_path"
        case cameraHeightM = "camera_height_m"
        case threshold
        case minScore = "min_score"
        case ppm
        case maxM2PerPx = "max_m2_per_px"
        case noHeightPrior = "no_height_prior"
        case noAutoHeight = "no_auto_height"
    }

    /// `encodeIfPresent` omits nil fields entirely rather than writing JSON
    /// `null` — matters here because the worker reads them with Python's
    /// `dict.get(key, default)`, which only falls back to `default` when the
    /// key is *missing*, not when it's present-but-null.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode("analyze", forKey: .type)
        try c.encode(imagePath, forKey: .imagePath)
        try c.encodeIfPresent(cameraHeightM, forKey: .cameraHeightM)
        try c.encodeIfPresent(threshold, forKey: .threshold)
        try c.encodeIfPresent(minScore, forKey: .minScore)
        try c.encodeIfPresent(ppm, forKey: .ppm)
        try c.encodeIfPresent(maxM2PerPx, forKey: .maxM2PerPx)
        try c.encodeIfPresent(noHeightPrior, forKey: .noHeightPrior)
        try c.encodeIfPresent(noAutoHeight, forKey: .noAutoHeight)
    }
}

/// One line written to the worker's stdin, requesting a BEV re-render for a
/// different vehicle selection on an image already analyzed in this worker
/// process — see `serve_worker`'s `result_cache` (src/disturbance.py). Used
/// by the "Tinjauan Parkir" screen when the user taps a different vehicle.
public struct RenderBEVRequest: Encodable, Sendable {
    public var id: String
    public var analysisID: String
    public var vehicleID: Int?

    public init(id: String, analysisID: String, vehicleID: Int? = nil) {
        self.id = id
        self.analysisID = analysisID
        self.vehicleID = vehicleID
    }

    enum CodingKeys: String, CodingKey {
        case id, type
        case analysisID = "analysis_id"
        case vehicleID = "vehicle_id"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode("render_bev", forKey: .type)
        try c.encode(analysisID, forKey: .analysisID)
        try c.encodeIfPresent(vehicleID, forKey: .vehicleID)
    }
}

/// One line written to the worker's stdout, in response to one `WorkerRequest`.
public struct WorkerResponse: Decodable, Sendable {
    public let id: String
    public let ok: Bool
    public let summary: DisturbanceSummary?
    public let imageWidth: Int?
    public let imageHeight: Int?
    public let candidatesPNG: String?
    public let bevPNG: String?
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case id, ok, summary, error
        case imageWidth = "image_width"
        case imageHeight = "image_height"
        case candidatesPNG = "candidates_png"
        case bevPNG = "bev_png"
    }
}

/// One structured JSON object written to the worker's stderr — either the
/// one-time `{"type": "ready"}` once models finish loading, a per-stage
/// `{"type": "progress", "id", "stage", "state"}` (state is "start"/"done"),
/// or `{"type": "error"}` for a malformed request line. Everything else on
/// stderr (model-loading chatter, warnings) is NOT JSON and is surfaced as a
/// raw `LogLine` instead of decoded as an event — see PipelineProgressParser.
public struct WorkerEvent: Decodable, Sendable {
    public let type: String
    public let id: String?
    public let stage: String?
    public let state: String?
    public let error: String?
}

/// Mirrors `DisturbanceResult.summary()` (src/disturbance.py). `Encodable`
/// (not just `Decodable`) because the Mac re-encodes this into
/// `SyncedParkingResult.summaryJSON` to push a real result back to the
/// iPhone via CloudKit.
public struct DisturbanceSummary: Codable, Sendable {
    public let image: String
    public let ok: Bool
    public let scale: ScaleInfo
    public let resolution: ResolutionInfo
    public let total: TotalSummary
    public let unattributed: AreaMeasure
    public let vehicles: [VehicleSummary]
    public let warnings: [String]
}

public struct ScaleInfo: Codable, Sendable {
    public let mode: String
    public let cameraHeightM: Double?
    public let impliedCameraHeightM: Double?
    /// Both present only when `mode == "auto_vehicle_height"` — how many
    /// qualifying cars the automatic camera-height estimate was based on,
    /// and how much they disagreed (fraction of the median).
    public let nSamples: Int?
    public let kSpread: Double?

    enum CodingKeys: String, CodingKey {
        case mode
        case cameraHeightM = "camera_height_m"
        case impliedCameraHeightM = "implied_camera_height_m"
        case nSamples = "n_samples"
        case kSpread = "k_spread"
    }
}

public struct ResolutionInfo: Codable, Sendable {
    public let measurableRangeM: Double
    public let maxM2PerPx: Double
    public let inFramePct: Double
    public let measurablePct: Double

    enum CodingKeys: String, CodingKey {
        case measurableRangeM = "measurable_range_m"
        case maxM2PerPx = "max_m2_per_px"
        case inFramePct = "in_frame_pct"
        case measurablePct = "measurable_pct"
    }
}

public struct TotalSummary: Codable, Sendable {
    public let amodalRoadM2: Double
    public let visibleRoadM2: Double
    public let occludedRoadM2: Double
    public let occludedRoadM2Raw: Double
    public let occludedPct: Double
    public let shadowTruncated: Bool?

    enum CodingKeys: String, CodingKey {
        case amodalRoadM2 = "amodal_road_m2"
        case visibleRoadM2 = "visible_road_m2"
        case occludedRoadM2 = "occluded_road_m2"
        case occludedRoadM2Raw = "occluded_road_m2_raw"
        case occludedPct = "occluded_pct"
        case shadowTruncated = "shadow_truncated"
    }
}

public struct AreaMeasure: Codable, Sendable {
    public let areaM2: Double
    public let areaM2Raw: Double
    public let cells: Int

    enum CodingKeys: String, CodingKey {
        case areaM2 = "area_m2"
        case areaM2Raw = "area_m2_raw"
        case cells
    }
}

/// One occluder (candidate parked vehicle), keyed by `id` (matches
/// `inst_ids == id` on the Python side, and the numbering shown in
/// `render_candidates`'s overlay). `areaM2` is nil only in the pathological
/// case where `analyze()` returned before BEV attribution ran at all
/// (`summary.ok == false`) — a vehicle with zero attributed area still gets
/// a real `0.0`, not nil.
public struct VehicleSummary: Codable, Sendable {
    public let id: Int
    public let label: String
    public let score: Double?
    public let source: String
    public let selectable: Bool
    public let bbox: [Int]
    public let areaM2: Double?
    /// Straight from monocular depth's own scale, uncorrected by the
    /// camera-height prior — shown alongside `areaM2` since the calibrated
    /// figure depends on an assumption this one doesn't inherit (it inherits
    /// the depth model's scale error instead).
    public let areaM2Raw: Double?
    /// This vehicle's single worst along-road cross-section, as a percent of
    /// the road's width there — a full-width blockage on a narrow road and a
    /// small patch on a wide one can have the same area but very different
    /// real-world consequences; this captures the one area alone doesn't.
    public let widthMaxPct: Double?

    enum CodingKeys: String, CodingKey {
        case id, label, score, source, selectable, bbox
        case areaM2 = "area_m2"
        case areaM2Raw = "area_m2_raw"
        case widthMaxPct = "width_max_pct"
    }

    /// Image-space pixel bbox `[u0, v0, u1, v1]` (exclusive upper) as a CGRect.
    public var pixelBBox: CGRect? {
        guard bbox.count == 4 else { return nil }
        let u0 = CGFloat(bbox[0]), v0 = CGFloat(bbox[1])
        let u1 = CGFloat(bbox[2]), v1 = CGFloat(bbox[3])
        return CGRect(x: u0, y: v0, width: max(0, u1 - u0), height: max(0, v1 - v0))
    }
}
