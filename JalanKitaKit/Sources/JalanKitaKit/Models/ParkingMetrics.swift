//
//  ParkingMetrics.swift
//  JalanKitaKit
//
//  Small pure-computation helpers shared by the "Tinjauan Parkir" screen
//  (VehicleCandidatesCanvasView, ParkingMetricsPanel): normalizing a
//  vehicle's image-space bbox for overlay placement, computing its share of
//  the amodal road, and translating its class label. Reused rather than
//  duplicated per view, same helpers that used to live in FindingMapper
//  before real parking results moved off Peninjauan onto their own screen.
//

import CoreGraphics
import Foundation

public enum ParkingMetrics {
    public static func percentOfSurface(area: Double?, ofTotal total: Double) -> Double? {
        guard let area, total > 0 else { return nil }
        return 100 * area / total
    }

    /// Image-space `vehicle.pixelBBox`, normalized to (0...1) against the
    /// analyzed image's own dimensions — what `VehicleCandidatesCanvasView`
    /// positions its tappable overlays with.
    public static func normalizedRect(for vehicle: VehicleSummary, imageWidth: Int,
                               imageHeight: Int) -> CGRect {
        guard let pixelBBox = vehicle.pixelBBox, imageWidth > 0, imageHeight > 0 else {
            return .zero
        }
        let w = CGFloat(imageWidth), h = CGFloat(imageHeight)
        return CGRect(x: pixelBBox.minX / w, y: pixelBBox.minY / h,
                      width: pixelBBox.width / w, height: pixelBBox.height / h)
    }

    /// Which of OFRSNet's independently-detected `vehicles` is actually v13's
    /// flagged candidate, matched by position rather than assumed to be
    /// whichever one OFRSNet ranks largest by area.
    ///
    /// Scored by Dice coefficient (2 x intersection / (areaA + areaB)), not
    /// plain IoU or a raw containment ratio -- both of those were tried
    /// against a real cluttered frame and got it wrong. IoU undersells a
    /// good match when OFRSNet's instance/blob splitting fragments one
    /// physical car into several pieces, since a good-but-partial fragment
    /// reads as a weak match once union is dominated by v13's fuller box.
    /// Raw containment (intersection / smaller area) swings too far the
    /// other way: a tiny fragment that happens to sit entirely inside v13's
    /// box scores a perfect 1.0 and wins over a much more complete match
    /// that slightly overshoots v13's box on one edge -- confirmed on a real
    /// video where this exact failure picked a motorcycle+rider sliver
    /// (fully contained, score 1.0) over the actual flagged car (92% overlap
    /// but not 100% contained, score 0.93). Dice scored that same pair 0.31
    /// vs 0.89 -- correctly favors substantial, mostly-complete overlap
    /// without over-rewarding small fragments just for being fully enclosed.
    ///
    /// Falls back to nil (caller defaults to largest-area) if nothing
    /// overlaps meaningfully -- e.g. the candidate box is missing, or every
    /// OFRSNet detection genuinely is a different object.
    public static func bestMatchVehicleID(candidateBBox: CGRect?, vehicles: [VehicleSummary],
                                   minDice: Double = 0.3) -> Int? {
        guard let candidateBBox, candidateBBox.width > 0, candidateBBox.height > 0 else { return nil }
        let candidateArea = candidateBBox.width * candidateBBox.height
        var best: (id: Int, score: Double)?
        for vehicle in vehicles {
            guard let box = vehicle.pixelBBox, box.width > 0, box.height > 0 else { continue }
            let intersection = box.intersection(candidateBBox)
            guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { continue }
            let intersectionArea = intersection.width * intersection.height
            let vehicleArea = box.width * box.height
            let denom = candidateArea + vehicleArea
            let score = denom > 0 ? Double(2 * intersectionArea / denom) : 0
            if score > (best?.score ?? 0) {
                best = (vehicle.id, score)
            }
        }
        guard let best, best.score >= minDice else { return nil }
        return best.id
    }

    /// A short Indonesian descriptor for a vehicle's class label. Falls back
    /// to the raw class label (capitalized) for anything the instance model
    /// reports that isn't in this list, rather than guessing a translation.
    private static let labelTranslations: [String: String] = [
        "car": "mobil", "truck": "truk", "motorcycle": "motor", "bus": "bus",
        "van": "van", "vehicle": "kendaraan",
    ]

    public static func label(for rawLabel: String) -> String {
        labelTranslations[rawLabel.lowercased()] ?? rawLabel.capitalized
    }
}
