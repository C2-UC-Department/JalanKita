//
//  SampleData.swift
//  JalanKita Mac
//
//  Mock road-segment data standing in for the real road-damage
//  segmentation pipeline, which doesn't exist yet — Peninjauan/Peta &
//  segmen stay entirely sample-driven until it does (see MapSegmentsView,
//  ReviewFindingsView/DummySegmentation). Sessions, pipeline steps, and log
//  lines used to live here too; those are gone now that Sesi Masuk/Antrean
//  run on real synced/uploaded data with nothing left to fall back to.
//

import Foundation
import CoreGraphics
import CoreLocation
import JalanKitaKit

enum SampleData {

    static let segments: [SegmentResult] = [
        SegmentResult(id: "seg214", severity: .urgent, score: 28, roadName: "Jl. Raya Darmo", kmMarker: "km 3,42",
                      segmentLabel: "segmen 214 · 4 Agt", date: "4 Agt",
                      defectTypes: [.pothole, .alligator], hasBlockedParking: true, areaSqm: 4.8),
        SegmentResult(id: "seg187", severity: .urgent, score: 34, roadName: "Jl. Raya Darmo", kmMarker: "km 2,98",
                      segmentLabel: "segmen 187 · 4 Agt", date: "4 Agt",
                      defectTypes: [.pothole, .alligator], hasBlockedParking: false, areaSqm: 3.2),
        SegmentResult(id: "seg96", severity: .urgent, score: 39, roadName: "Jl. Mayjen Sungkono", kmMarker: "km 1,54",
                      segmentLabel: "segmen 96 · 2 Agt", date: "2 Agt",
                      defectTypes: [.alligator, .crack], hasBlockedParking: false, areaSqm: 2.7),
        SegmentResult(id: "seg231", severity: .monitor, score: 44, roadName: "Jl. Basuki Rahmat", kmMarker: "km 3,71",
                      segmentLabel: "segmen 231 · 3 Agt", date: "3 Agt",
                      defectTypes: [.alligator], hasBlockedParking: false, areaSqm: 1.9),
        SegmentResult(id: "seg58", severity: .monitor, score: 52, roadName: "Jl. Kertajaya", kmMarker: "km 0,92",
                      segmentLabel: "segmen 58 · 31 Jul", date: "31 Jul",
                      defectTypes: [.crack], hasBlockedParking: true, areaSqm: 1.1),
        SegmentResult(id: "seg142", severity: .monitor, score: 61, roadName: "Jl. Basuki Rahmat", kmMarker: "km 2,27",
                      segmentLabel: "segmen 142 · 3 Agt", date: "3 Agt",
                      defectTypes: [.crack], hasBlockedParking: false, areaSqm: 0.6),
        SegmentResult(id: "seg12", severity: .ignore, score: 73, roadName: "Jl. Raya Darmo", kmMarker: "km 0,18",
                      segmentLabel: "segmen 12 · 1 Agt", date: "1 Agt",
                      defectTypes: [.crack], hasBlockedParking: false, areaSqm: 0.2),
    ]
}

/// Illustrative GPS polylines around Surabaya, keyed by session id — kept
/// separate from `Session` itself so the model doesn't need to carry
/// map-only geometry (and doesn't need CLLocationCoordinate2D to be
/// Hashable, which it isn't).
enum RouteSampleCoordinates {
    /// Base coordinates keyed by the road's short name, so both "Jalan
    /// Raya Darmo" (session rows) and "Jl. Raya Darmo" (segment rows) can
    /// look themselves up after stripping their prefix.
    private static let roadBaseCoordinates: [String: CLLocationCoordinate2D] = [
        "Raya Darmo": CLLocationCoordinate2D(latitude: -7.2932, longitude: 112.7378),
        "Kertajaya": CLLocationCoordinate2D(latitude: -7.2778, longitude: 112.7825),
        "Mayjen Sungkono": CLLocationCoordinate2D(latitude: -7.2688, longitude: 112.7108),
        "Basuki Rahmat": CLLocationCoordinate2D(latitude: -7.2686, longitude: 112.7469),
    ]

    static func baseCoordinate(forRoadName roadName: String) -> CLLocationCoordinate2D {
        let key = roadName
            .replacingOccurrences(of: "Jalan ", with: "")
            .replacingOccurrences(of: "Jl. ", with: "")
        return roadBaseCoordinates[key] ?? CLLocationCoordinate2D(latitude: -7.2575, longitude: 112.7521)
    }

    /// A small, stable per-segment offset from its road's base coordinate
    /// — enough to place distinct pins/polyline points on the map without
    /// needing real per-segment geometry.
    static func coordinate(for segment: SegmentResult) -> CLLocationCoordinate2D {
        let base = baseCoordinate(forRoadName: segment.roadName)
        var hasher = Hasher()
        hasher.combine(segment.id)
        let hash = abs(hasher.finalize())
        let latOffset = Double(hash % 200) / 10000.0 - 0.01
        let lonOffset = Double((hash / 200) % 200) / 10000.0 - 0.01
        return CLLocationCoordinate2D(latitude: base.latitude + latOffset, longitude: base.longitude + lonOffset)
    }
}
