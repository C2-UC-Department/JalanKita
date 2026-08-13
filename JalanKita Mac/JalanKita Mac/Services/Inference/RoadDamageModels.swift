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
//  Note what is still NOT here: no mask payload, no polygon, no per-pixel anything.
//  `extentPct` is a single scalar per box — how much of that rectangle a U-Net
//  calls damage — not a shape. Drawing a real mask would need geometry on the
//  wire and a `FrameCanvasView` that is not built around a rect; that remains a
//  separate, deliberate decision (ADR-021).
//
//  ⚠️ `extentPct` and `extentSource` are OPTIONAL, and both facts matter. They are
//  absent from Stage 0's CSV rows, absent when a frame has no boxes, and absent
//  when the worker could not trust the extent model for that image. Making either
//  non-optional would break decoding of every Stage 0 row.
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

    /// How much of this box a U-Net actually calls damage, as a percentage of the
    /// whole frame — the same unit as `areaPct`, so the two are directly comparable.
    ///
    /// `areaPct` is the box's own footprint and over-states a thin diagonal crack by
    /// construction; boxes drawn around hand-brushed ground truth reach only 24,48 %
    /// pixel precision, which caps what `areaPct` can ever mean. This is the honest
    /// figure. 🚫 It does **not** feed severity — `condition` and `deductEffective`
    /// are still box-derived, because Stage 0 has no extent column and ADR-016
    /// requires both paths to grade a frame identically. Displayed, never scored.
    let extentPct: Double?

    /// Provenance for `extentPct`, currently always `"unet"` when present. Carried
    /// now so the later fallback policy is not another schema widening.
    let extentSource: String?

    enum CodingKeys: String, CodingKey {
        case cls, cx, cy, w, h, conf
        case boxIndex = "box_index"
        case areaPct = "area_pct"
        case inWheelpath = "in_wheelpath"
        case deductRaw = "deduct_raw"
        case deductEffective = "deduct_effective"
        case extentPct = "extent_pct"
        case extentSource = "extent_source"
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

    /// The same sentence `worker_main.py:198-199` sends, for the path that never
    /// talks to the worker.
    ///
    /// Stage 0 reads `outputs/quantify/per_frame.csv` and there is no warnings
    /// column in it, but the caveat is a property of the DETECTOR, not of the
    /// transport — the CSVs are that same model's output, just computed earlier.
    /// Leaving Stage 0 uncaveated would have hidden it on 236 of ~237 queue
    /// entries, i.e. everywhere except a photo the reviewer uploaded themselves,
    /// which is not a caveat so much as an easter egg.
    ///
    /// Yes, this duplicates a Python string literal, and that is the deliberate
    /// part: it lives HERE, immediately under the `warnings` field, because
    /// CLAUDE.md's schema rule already names this file and `worker_main.py` as a
    /// pair that changes together. Put it in `RoadDamageDataset` or a view and it
    /// escapes the one rule that would catch the drift. Stage 1 still prefers the
    /// live value (`response.warnings ?? domainGapCaveat`), so editing the Python
    /// alone changes what the worker path renders immediately; the constant is the
    /// floor, not the source of truth.
    ///
    /// Rejected: deriving Stage 0's text from `outputs/quantify/summary.json`'s
    /// `note` field. It exists and says the right thing with real numbers attached,
    /// but it is English (CLAUDE.md requires Bahasa Indonesia for user-facing
    /// strings) and it is a DIFFERENT sentence — the two stages would then caveat
    /// the same road with two different texts, which is the drift this was
    /// supposed to avoid, relocated into prose.
    static let domainGapCaveat =
        "Model RDD2022 belum divalidasi pada data Indonesia — jumlah temuan "
        + "adalah batas bawah, bukan kebenaran."

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
