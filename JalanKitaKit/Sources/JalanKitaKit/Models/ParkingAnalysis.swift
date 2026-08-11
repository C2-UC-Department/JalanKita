//
//  ParkingAnalysis.swift
//  JalanKitaKit
//
//  One session's real parking-disturbance analysis — the "Tinjauan Parkir"
//  screen's unit of work. `bevPNGPath` is `var`: the Mac app updates it in
//  place each time the user taps a different vehicle overlay, re-rendering
//  the BEV panel with that vehicle's share highlighted.
//
//  One session can hold SEVERAL of these — one per car v13 found parked in
//  the source video — so `id` is its own value, not the session id;
//  `sessionID` groups analyses that came from the same upload.
//

import Foundation

public struct ParkingAnalysis: Identifiable, Codable, Sendable {
    public let id: String
    public let sessionID: Session.ID
    public let imageURL: URL
    public let imageWidth: Int
    public let imageHeight: Int
    public let summary: DisturbanceSummary
    public var bevPNGPath: String?

    /// nil for a plain manual photo upload — set only when this analysis
    /// came from a v13 car-detection candidate, carrying context OFRSNet
    /// itself doesn't know about (which STOP_CLASS, the depth reading,
    /// whether it was inside a sign's zone).
    public var carCandidate: CarCandidate?

    public init(id: String, sessionID: Session.ID, imageURL: URL, imageWidth: Int, imageHeight: Int,
                summary: DisturbanceSummary, bevPNGPath: String? = nil, carCandidate: CarCandidate? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.imageURL = imageURL
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.summary = summary
        self.bevPNGPath = bevPNGPath
        self.carCandidate = carCandidate
    }

    /// Vehicles with a measurable share, ranked by area descending —
    /// mirrors `src/disturbance.py`'s own `_print_report` ranking.
    public var rankedVehicles: [VehicleSummary] {
        summary.vehicles
            .filter { ($0.areaM2 ?? 0) > 0 }
            .sorted { ($0.areaM2 ?? 0) > ($1.areaM2 ?? 0) }
    }

    /// Best default vehicle to select: v13's own candidate box matched by
    /// position against OFRSNet's independently-detected `vehicles`, not
    /// just whichever one OFRSNet ranks largest by area. That "largest area"
    /// default can silently point at the wrong object in a cluttered frame.
    /// Falls back to `rankedVehicles.first` when there's no carCandidate
    /// (manual photo upload) or nothing overlaps its box meaningfully.
    public var bestMatchVehicleID: Int? {
        ParkingMetrics.bestMatchVehicleID(candidateBBox: carCandidate?.pixelBBox, vehicles: summary.vehicles)
            ?? rankedVehicles.first?.id
    }
}
