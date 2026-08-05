//
//  ParkingMetrics.swift
//  JalanKita Mac
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

enum ParkingMetrics {
    static func percentOfSurface(area: Double?, ofTotal total: Double) -> Double? {
        guard let area, total > 0 else { return nil }
        return 100 * area / total
    }

    /// Image-space `vehicle.pixelBBox`, normalized to (0...1) against the
    /// analyzed image's own dimensions — what `VehicleCandidatesCanvasView`
    /// positions its tappable overlays with.
    static func normalizedRect(for vehicle: VehicleSummary, imageWidth: Int,
                               imageHeight: Int) -> CGRect {
        guard let pixelBBox = vehicle.pixelBBox, imageWidth > 0, imageHeight > 0 else {
            return .zero
        }
        let w = CGFloat(imageWidth), h = CGFloat(imageHeight)
        return CGRect(x: pixelBBox.minX / w, y: pixelBBox.minY / h,
                      width: pixelBBox.width / w, height: pixelBBox.height / h)
    }

    /// A short Indonesian descriptor for a vehicle's class label. Falls back
    /// to the raw class label (capitalized) for anything the instance model
    /// reports that isn't in this list, rather than guessing a translation.
    private static let labelTranslations: [String: String] = [
        "car": "mobil", "truck": "truk", "motorcycle": "motor", "bus": "bus",
        "van": "van", "vehicle": "kendaraan",
    ]

    static func label(for rawLabel: String) -> String {
        labelTranslations[rawLabel.lowercased()] ?? rawLabel.capitalized
    }
}
