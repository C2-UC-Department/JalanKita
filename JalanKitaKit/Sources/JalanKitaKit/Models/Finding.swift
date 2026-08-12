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

    /// Normalized (0...1) placement + extent used to draw the mask/box over the
    /// frame. Fed directly from the detector's normalized YOLO `xywh`, converted
    /// centre-origin -> top-left-origin by `RoadDamageDataset`. Per ADR-015 this
    /// vertical ships boxes, not masks, so there is deliberately no mask field.
    public var frameRect: CGRect

    public init(id: String, defectType: DefectType, areaSqm: Double? = nil, percentOfSurface: Double? = nil,
                vehicleNote: String? = nil, confidence: Double? = nil, mappedFromNote: String? = nil, frameRect: CGRect) {
        self.id = id
        self.defectType = defectType
        self.areaSqm = areaSqm
        self.percentOfSurface = percentOfSurface
        self.vehicleNote = vehicleNote
        self.confidence = confidence
        self.mappedFromNote = mappedFromNote
        self.frameRect = frameRect
    }
}
