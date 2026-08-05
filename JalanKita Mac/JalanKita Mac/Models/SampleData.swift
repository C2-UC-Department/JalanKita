//
//  SampleData.swift
//  JalanKita Mac
//
//  Realistic mock content standing in for the backend, per the design
//  brief's instruction to use real measured numbers rather than lorem
//  ipsum (§8): 37 Surabaya clips, 958 frames, 236 damaged frames, grade
//  distribution 177 IGNORE / 43 MONITOR / 16 URGENT, mean score 76.6.
//

import Foundation
import CoreGraphics
import CoreLocation

enum Surveyors {
    static let budi = Surveyor(id: "budi", name: "Budi Santoso")
    static let sri = Surveyor(id: "sri", name: "Sri Wahyuni")
    static let agus = Surveyor(id: "agus", name: "Agus Prasetyo")
    static let dewi = Surveyor(id: "dewi", name: "Dewi Lestari")

    static let all = [budi, sri, agus, dewi]
}

enum SampleData {

    static let sessions: [Session] = [
        Session(id: "s1", roadName: "Jalan Raya Darmo", kmMarker: nil, date: "4 Agt 06:12", surveyor: Surveyors.budi,
                clipCount: 2, duration: "01:47:22", distanceKm: 24.6, gpsAccuracyM: 6, gpsHz: 1,
                gpsGapNote: nil, sizeGB: 2.8, status: .readyToProcess, segmentCount: nil, selectedForBatch: true),
        Session(id: "s2", roadName: "Jalan Kertajaya", kmMarker: nil, date: "4 Agt 05:48", surveyor: Surveyors.sri,
                clipCount: 1, duration: "00:52:10", distanceKm: 11.4, gpsAccuracyM: 8, gpsHz: 1,
                gpsGapNote: nil, sizeGB: 1.2, status: .readyToProcess, segmentCount: nil, selectedForBatch: true),
        Session(id: "s3", roadName: "Jalan Mayjen Sungkono", kmMarker: nil, date: "2 Agt 07:02", surveyor: Surveyors.agus,
                clipCount: 1, duration: "00:58:40", distanceKm: 12.1, gpsAccuracyM: nil, gpsHz: nil,
                gpsGapNote: "4,2 km tanpa jejak", sizeGB: 1.4, status: .degraded(reason: "4,2 km tanpa jejak GPS"),
                segmentCount: nil, selectedForBatch: true),
        Session(id: "s4", roadName: "Jalan Basuki Rahmat", kmMarker: nil, date: "3 Agt 06:30", surveyor: Surveyors.dewi,
                clipCount: 2, duration: "02:12:05", distanceKm: 31.8, gpsAccuracyM: 5, gpsHz: 1,
                gpsGapNote: nil, sizeGB: 3.4, status: .segmenting(progress: 0.42), segmentCount: nil, selectedForBatch: false),
        Session(id: "s5", roadName: "Jalan Raya Darmo", kmMarker: nil, date: "1 Agt 06:05", surveyor: Surveyors.budi,
                clipCount: 2, duration: "01:44:58", distanceKm: 24.1, gpsAccuracyM: 6, gpsHz: 1,
                gpsGapNote: nil, sizeGB: 2.7, status: .done, segmentCount: 72, selectedForBatch: false),
        Session(id: "s6", roadName: "Jalan Kertajaya", kmMarker: nil, date: "31 Jul 05:52", surveyor: Surveyors.sri,
                clipCount: 1, duration: "00:49:31", distanceKm: 10.8, gpsAccuracyM: 7, gpsHz: 1,
                gpsGapNote: nil, sizeGB: 1.1, status: .done, segmentCount: 58, selectedForBatch: false),
        Session(id: "s7", roadName: "Jalan Mayjen Sungkono", kmMarker: nil, date: "30 Jul 06:41", surveyor: Surveyors.agus,
                clipCount: 1, duration: "00:12:04", distanceKm: 2.4, gpsAccuracyM: 6, gpsHz: 1,
                gpsGapNote: "video rusak di 00:12:04", sizeGB: 0.3, status: .failed(reason: "video rusak di 00:12:04"),
                segmentCount: nil, selectedForBatch: false),
    ]

    static let queue: [Session] = [sessions[3], sessions[0], sessions[1]]

    /// The parking-disturbance pipeline's own stages (src/disturbance.py
    /// `analyze()`), not the video/GPS pipeline the design brief describes —
    /// this integration takes a single uploaded photo, not a recorded drive.
    /// `.waiting` at rest; AppModel.applyProgress drives state/detail live
    /// from the worker's stderr progress events during `uploadImage(url:)`.
    static let pipelineSteps: [PipelineStep] = [
        PipelineStep(id: 1, title: "Segmentasi semantik jalan", state: .waiting,
                     detail: "menunggu",
                     stats: "Mask2Former (jalan terlihat) + OFRSNet (patch jalan amodal)"),
        PipelineStep(id: 2, title: "Deteksi instans kendaraan", state: .waiting,
                     detail: "menunggu",
                     stats: "model instans kendaraan, dengan fallback komponen-terhubung (blob) untuk dukungan yang tak terdeteksi"),
        PipelineStep(id: 3, title: "Estimasi bidang tanah & tinggi kamera", state: .waiting,
                     detail: "menunggu",
                     stats: "RANSAC pada depth monokuler · skala metrik otomatis dari tinggi atap kendaraan terdeteksi"),
        PipelineStep(id: 4, title: "Rasterisasi BEV & atribusi", state: .waiting,
                     detail: "menunggu",
                     stats: "proyeksi top-down · jejak kontak-tanah tiap kendaraan · atribusi area jalan tersembunyi per kendaraan"),
    ]

    static let gpsJoinNote = "Log GPS dimulai 4 detik sebelum video dan berakhir 9 detik sesudah — tidak ada frame yang perlu dijepit ke ujung jejak."

    static let logLines: [LogLine] = [
        LogLine(time: "07:02:14", message: "segmentasi batch 181/431 · gpu 91% · 1,04 f/d", isWarning: false),
        LogLine(time: "07:02:11", message: "segmentasi frame 002891 mask: retak 0,7 m²", isWarning: false),
        LogLine(time: "07:02:09", message: "segmentasi frame 002890 mask: lubang 0,4 m² · retak 0,2 m²", isWarning: false),
        LogLine(time: "07:01:58", message: "peringatan kelas 'alligator' tidak ada di segmenter — dipetakan ke 'retak'", isWarning: true),
        LogLine(time: "07:01:44", message: "gps 6892/6892 frame tergabung · rms 0,4 d", isWarning: false),
    ]

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

    private static let sessionRoadNames: [String: String] = [
        "s1": "Raya Darmo", "s5": "Raya Darmo",
        "s2": "Kertajaya", "s6": "Kertajaya",
        "s3": "Mayjen Sungkono", "s7": "Mayjen Sungkono",
        "s4": "Basuki Rahmat",
    ]

    static func route(for sessionID: String) -> [CLLocationCoordinate2D] {
        let base = baseCoordinate(forRoadName: sessionRoadNames[sessionID] ?? "")
        let offsets: [(Double, Double)] = [
            (-0.010, -0.006), (-0.004, -0.002), (0.002, 0.001), (0.009, 0.005), (0.015, 0.009),
        ]
        return offsets.map {
            CLLocationCoordinate2D(latitude: base.latitude + $0.0, longitude: base.longitude + $0.1)
        }
    }

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
