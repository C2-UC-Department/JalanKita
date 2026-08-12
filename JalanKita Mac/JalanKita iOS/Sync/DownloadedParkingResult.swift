//
//  DownloadedParkingResult.swift
//  JalanKita iOS
//
//  Local, iOS-side counterpart to the Mac's `ParkingAnalysis` — a
//  `SyncedParkingResult` CKRecord plus the CKAsset fields that protocol
//  deliberately excludes (image/BEV), downloaded once and copied to a
//  stable local file, plus the decoded `DisturbanceSummary` for direct UI
//  consumption without re-parsing `summaryJSON` on every render. Stays
//  iOS-only rather than JalanKitaKit for the same reason `ParkingAnalysis`
//  stays Mac-only: it holds local file paths, meaningless cross-process.
//

import Foundation
import JalanKitaKit

struct DownloadedParkingResult: Identifiable, Codable {
    let sessionID: String
    let candidateID: String
    var sourceKind: String
    var carTrackID: Int?
    var disturbance: Bool?
    var imageWidth: Int
    var imageHeight: Int
    var createdAt: Date
    var localImageURL: URL
    var localBEVURL: URL?
    var summary: DisturbanceSummary

    var id: String { "\(sessionID)#\(candidateID)" }

    /// Vehicles with a measured area, ranked descending — same ordering as
    /// `ParkingAnalysis.rankedVehicles` on the Mac.
    var rankedVehicles: [VehicleSummary] {
        summary.vehicles
            .filter { ($0.areaM2 ?? 0) > 0 }
            .sorted { ($0.areaM2 ?? 0) > ($1.areaM2 ?? 0) }
    }
}
