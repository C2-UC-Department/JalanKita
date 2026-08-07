//
//  InferenceService.swift
//  JalanKita Mac
//
//  App-facing entry point for the parking-disturbance pipeline. Owns the
//  lazily-launched, kept-warm InferenceWorkerProcess and turns its raw
//  NDJSON responses into the one thing AppModel actually wants: an
//  AnalysisResult ready for ParkingMetrics/the Tinjauan Parkir screen.
//  Everything actor-isolated lives in InferenceWorkerProcess; this type is
//  @MainActor because its jobs — being called from AppModel and forwarding
//  progress back to it — both belong on the main actor.
//

import Foundation

/// Everything one `analyze()` call produces, beyond the raw
/// `DisturbanceSummary` — the image's own pixel dimensions (needed to
/// normalize `VehicleSummary.pixelBBox` into a `Finding.frameRect`) and the
/// two PNGs the worker rendered to disk.
struct AnalysisResult {
    let summary: DisturbanceSummary
    let imageWidth: Int
    let imageHeight: Int
    let candidatesPNGPath: String?
    let bevPNGPath: String?
}

@MainActor
final class InferenceService {
    static let shared = InferenceService()

    private var worker: InferenceWorkerProcess?

    /// Forwarded from the worker's stderr — AppModel is the only subscriber,
    /// turning each line into a PipelineProgressParser.Update.
    var onProgress: ((WorkerStderrLine) -> Void)?

    private init() {}

    /// `requestID` doubles as the analysis's cache key on the worker side
    /// (`serve_worker`'s `result_cache`) — callers that want to later
    /// re-render the BEV for a different vehicle (`renderBEV`) should pass a
    /// stable id they can remember, e.g. AppModel passes the session id.
    func analyze(imagePath: URL, requestID: String = UUID().uuidString) async throws -> AnalysisResult {
        let worker = try await ensureStarted()
        let request = WorkerRequest(id: requestID, imagePath: imagePath.path)
        let response = try await worker.send(request, id: requestID)

        guard response.ok, let summary = response.summary,
              let width = response.imageWidth, let height = response.imageHeight else {
            throw InferenceWorkerError.requestFailed(
                response.error ?? "Analisis gagal tanpa pesan kesalahan.")
        }
        return AnalysisResult(summary: summary, imageWidth: width, imageHeight: height,
                              candidatesPNGPath: response.candidatesPNG, bevPNGPath: response.bevPNG)
    }

    /// Re-renders the BEV panel highlighting `vehicleID`'s share (`nil` for
    /// no highlight), for an image already analyzed via `analyze(requestID:)`
    /// in this same worker process. Throws `InferenceWorkerError.requestFailed`
    /// if the worker no longer has that analysis cached (evicted, or the
    /// worker restarted since) — callers should keep showing the last
    /// successfully rendered BEV rather than treat this as fatal.
    func renderBEV(analysisID: String, vehicleID: Int?) async throws -> String {
        let worker = try await ensureStarted()
        let requestID = UUID().uuidString
        let request = RenderBEVRequest(id: requestID, analysisID: analysisID, vehicleID: vehicleID)
        let response = try await worker.send(request, id: requestID)

        guard response.ok, let bevPNG = response.bevPNG else {
            throw InferenceWorkerError.requestFailed(
                response.error ?? "Render ulang BEV gagal tanpa pesan kesalahan.")
        }
        return bevPNG
    }

    /// Terminates the child process, if any — call on app termination so no
    /// orphaned `disturbance-worker` survives quitting mid-analysis (Phase 4).
    func shutdown() async {
        await worker?.stop()
        worker = nil
    }

    private func ensureStarted() async throws -> InferenceWorkerProcess {
        if let worker, await worker.isRunning {
            return worker
        }
        let (executable, arguments, cwd) = try Self.resolveWorkerLaunch()
        let newWorker = InferenceWorkerProcess(executableURL: executable, arguments: arguments,
                                               workingDirectory: cwd)
        let forward = onProgress
        await newWorker.setOnStderrLine { line in
            Task { @MainActor in forward?(line) }
        }
        try await newWorker.start()
        worker = newWorker
        return newWorker
    }

    /// Resolves where the disturbance-worker executable lives, in order:
    ///
    ///  1. **Packaged**: `Contents/Resources/disturbance-worker/disturbance-worker`
    ///     — the PyInstaller onedir output staged there by a Copy Files build
    ///     phase (see JalanKita Mac.xcodeproj's "Stage disturbance-worker"
    ///     run-script phase, and `PythonWorker/build_worker.sh`). This is how
    ///     the shipped app launches the worker.
    ///  2. **Dev, explicit**: the `JALANKITA_DISTURBANCE_REPO` environment
    ///     variable, pointing at any repo checkout that has `.venv/`,
    ///     `src/disturbance.py`, and `config.py` at its root — either this
    ///     project's own `PythonWorker/` or a separate AmodalRoadSegmentation
    ///     checkout both qualify.
    ///  3. **Dev, zero-config**: `PythonWorker/` as a sibling of this
    ///     checkout, located via this source file's own on-disk path
    ///     (`#filePath`). This is what makes `git clone` + `cd PythonWorker
    ///     && ./build_worker.sh` (which also creates `.venv/` as a side
    ///     effect) + build-and-run in Xcode work with no environment
    ///     variable at all.
    ///
    /// Both dev tiers invoke the repo's own `.venv/bin/python3` by full path
    /// rather than relying on a shell's activated PATH — Xcode launches the
    /// app without inheriting a terminal's venv, so `/usr/bin/env python3`
    /// would otherwise resolve to a `python3` with none of the pipeline's
    /// dependencies installed.
    ///
    /// All three launches pass `--no-instance-model`: skips OFRSNet's own
    /// Mask2Former-instance forward pass (src/instances.py), falling back to
    /// connected-components for per-vehicle attribution. Worth it because the
    /// video pipeline already has a precise per-car mask from v13 and never
    /// needed OFRSNet to rediscover vehicle boundaries; the one thing it costs
    /// is that touching/overlapping vehicles in a frame can get merged into
    /// one attributed blob (see instances.py's own docstring) instead of
    /// split cleanly — applies to Tinjauan Parkir's photo flow too, since
    /// both share this one worker process.
    private static func resolveWorkerLaunch() throws -> (executable: URL, arguments: [String], cwd: URL?) {
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("disturbance-worker/disturbance-worker"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return (bundled, ["--serve", "--no-instance-model"], nil)
        }

        if let repoPath = ProcessInfo.processInfo.environment["JALANKITA_DISTURBANCE_REPO"],
           let launch = devLaunch(repoRoot: URL(fileURLWithPath: repoPath, isDirectory: true)) {
            return launch
        }

        if let launch = devLaunch(repoRoot: autoDetectedPythonWorkerRoot()) {
            return launch
        }

        throw InferenceWorkerError.workerNotFound
    }

    private static func devLaunch(repoRoot: URL) -> (executable: URL, arguments: [String], cwd: URL?)? {
        let python = repoRoot.appendingPathComponent(".venv/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return nil }
        return (python, ["-m", "src.disturbance", "--serve", "--no-instance-model"], repoRoot)
    }

    /// `PythonWorker/`, five path components up from this source file
    /// (Inference/ -> Services/ -> "JalanKita Mac/" (inner) -> "JalanKita
    /// Mac/" (outer, the Xcode project dir) -> repo root), then into
    /// PythonWorker. Only meaningful for local builds run from a clone of
    /// this repo — a distributed/archived build won't have this path on
    /// disk at all, which `devLaunch`'s executable check handles.
    private static func autoDetectedPythonWorkerRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("PythonWorker", isDirectory: true)
    }
}
