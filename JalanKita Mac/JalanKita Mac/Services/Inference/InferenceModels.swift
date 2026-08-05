//
//  InferenceModels.swift
//  JalanKita Mac
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

import CoreGraphics
import Foundation

/// One line written to the worker's stdin.
struct WorkerRequest: Encodable {
    var id: String
    var imagePath: String
    var cameraHeightM: Double?
    var threshold: Double?
    var minScore: Double?
    var ppm: Double?
    var maxM2PerPx: Double?
    var noHeightPrior: Bool?
    var noAutoHeight: Bool?

    enum CodingKeys: String, CodingKey {
        case id
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
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
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

/// One line written to the worker's stdout, in response to one `WorkerRequest`.
struct WorkerResponse: Decodable {
    let id: String
    let ok: Bool
    let summary: DisturbanceSummary?
    let imageWidth: Int?
    let imageHeight: Int?
    let candidatesPNG: String?
    let bevPNG: String?
    let error: String?

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
struct WorkerEvent: Decodable {
    let type: String
    let id: String?
    let stage: String?
    let state: String?
    let error: String?
}

/// Mirrors `DisturbanceResult.summary()` (src/disturbance.py).
struct DisturbanceSummary: Decodable {
    let image: String
    let ok: Bool
    let scale: ScaleInfo
    let resolution: ResolutionInfo
    let total: TotalSummary
    let unattributed: AreaMeasure
    let vehicles: [VehicleSummary]
    let warnings: [String]
}

struct ScaleInfo: Decodable {
    let mode: String
    let cameraHeightM: Double?
    let impliedCameraHeightM: Double?

    enum CodingKeys: String, CodingKey {
        case mode
        case cameraHeightM = "camera_height_m"
        case impliedCameraHeightM = "implied_camera_height_m"
    }
}

struct ResolutionInfo: Decodable {
    let measurableRangeM: Double
    let maxM2PerPx: Double
    let inFramePct: Double
    let measurablePct: Double

    enum CodingKeys: String, CodingKey {
        case measurableRangeM = "measurable_range_m"
        case maxM2PerPx = "max_m2_per_px"
        case inFramePct = "in_frame_pct"
        case measurablePct = "measurable_pct"
    }
}

struct TotalSummary: Decodable {
    let amodalRoadM2: Double
    let visibleRoadM2: Double
    let occludedRoadM2: Double
    let occludedRoadM2Raw: Double
    let occludedPct: Double
    let shadowTruncated: Bool?

    enum CodingKeys: String, CodingKey {
        case amodalRoadM2 = "amodal_road_m2"
        case visibleRoadM2 = "visible_road_m2"
        case occludedRoadM2 = "occluded_road_m2"
        case occludedRoadM2Raw = "occluded_road_m2_raw"
        case occludedPct = "occluded_pct"
        case shadowTruncated = "shadow_truncated"
    }
}

struct AreaMeasure: Decodable {
    let areaM2: Double
    let areaM2Raw: Double
    let cells: Int

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
/// a real `0.0`, not nil, and FindingMapper filters those out.
struct VehicleSummary: Decodable {
    let id: Int
    let label: String
    let score: Double?
    let source: String
    let selectable: Bool
    let bbox: [Int]
    let areaM2: Double?

    enum CodingKeys: String, CodingKey {
        case id, label, score, source, selectable, bbox
        case areaM2 = "area_m2"
    }

    /// Image-space pixel bbox `[u0, v0, u1, v1]` (exclusive upper) as a CGRect.
    var pixelBBox: CGRect? {
        guard bbox.count == 4 else { return nil }
        let u0 = CGFloat(bbox[0]), v0 = CGFloat(bbox[1])
        let u1 = CGFloat(bbox[2]), v1 = CGFloat(bbox[3])
        return CGRect(x: u0, y: v0, width: max(0, u1 - u0), height: max(0, v1 - v0))
    }
}
