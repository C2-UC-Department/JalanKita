//
//  Finding.swift
//  JalanKitaKit
//
//  A single AI finding on one video frame, awaiting human verification — the
//  read-only review surface from the design brief §6.6, never an editing tool.
//

import Foundation
import CoreGraphics

public struct Finding: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var defectType: DefectType
    public var areaSqm: Double?
    public var percentOfSurface: Double?

    /// Percentage of the frame a segmentation model calls damage *inside this
    /// finding's box* — the same unit as `percentOfSurface`, so the two can sit
    /// side by side.
    ///
    /// `percentOfSurface` is the box's own footprint, which over-states a thin
    /// diagonal crack by construction. This is the measured extent. 🚫 It does not
    /// feed the condition score: severity is still computed in Python from box
    /// area, and Stage 0 has no extent column, so making this authoritative means
    /// moving both stages together (ADR-021). Defaults to nil — findings without a
    /// U-Net pass simply do not have one.
    public var extentPercent: Double?

    public var vehicleNote: String?

    /// Detector confidence, or nil when the source didn't record one.
    ///
    /// Optional because provenance varies and a fabricated 0.87 is worse than a
    /// missing chip: the YOLO `.txt` labels under `data/local_prelabeled/labels/`
    /// are geometry only (`class cx cy w h`), so anything read from them has no
    /// confidence at all. Real values arrive via `outputs/quantify/per_box.csv`,
    /// the sidecar `quantify_damage.py` writes precisely to carry this.
    public var confidence: Double?

    public var mappedFromNote: String?

    /// Normalized (0...1) placement + extent used to draw the box over the frame.
    /// Fed directly from the detector's normalized YOLO `xywh`, converted
    /// centre-origin -> top-left-origin by `RoadDamageService.makeFrame`. Per
    /// ADR-015 this vertical ships boxes, not masks, so there is deliberately no
    /// mask field — `RoadDamageFindingOverlay` draws a plain stroked rect for the
    /// same reason.
    public var frameRect: CGRect

    public init(id: String, defectType: DefectType, areaSqm: Double? = nil, percentOfSurface: Double? = nil,
                extentPercent: Double? = nil, vehicleNote: String? = nil, confidence: Double? = nil,
                mappedFromNote: String? = nil, frameRect: CGRect) {
        self.id = id
        self.defectType = defectType
        self.areaSqm = areaSqm
        self.percentOfSurface = percentOfSurface
        self.extentPercent = extentPercent
        self.vehicleNote = vehicleNote
        self.confidence = confidence
        self.mappedFromNote = mappedFromNote
        self.frameRect = frameRect
    }
}
