//
//  FindingMapper.swift
//  JalanKita Mac
//
//  AnalysisResult -> [Finding], per the integration plan's data contract.
//  `vehicleNote` is deliberately left nil: FindingCard.detailText
//  (ReviewFindingsPanel.swift) shows `vehicleNote` INSTEAD OF area/percent
//  when it's set, and area/percent are the real numbers this pipeline exists
//  to surface. `mappedFromNote` is used instead — the same slot alligator
//  findings use for "dinilai sebagai retak" — so it renders alongside the
//  measurement rather than hiding it.
//
//  Filtering/ranking mirrors src/disturbance.py's own `_print_report`: skip
//  occluders with zero attributed area, rank the rest by area descending.
//  Not filtered by `selectable` — `_print_report` doesn't either, it just
//  flags it in the table.
//

import CoreGraphics
import Foundation

enum FindingMapper {
    static func findings(from result: AnalysisResult) -> [Finding] {
        let amodalRoadM2 = result.summary.total.amodalRoadM2
        let ranked = result.summary.vehicles
            .filter { ($0.areaM2 ?? 0) > 0 }
            .sorted { ($0.areaM2 ?? 0) > ($1.areaM2 ?? 0) }

        return ranked.map { vehicle in
            Finding(
                id: "vehicle-\(vehicle.id)",
                defectType: .blockedPark,
                areaSqm: vehicle.areaM2,
                percentOfSurface: percentOfSurface(area: vehicle.areaM2, ofTotal: amodalRoadM2),
                vehicleNote: nil,
                confidence: vehicle.score ?? 0.75,
                mappedFromNote: label(for: vehicle.label),
                frameRect: normalizedRect(for: vehicle, imageWidth: result.imageWidth,
                                          imageHeight: result.imageHeight)
            )
        }
    }

    private static func percentOfSurface(area: Double?, ofTotal total: Double) -> Double? {
        guard let area, total > 0 else { return nil }
        return 100 * area / total
    }

    private static func normalizedRect(for vehicle: VehicleSummary, imageWidth: Int,
                                       imageHeight: Int) -> CGRect {
        guard let pixelBBox = vehicle.pixelBBox, imageWidth > 0, imageHeight > 0 else {
            return .zero
        }
        let w = CGFloat(imageWidth), h = CGFloat(imageHeight)
        return CGRect(x: pixelBBox.minX / w, y: pixelBBox.minY / h,
                      width: pixelBBox.width / w, height: pixelBBox.height / h)
    }

    /// A short Indonesian descriptor for FindingCard's `mappedFromNote` slot.
    /// Falls back to the raw class label (capitalized) for anything the
    /// instance model reports that isn't in this list, rather than guessing
    /// a translation.
    private static let labelTranslations: [String: String] = [
        "car": "mobil", "truck": "truk", "motorcycle": "motor", "bus": "bus",
        "van": "van", "vehicle": "kendaraan",
    ]

    private static func label(for rawLabel: String) -> String {
        labelTranslations[rawLabel.lowercased()] ?? rawLabel.capitalized
    }
}
