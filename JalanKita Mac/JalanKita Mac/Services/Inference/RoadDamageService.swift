//
//  RoadDamageService.swift
//  JalanKita Mac
//
//  App-facing entry point for the road-damage pipeline (Peninjauan). Owns the
//  lazily-launched, kept-warm RoadDamageWorkerProcess and turns its NDJSON
//  responses into the one thing AppModel wants: a `ReviewFrame` ready for the
//  review queue — the SAME type Stage 0's RoadDamageDataset produces, so the
//  screen cannot tell a live analysis from a dataset frame.
//
//  @MainActor for the same reason as InferenceService: its callers and its
//  progress forwarding both belong on the main actor, while everything genuinely
//  concurrent lives in the actor behind it.
//

import Foundation
import CoreGraphics

@MainActor
final class RoadDamageService {
    static let shared = RoadDamageService()

    private var worker: RoadDamageWorkerProcess?

    /// Forwarded from the worker's stderr — AppModel is the only subscriber.
    var onProgress: ((RoadDamageStderrLine) -> Void)?

    private init() {}

    /// Analyses one photo and returns it as a queue-ready `ReviewFrame`.
    ///
    /// `requestID` only has to be unique in flight; unlike the disturbance worker
    /// there is no result cache to key into, because nothing re-renders a road
    /// damage result after the fact (no BEV equivalent). The frame's own id is
    /// the image filename, so re-analysing the same photo replaces rather than
    /// duplicates it in the queue.
    func analyze(imageURL: URL, requestID: String = UUID().uuidString) async throws -> ReviewFrame {
        let worker = try await ensureStarted()
        let response = try await worker.send(
            RoadDamageRequest(id: requestID, imagePath: imageURL.path))

        guard response.ok else {
            throw RoadDamageWorkerError.requestFailed(
                response.error ?? "Analisis kerusakan jalan gagal tanpa pesan kesalahan.")
        }
        return Self.makeFrame(from: response, imageURL: imageURL)
    }

    /// Terminates the child process. Unlike `InferenceService.shutdown()` — which
    /// famously has no caller — this one is wired to app termination in
    /// JalanKita_MacApp, so quitting mid-analysis doesn't orphan a Python process.
    func shutdown() async {
        await worker?.stop()
        worker = nil
    }

    private func ensureStarted() async throws -> RoadDamageWorkerProcess {
        if let worker, await worker.isRunning {
            return worker
        }
        let (executable, arguments, cwd) = try Self.resolveWorkerLaunch()
        let newWorker = RoadDamageWorkerProcess(executableURL: executable,
                                                arguments: arguments,
                                                workingDirectory: cwd)
        let forward = onProgress
        await newWorker.setOnStderrLine { line in
            Task { @MainActor in forward?(line) }
        }
        try await newWorker.start()
        worker = newWorker
        return newWorker
    }

    // MARK: - Launch resolution

    /// Where the road-damage worker's interpreter lives, in order:
    ///
    ///  1. **`JALANKITA_ROAD_DAMAGE_PYTHON`** — an explicit interpreter, which is
    ///     how you point this at an existing environment without building a new one.
    ///  2. **`JALANKITA_ROAD_DAMAGE_REPO`/.venv** — an explicit checkout.
    ///  3. **`RoadDamage/.venv`** — this repo's own worker environment, the
    ///     intended steady state (`RoadDamage/README.md` has the two commands).
    ///  4. **`../test-road-damage-detection/.venv`** — the sibling checkout the
    ///     detector is trained in. Present on a dev machine that has run the
    ///     upstream project, and it already has the exact dependency set, so this
    ///     tier is what makes the feature work before anyone spends ~2 GB and
    ///     several minutes on a fourth venv.
    ///
    /// ⚠️ There is deliberately NO bundled tier yet, because there is no frozen
    /// build — `RoadDamage/` has no `build_worker.sh`, exactly like `CarDetection/`
    /// (CLAUDE.md fact 13). An archived app therefore has Stage 0 but not Stage 1.
    /// Adding PyInstaller here is the fix and it is not done.
    ///
    /// Every tier invokes an interpreter by full path rather than relying on PATH:
    /// Xcode launches the app without a terminal's activated venv, so
    /// `/usr/bin/env python3` would find a Python with none of this installed.
    private static func resolveWorkerLaunch() throws -> (URL, [String], URL?) {
        let repoRoot = autoDetectedWorkerRoot()
        let script = repoRoot.appendingPathComponent("worker_main.py")
        let environment = ProcessInfo.processInfo.environment
        var searched: [String] = []

        var candidates: [URL] = []
        if let explicit = environment["JALANKITA_ROAD_DAMAGE_PYTHON"] {
            candidates.append(URL(fileURLWithPath: explicit))
        }
        if let repo = environment["JALANKITA_ROAD_DAMAGE_REPO"] {
            candidates.append(URL(fileURLWithPath: repo, isDirectory: true)
                .appendingPathComponent(".venv/bin/python3"))
        }
        candidates.append(repoRoot.appendingPathComponent(".venv/bin/python3"))
        candidates.append(siblingDetectorRoot().appendingPathComponent(".venv/bin/python3"))

        for python in candidates {
            if FileManager.default.isExecutableFile(atPath: python.path),
               FileManager.default.fileExists(atPath: script.path) {
                return (python, [script.path, "--serve"], repoRoot)
            }
            searched.append(python.path)
        }
        throw RoadDamageWorkerError.workerNotFound(searched: searched)
    }

    /// `RoadDamage/`, five path components up from this source file — the same
    /// walk `InferenceService` does to find `PythonWorker/`, since both are
    /// subdirectories of the repo root.
    private static func autoDetectedWorkerRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("RoadDamage", isDirectory: true)
    }

    /// One level further out than the repo root — the sibling checkout, same
    /// place `RoadDamageDataset` finds the Stage 0 CSVs.
    private static func siblingDetectorRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("test-road-damage-detection", isDirectory: true)
    }

    // MARK: - Response -> ReviewFrame

    /// Builds the same `ReviewFrame` shape Stage 0 produces.
    ///
    /// The metadata Stage 0 reads from `frames_provenance.csv` has no analogue for
    /// an ad-hoc photo — there is no source clip, no decoder frame index, no
    /// presentation timestamp — so those carry the filename and em-dashes rather
    /// than invented values, and GPS stays nil for the same reason it does in
    /// Stage 0: the footage has none.
    private static func makeFrame(from response: RoadDamageResponse,
                                  imageURL: URL) -> ReviewFrame {
        let score = response.condition ?? 98
        let boxes = response.boxes ?? []
        let stem = imageURL.deletingPathExtension().lastPathComponent

        let findings = boxes.map { box in
            Finding(
                id: "\(stem)#\(box.boxIndex)",
                defectType: defectType(box.cls) ?? .crack,
                areaSqm: nil,                       // needs IPM + a calibration frame
                percentOfSurface: box.areaPct,
                vehicleNote: nil,
                confidence: box.conf,
                mappedFromNote: box.cls == "crack"
                    ? "gabungan retak memanjang & melintang" : nil,
                frameRect: CGRect(x: box.cx - box.w / 2, y: box.cy - box.h / 2,
                                  width: box.w, height: box.h)
            )
        }

        let deductions = boxes.map { box -> SeverityDeduction in
            var label = (defectType(box.cls) ?? .crack).label
            if box.inWheelpath { label += " · di jalur roda" }
            if box.deductEffective < box.deductRaw - 0.0001 { label += " · pengulangan kelas" }
            return SeverityDeduction(label: label, points: -Int(box.deductEffective.rounded()))
        }

        return ReviewFrame(
            id: stem,
            sourceClip: imageURL.lastPathComponent,
            frameNumber: "—",
            timecode: "—",
            capturedAt: nil,
            severity: Severity(score: score),
            score: score,
            isProvisional: true,
            segmentLabel: nil,
            kmMarker: nil,
            coordinate: nil,
            gpsAccuracyM: nil,
            findings: findings,
            startScore: response.startScore ?? 100,
            deductions: deductions,
            imageURL: imageURL,
            imageWidth: response.imageWidth ?? 0,
            imageHeight: response.imageHeight ?? 0
        )
    }

    private static func defectType(_ raw: String) -> DefectType? {
        switch raw {
        case "crack": return .crack
        case "alligator": return .alligator
        case "pothole": return .pothole
        default: return nil
        }
    }
}
