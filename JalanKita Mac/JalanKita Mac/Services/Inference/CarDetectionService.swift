//
//  CarDetectionService.swift
//  JalanKita Mac
//
//  App-facing entry point for v13 (car-detection-from-video), mirroring
//  InferenceService's role for the disturbance worker. @MainActor for the
//  same reason: it's called from AppModel and forwards progress back to it.
//
//  Path resolution mirrors InferenceService.resolveWorkerLaunch(): v13 lives
//  at `CarDetection/` -- a sibling of `PythonWorker/` INSIDE this repo, a
//  trimmed self-contained copy (same reasoning as PythonWorker/README's own
//  "kept here so contributors can build and run the app without a second
//  repo checkout"), not an external sibling folder that a `git clone` would
//  never bring along. It needs its OWN `.venv` -- ultralytics/YOLO/MiDaS/
//  YOLOP is a completely different, heavier dependency stack than
//  PythonWorker's Mask2Former/OFRSNet one (see CarDetection/requirements.txt)
//  -- so it cannot reuse PythonWorker/.venv. There is no PyInstaller-frozen
//  build of v13 yet (unlike disturbance-worker) -- this only resolves a
//  dev-mode launch, same as PythonWorker's own dev-tier resolution.
//

import Foundation

struct CarDetectionResult {
    let summary: CarDetectionSummary
    let screenshotDir: URL
}

@MainActor
final class CarDetectionService {
    static let shared = CarDetectionService()

    /// Forwarded to AppModel, same pattern as InferenceService.onProgress.
    var onProgress: ((CarDetectionProgress) -> Void)?

    private init() {}

    /// Runs v13 on `video`, writing its screenshots + _summary.json into a
    /// subfolder of `workDir` (typically ~/Library/Application Support/...,
    /// keyed by session id so re-running never collides with another
    /// session's output).
    func detect(video: URL, workDir: URL) async throws -> CarDetectionResult {
        let (python, script, cwd) = try Self.resolveLaunch()
        let worker = CarDetectionWorkerProcess(executableURL: python, scriptURL: script, workingDirectory: cwd)
        let screenshotDir = workDir
        let outputVideoPath = workDir.appendingPathComponent("annotated.mp4")
        let forward = onProgress
        let summary = try await worker.run(video: video, screenshotDir: screenshotDir,
                                           outputVideoPath: outputVideoPath) { progress in
            Task { @MainActor in forward?(progress) }
        }
        return CarDetectionResult(summary: summary, screenshotDir: screenshotDir)
    }

    /// Resolution order (mirrors InferenceService.resolveWorkerLaunch()):
    ///  1. **Packaged**: `Contents/Resources/car-detection/cardetection` --
    ///     the PyInstaller onedir output staged there by the "Stage
    ///     CarDetection" run-script build phase (see
    ///     JalanKita Mac.xcodeproj, and `CarDetection/build_cardetection.sh`).
    ///     This is how the shipped app runs car detection without a dev
    ///     Python environment present.
    ///  2. **Dev, explicit**: `JALANKITA_V13_REPO` + `JALANKITA_V13_PYTHON`
    ///     env vars, for anyone whose checkout doesn't match the layout
    ///     below (e.g. a separate full v13 dev checkout with more than the
    ///     trimmed runtime files).
    ///  3. **Dev, zero-config**: `CarDetection/` as a sibling of
    ///     `PythonWorker/` inside this repo (found via this source file's
    ///     own `#filePath`, same climb depth
    ///     `InferenceService.autoDetectedPythonWorkerRoot()` uses to reach
    ///     repo root), interpreted by its own `CarDetection/.venv/bin/python3`
    ///     -- built via `python3 -m venv .venv && pip install -r
    ///     requirements.txt`, same recipe as PythonWorker/README's dev
    ///     setup. Both env vars override independently so only the
    ///     mismatched half needs setting.
    ///
    /// The packaged tier runs a different script (`cardetection_main.py`,
    /// not `pipeline_v13.py` directly) with no `.venv` -- the frozen
    /// executable IS the interpreter, so `python`/`script` collapse to the
    /// same value there; see CarDetectionWorkerProcess for how that's used.
    private static func resolveLaunch() throws -> (python: URL, script: URL, cwd: URL?) {
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("car-detection/cardetection"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return (bundled, bundled, nil)
        }

        let env = ProcessInfo.processInfo.environment
        let repoRoot = env["JALANKITA_V13_REPO"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? autoDetectedCarDetectionRoot()
        let python = env["JALANKITA_V13_PYTHON"].map { URL(fileURLWithPath: $0) }
            ?? repoRoot.appendingPathComponent(".venv/bin/python3")

        let script = repoRoot.appendingPathComponent("pipeline_v13.py")
        let scriptExists = FileManager.default.fileExists(atPath: script.path)
        let pythonExecutable = FileManager.default.isExecutableFile(atPath: python.path)
        guard scriptExists, pythonExecutable else {
            throw CarDetectionError.workerNotFound(detail:
                "repoRoot=\(repoRoot.path)\nscript=\(script.path) (exists=\(scriptExists))\n"
                + "python=\(python.path) (executable=\(pythonExecutable))")
        }
        return (python, script, repoRoot)
    }

    /// `CarDetection/`, five path components up from this source file (same
    /// climb as `InferenceService.autoDetectedPythonWorkerRoot()` -- see its
    /// comment for the component-by-component breakdown), then into
    /// `CarDetection` instead of `PythonWorker`.
    private static func autoDetectedCarDetectionRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("CarDetection", isDirectory: true)
    }
}
