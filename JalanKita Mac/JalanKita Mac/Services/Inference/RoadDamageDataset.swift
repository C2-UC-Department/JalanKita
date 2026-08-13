//
//  RoadDamageDataset.swift
//  JalanKita Mac
//
//  Stage 0 of the road-damage vertical: read what the detector ALREADY produced,
//  rather than running it. `../test-road-damage-detection/` has graded 958 real
//  Surabaya frames and left the results on disk, so Peninjauan can show real
//  numbers with no Python process, no venv, no model load and no new committed
//  weights. Stage 1 (RoadDamageService) adds live inference on top of the same
//  `ReviewFrame` shape — this loader is what proved that shape works first.
//
//  Three CSVs, all read-only, all outside this repo:
//
//    outputs/quantify/per_frame.csv              one row per frame: condition, grade, counts
//    outputs/quantify/per_box.csv                one row per DETECTION: geometry, conf, deduction
//    data/local/surabaya_frames/frames_provenance.csv
//                                                source clip, frame index, pts, pixel size, GPS
//
//  `per_box.csv` is the one this app specifically needs and the reason
//  `quantify_damage.py` grew a sidecar writer: the YOLO `.txt` labels are geometry
//  only, so per-detection confidence and per-detection deduction exist nowhere else.
//  Its `deduct_effective` column is the per-box split of the very sum that produced
//  `condition`, which is what lets the severity panel show "100 − deductions = score"
//  and have it actually add up. Swift computes no severity arithmetic of its own;
//  the previous DummySegmentation did, and disagreed with Python on every term
//  (wheel-path x1,4 vs 1.22, repeat decay ÷3 vs 0.82^rank, no size term). ADR-016.
//
//  Everything without a source on disk stays nil. `frames_provenance.csv` records
//  `gps_source=none` and empty lat/lon for all 958 frames, so `coordinate`,
//  `kmMarker` and `segmentLabel` are nil rather than the invented
//  "-7,2823 / 112,7386" the mock used to display. `areaSqm` is nil for the same
//  reason: `src/ipm.py` is built but unwired, needing one known-scale calibration
//  frame. A missing figure reads as missing; a fabricated one reads as a survey.
//

import Foundation
import CoreGraphics

enum RoadDamageDataset {

    enum LoadError: LocalizedError {
        case datasetNotFound(searched: [URL])
        case unreadable(URL, underlying: String)
        case malformed(URL, reason: String)

        var errorDescription: String? {
            switch self {
            case .datasetNotFound(let searched):
                let list = searched.map(\.path).joined(separator: "\n  ")
                return """
                Dataset kerusakan jalan tidak ditemukan. Lokasi yang dicari:
                  \(list)
                Setel JALANKITA_ROAD_DAMAGE_DATA ke checkout test-road-damage-detection.
                """
            case .unreadable(let url, let underlying):
                return "Gagal membaca \(url.lastPathComponent): \(underlying)"
            case .malformed(let url, let reason):
                return "Format \(url.lastPathComponent) tidak sesuai: \(reason)"
            }
        }
    }

    /// What one `load` produced, plus anything the reader wants the log to know.
    /// Warnings are non-fatal by design — a missing provenance file costs metadata,
    /// not the whole screen, matching the app's "never let a failure be fatal" rule.
    struct LoadResult {
        var frames: [ReviewFrame]
        var warnings: [String]
        var totalFramesInDataset: Int
        var cleanFrameCount: Int
    }

    // MARK: - Locating the dataset

    /// `JALANKITA_ROAD_DAMAGE_DATA` first, then a zero-config sibling lookup.
    ///
    /// The sibling path is six components up from this source file — Inference/ ->
    /// Services/ -> "JalanKita Mac/" (inner) -> "JalanKita Mac/" (project dir) ->
    /// repo root -> the directory holding both checkouts — then into
    /// `test-road-damage-detection`. Same trick as `InferenceService`'s
    /// `autoDetectedPythonWorkerRoot`, one level further out because this dataset
    /// is a sibling *repo*, not a subdirectory of this one.
    static func resolveDataRoot() throws -> URL {
        try resolveDataRootReportingFallback().root
    }

    /// Resolution, plus a warning if an explicitly-set `JALANKITA_ROAD_DAMAGE_DATA`
    /// was ignored.
    ///
    /// Falling through to the sibling lookup matches `InferenceService`'s tiering,
    /// but the consequence differs in kind: a bad interpreter path fails loudly at
    /// launch, whereas a typo'd *dataset* path would silently load a DIFFERENT
    /// dataset and every number on screen would be real, plausible, and not the one
    /// the operator asked for. So the fallback still happens — a working screen
    /// beats a dead one — but it never happens quietly.
    static func resolveDataRootReportingFallback() throws -> (root: URL, warnings: [String]) {
        var searched: [URL] = []
        var warnings: [String] = []

        if let explicit = ProcessInfo.processInfo.environment["JALANKITA_ROAD_DAMAGE_DATA"] {
            let url = URL(fileURLWithPath: explicit, isDirectory: true)
            if isDatasetRoot(url) { return (url, warnings) }
            searched.append(url)
            warnings.append("JALANKITA_ROAD_DAMAGE_DATA menunjuk ke \(url.path), yang tidak berisi "
                            + "\(perFrameRelPath). Memakai lokasi bawaan sebagai gantinya.")
        }

        let sibling = autoDetectedSiblingRoot()
        if isDatasetRoot(sibling) { return (sibling, warnings) }
        searched.append(sibling)

        throw LoadError.datasetNotFound(searched: searched)
    }

    private static func isDatasetRoot(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(perFrameRelPath).path)
    }

    private static func autoDetectedSiblingRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("test-road-damage-detection", isDirectory: true)
    }

    private static let perFrameRelPath = "outputs/quantify/per_frame.csv"
    private static let perBoxRelPath = "outputs/quantify/per_box.csv"
    private static let provenanceRelPath = "data/local/surabaya_frames/frames_provenance.csv"
    private static let imagesRelPath = "data/local_prelabeled/images"

    // MARK: - Loading

    /// Builds the review queue.
    ///
    /// `includeClean` defaults to false because 722 of the 958 frames carry no
    /// detection at all: a reviewer paging through those sees three quarters of the
    /// queue as empty screens. They remain loadable — the Peninjauan toolbar toggles
    /// this at runtime — so the clean-frame path stays exercisable without a rebuild,
    /// which is the one case most likely to regress into an empty-state bug.
    static func load(includeClean: Bool = false) throws -> LoadResult {
        let (root, resolutionWarnings) = try resolveDataRootReportingFallback()
        var warnings: [String] = resolutionWarnings

        let frameRows = try readCSV(root.appendingPathComponent(perFrameRelPath))
        let boxRows = try readCSV(root.appendingPathComponent(perBoxRelPath))

        let provenanceURL = root.appendingPathComponent(provenanceRelPath)
        var provenance: [String: [String: String]] = [:]
        if FileManager.default.fileExists(atPath: provenanceURL.path) {
            for row in try readCSV(provenanceURL) {
                let stem = (row["frame_file"] ?? "").replacingOccurrences(of: ".jpg", with: "")
                if !stem.isEmpty { provenance[stem] = row }
            }
        } else {
            warnings.append("frames_provenance.csv tidak ditemukan — metadata klip, "
                            + "timecode dan ukuran piksel tidak tersedia.")
        }

        // Group detections by frame, preserving per_box.csv's own ordering so
        // `box_index` and the on-screen order agree.
        var boxesByImage: [String: [[String: String]]] = [:]
        for row in boxRows {
            guard let image = row["image"], !image.isEmpty else { continue }
            boxesByImage[image, default: []].append(row)
        }

        let imagesDir = root.appendingPathComponent(imagesRelPath, isDirectory: true)
        var frames: [ReviewFrame] = []
        var cleanCount = 0
        var missingImages = 0

        for row in frameRows {
            guard let image = row["image"], !image.isEmpty else { continue }
            let defectCount = Int(row["n_defects"] ?? "0") ?? 0
            if defectCount == 0 { cleanCount += 1 }
            guard includeClean || defectCount > 0 else { continue }

            let imageURL = imagesDir.appendingPathComponent("\(image).jpg")
            guard FileManager.default.fileExists(atPath: imageURL.path) else {
                missingImages += 1
                continue
            }

            let meta = provenance[image]
            let boxes = boxesByImage[image] ?? []
            let findings = boxes.enumerated().compactMap { index, box in
                makeFinding(image: image, index: index, row: box)
            }

            frames.append(makeFrame(image: image,
                                    row: row,
                                    meta: meta,
                                    boxes: boxes,
                                    findings: findings,
                                    imageURL: imageURL))
        }

        if missingImages > 0 {
            warnings.append("\(missingImages) frame dilewati — berkas gambar tidak ditemukan di "
                            + imagesDir.path)
        }

        return LoadResult(frames: frames,
                          warnings: warnings,
                          totalFramesInDataset: frameRows.count,
                          cleanFrameCount: cleanCount)
    }

    // MARK: - Row -> model

    private static func makeFinding(image: String, index: Int, row: [String: String]) -> Finding? {
        guard let type = defectType(row["cls"]),
              let cx = Double(row["cx"] ?? ""), let cy = Double(row["cy"] ?? ""),
              let w = Double(row["w"] ?? ""), let h = Double(row["h"] ?? "") else { return nil }

        // YOLO stores a centre-origin box; CGRect wants its top-left corner. Both
        // measure y downward from the top of the image, so there is no flip here —
        // getting that wrong shows up immediately as vertically mirrored overlays.
        let rect = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)

        return Finding(
            // Deterministic, not a UUID: relaunching must reproduce identical
            // findings, and selection state is keyed on this id.
            id: "\(image)#\(index)",
            defectType: type,
            areaSqm: nil,                                   // needs src/ipm.py + a calibration frame
            percentOfSurface: Double(row["area_pct"] ?? ""),
            vehicleNote: nil,
            confidence: Double(row["conf"] ?? ""),
            mappedFromNote: mappedFromNote(for: type),
            frameRect: rect
        )
    }

    private static func makeFrame(image: String,
                                  row: [String: String],
                                  meta: [String: String]?,
                                  boxes: [[String: String]],
                                  findings: [Finding],
                                  imageURL: URL) -> ReviewFrame {
        let score = Int(row["condition"] ?? "") ?? 100
        let width = Int(meta?["width"] ?? "") ?? 0
        let height = Int(meta?["height"] ?? "") ?? 0

        return ReviewFrame(
            id: image,
            sourceClip: meta?["source_video"] ?? sourceClip(fromStem: image),
            frameNumber: meta?["frame_index"] ?? frameIndex(fromStem: image),
            timecode: timecode(seconds: Double(meta?["pts_sec"] ?? ""), stem: image),
            capturedAt: meta?["wall_clock_iso"].flatMap { $0.isEmpty ? nil : $0 },
            severity: Severity(score: score),
            score: score,
            // The detector's 0.53 mAP is a Japan+India figure; no Indonesian box
            // labels exist to validate it against. Every score stays provisional
            // until that measurement exists (ADR-015's domain-gap caveat).
            isProvisional: true,
            // The CSVs carry no warnings column, so the constant stands in — the
            // caveat belongs to the detector that produced them, not to the
            // transport. See RoadDamageResponse.domainGapCaveat for why the Swift
            // copy lives next to the wire field rather than here.
            warnings: RoadDamageResponse.domainGapCaveat,
            segmentLabel: nil,
            kmMarker: nil,
            coordinate: nil,
            gpsAccuracyM: nil,
            findings: findings,
            startScore: 100,
            deductions: deductions(boxes: boxes, findings: findings),
            imageURL: imageURL,
            imageWidth: width,
            imageHeight: height
        )
    }

    /// One row per detection, straight from `deduct_effective` and UNROUNDED.
    ///
    /// The rounding used to happen right here (`-Int(effective.rounded())`) and
    /// that is what stopped the panel's arithmetic closing on 27 of the 236
    /// damaged frames — see `SeverityDeduction`'s own comment for the measurement.
    /// Rounding is a display concern; the model layer carries what Python sent.
    private static func deductions(boxes: [[String: String]],
                                   findings: [Finding]) -> [SeverityDeduction] {
        zip(boxes, findings).compactMap { box, finding in
            guard let effective = Double(box["deduct_effective"] ?? "") else { return nil }
            let raw = Double(box["deduct_raw"] ?? "") ?? effective
            let inWheelpath = (box["in_wheelpath"] ?? "0") == "1"
            // A decayed value means this wasn't the worst of its class in the frame —
            // severity.yaml's `density_decay` applied. Say so, don't just show a number.
            let isRepeat = effective < raw - 0.0001

            var label = finding.defectType.label
            if inWheelpath { label += " · di jalur roda" }
            if isRepeat { label += " · pengulangan kelas" }

            return SeverityDeduction(label: label, points: -effective)
        }
    }

    private static func defectType(_ raw: String?) -> DefectType? {
        // Names come from data.yaml's merged 3-class taxonomy: 0 crack, 1 alligator,
        // 2 pothole. `blockedPark` is deliberately unreachable — it belongs to the
        // parking vertical and this detector cannot emit it.
        switch raw {
        case "crack": return .crack
        case "alligator": return .alligator
        case "pothole": return .pothole
        default: return nil
        }
    }

    private static func mappedFromNote(for type: DefectType) -> String? {
        // RDD2022's D00 (longitudinal) and D10 (transverse) are merged into one
        // `crack` class by scripts/convert_voc_to_yolo.py. Surfacing that keeps the
        // reviewer from reading more precision into the label than exists.
        type == .crack ? "gabungan retak memanjang & melintang" : nil
    }

    // MARK: - Filename fallbacks (used only when provenance is missing)

    /// Stems look like `IMG_0040_f000030_t0001000` — clip, frame index, ms timestamp.
    static func sourceClip(fromStem stem: String) -> String {
        let parts = stem.split(separator: "_")
        return parts.count >= 2 ? parts[0...1].joined(separator: "_") : stem
    }

    static func frameIndex(fromStem stem: String) -> String {
        guard let field = stem.split(separator: "_").first(where: { $0.hasPrefix("f") }),
              let value = Int(field.dropFirst()) else { return "—" }
        return String(value)
    }

    static func timecode(seconds: Double?, stem: String) -> String {
        let total: Double
        if let seconds {
            total = seconds
        } else if let field = stem.split(separator: "_").first(where: { $0.hasPrefix("t") }),
                  let ms = Int(field.dropFirst()) {
            total = Double(ms) / 1000.0
        } else {
            return "—"
        }
        let whole = Int(total.rounded())
        return String(format: "%02d:%02d:%02d", whole / 3600, (whole % 3600) / 60, whole % 60)
    }

    // MARK: - CSV

    /// Minimal reader: header row supplies the keys, every later row becomes a dict.
    ///
    /// Deliberately does NOT implement RFC 4180 quoting. All three inputs are written
    /// by `csv.DictWriter` from numeric fields, class names and ISO timestamps — none
    /// can contain a comma or a quote. A quoted field would silently mis-split here,
    /// so if these files ever gain free text this needs replacing, not patching.
    ///
    /// ⚠️ Splits on `Character.isNewline`, NOT on `"\n"`. Python's `csv.DictWriter`
    /// terminates rows with CRLF by default, and Swift treats `"\r\n"` as a SINGLE
    /// extended grapheme cluster that does not compare equal to `"\n"` — so
    /// `split(separator: "\n")` matches nothing, yields the entire file as one line,
    /// and this function returns zero rows. That failure is silent: the app compiles,
    /// loads, and shows an empty review queue as though the detector had found
    /// nothing. `isNewline` is true for the CRLF cluster and for a bare LF, so it
    /// handles whichever terminator the CSV was written with.
    private static func readCSV(_ url: URL) throws -> [[String: String]] {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw LoadError.unreadable(url, underlying: error.localizedDescription)
        }

        var lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard !lines.isEmpty else { throw LoadError.malformed(url, reason: "berkas kosong") }

        let header = lines.removeFirst().split(separator: ",", omittingEmptySubsequences: false)
            .map(String.init)
        return lines.map { line in
            let values = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            var row: [String: String] = [:]
            for (index, key) in header.enumerated() where index < values.count {
                row[key] = values[index]
            }
            return row
        }
    }
}
