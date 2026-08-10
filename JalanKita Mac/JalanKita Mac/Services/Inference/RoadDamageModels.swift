//
//  RoadDamageModels.swift
//  JalanKita Mac
//
//  Wire schema for the road-damage worker — Protocol A, one JSON object per line
//  each way. The other side of this contract is `RoadDamage/worker_main.py`'s
//  module docstring, and per CLAUDE.md's hard rule the pair changes TOGETHER, in
//  one commit. Widening one side alone is how a schema starts lying.
//
//  Shaped to carry the same fields as Stage 0's `per_box.csv`, on purpose: both
//  paths build the identical `ReviewFrame`, so a frame analysed live and the same
//  frame read from the dataset render identically and score identically. That was
//  verified against IMG_0040_f000030_t0001000 — worker output and CSV row agree
//  box for box, including `deduct_effective` and the resulting condition of 50.
//
//  Note what is NOT here: no mask payload, no polygon, no per-pixel anything.
//  ADR-015 ships boxes; adding masks later is a deliberate schema widening and a
//  separate decision, not something to sneak in as an optional field.
//

import Foundation

struct RoadDamageRequest: Encodable {
    let id: String
    var type: String = "analyze"
    let imagePath: String

    /// Both nil in normal use so the worker applies its own defaults, which are
    /// pinned to the run that produced the Stage 0 CSVs (conf 0.20, imgsz 1280).
    /// Overriding them here makes live results diverge from the dataset.
    var conf: Double?
    var imgsz: Int?

    enum CodingKeys: String, CodingKey {
        case id, type, conf, imgsz
        case imagePath = "image_path"
    }
}

/// One detection. Mirrors `per_box.csv`'s columns field for field.
struct RoadDamageBox: Decodable {
    let boxIndex: Int
    let cls: String
    let cx: Double
    let cy: Double
    let w: Double
    let h: Double
    let conf: Double
    let areaPct: Double
    let inWheelpath: Bool
    let deductRaw: Double

    /// After same-class density decay. These sum to `100 − condition`, which is
    /// what lets the severity panel's arithmetic close without Swift scoring
    /// anything itself.
    let deductEffective: Double

    enum CodingKeys: String, CodingKey {
        case cls, cx, cy, w, h, conf
        case boxIndex = "box_index"
        case areaPct = "area_pct"
        case inWheelpath = "in_wheelpath"
        case deductRaw = "deduct_raw"
        case deductEffective = "deduct_effective"
    }
}

struct RoadDamageResponse: Decodable {
    let id: String
    let ok: Bool
    let error: String?

    let imageWidth: Int?
    let imageHeight: Int?
    let condition: Int?
    let grade: String?
    let startScore: Int?
    let boxes: [RoadDamageBox]?

    /// Human-readable provenance caveat shipped with every result, per this
    /// repo's wire convention — currently the un-measured Indonesian domain gap.
    let warnings: String?

    enum CodingKeys: String, CodingKey {
        case id, ok, error, condition, grade, boxes, warnings
        case imageWidth = "image_width"
        case imageHeight = "image_height"
        case startScore = "start_score"
    }
}

/// A structured stderr event. Same shape as the disturbance worker's so both
/// pipelines' progress can flow through one UI path.
struct RoadDamageEvent: Decodable {
    let type: String
    let id: String?
    let stage: String?
    let state: String?
    let error: String?
}
