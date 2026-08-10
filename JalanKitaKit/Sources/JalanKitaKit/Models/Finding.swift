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
    public var confidence: Double
    public var mappedFromNote: String?

    /// Normalized (0...1) placement + extent used to draw the mask/box
    /// over the frame illustration.
    public var frameRect: CGRect

    public init(id: String, defectType: DefectType, areaSqm: Double? = nil, percentOfSurface: Double? = nil,
                vehicleNote: String? = nil, confidence: Double, mappedFromNote: String? = nil, frameRect: CGRect) {
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
