//
//  CarDetectionWorkerProcess.swift
//  JalanKita Mac
//
//  Runs v13's pipeline_v13.py as a ONE-SHOT subprocess per video -- not a
//  warm NDJSON worker like InferenceWorkerProcess. Deliberately different
//  shape: the disturbance worker is warm because it serves many CHEAP
//  repeat requests against one loaded model (re-render BEV, analyze another
//  photo); v13 is a single batch job per video (load YOLO+YOLOP+MiDaS once,
//  process one video start-to-finish, write outputs, exit) with no repeat-
//  request pattern to amortize a warm process against. A future version that
//  processes many videos back-to-back in one sitting could revisit this --
//  see CHANGELOG entry / conversation this was built from.
//
//  v13 doesn't speak NDJSON. It prints plain progress lines to stderr
//  ("  processed 50/154 frames") and writes its real output to disk
//  (_summary.json + screenshot JPEGs in --screenshot-dir) rather than to
//  stdout, so this reads stderr for a progress fraction only, and reads the
//  result off disk once the process exits -- no request/response protocol
//  to speak, unlike InferenceWorkerProcess's `pending` continuation map.
//
//  Runs with --deterministic (forces single-threaded CPU, ~6 min per 5s
//  clip) rather than the default --device mps. Confirmed directly during
//  this integration: without --deterministic, ByteTrack's own run-to-run
//  non-determinism (documented at length in this project's own history)
//  can flip the one ground-truth violation clip's result from 1 disturbance
//  to 0 between runs of the identical input -- unacceptable for a tool whose
//  entire job is not missing violations. Slow-and-correct over fast-and-
//  sometimes-wrong.
//

import Foundation
import JalanKitaKit

enum CarDetectionError: Error, LocalizedError {
    case workerNotFound(detail: String)
    case launchFailed(String)
    case processFailed(status: Int32, tail: String)
    case summaryUnreadable(String)

    var errorDescription: String? {
        switch self {
        case .workerNotFound(let detail):
            "Tidak menemukan pipeline_v13.py atau interpreter Python-nya.\n\(detail)\n"
            + "Set JALANKITA_V13_REPO / JALANKITA_V13_PYTHON kalau lokasinya berbeda."
        case .launchFailed(let reason):
            "Gagal menjalankan pipeline v13: \(reason)"
        case .processFailed(let status, let tail):
            "pipeline_v13.py berhenti dengan kode \(status).\n\(tail)"
        case .summaryUnreadable(let reason):
            "Hasil deteksi mobil (_summary.json) tidak bisa dibaca: \(reason)"
        }
    }
}

/// One car-detection progress update, coarser than the disturbance worker's
/// staged events -- v13 only ever reports "frame N of M processed".
struct CarDetectionProgress {
    let framesDone: Int
    let framesTotal: Int
    var fraction: Double { framesTotal > 0 ? Double(framesDone) / Double(framesTotal) : 0 }
}

actor CarDetectionWorkerProcess {
    private let executableURL: URL
    private let baseArguments: [String]
    private let workingDirectory: URL?

    /// `baseArguments` is `[scriptURL.path]` for a dev-mode launch (`python3
    /// pipeline_v13.py ...`) or `[]` for the packaged, frozen executable
    /// (`pipeline_v13 ...` directly) -- mirrors InferenceWorkerProcess's own
    /// plain `arguments` parameter rather than treating "script path" as a
    /// concept this type needs to know about.
    init(executableURL: URL, baseArguments: [String] = [], workingDirectory: URL? = nil) {
        self.executableURL = executableURL
        self.baseArguments = baseArguments
        self.workingDirectory = workingDirectory
    }

    /// Runs v13 to completion on one video, writing screenshots + _summary.json
    /// into `screenshotDir` (created if needed), and returns the parsed
    /// summary. A video with zero PARKED-family cars is a normal, successful
    /// result -- v13 doesn't write _summary.json at all in that case (see
    /// pipeline_v13.py: `if demo_candidates:`), so that's read back as a
    /// summary with an empty `carsDetectedParked`, not an error.
    func run(video: URL, screenshotDir: URL, outputVideoPath: URL,
            onProgress: @Sendable @escaping (CarDetectionProgress) -> Void) async throws -> CarDetectionSummary {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CarDetectionError.workerNotFound(detail: "executable=\(executableURL.path)")
        }
        try FileManager.default.createDirectory(at: screenshotDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = baseArguments + [
            "--input", video.path,
            "--output", outputVideoPath.path,
            "--screenshot-dir", screenshotDir.path,
            "--deterministic",
        ]
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        let stderrReader = AsyncLineReader(fileHandle: stderrPipe.fileHandleForReading)

        var stderrTail: [String] = []
        let pumpTask = Task {
            do {
                for try await line in stderrReader.lines {
                    stderrTail.append(line)
                    if stderrTail.count > 40 { stderrTail.removeFirst() }
                    if let progress = Self.parseProgress(line) {
                        onProgress(progress)
                    }
                }
            } catch {
                // Reader ended -- process exited.
            }
        }

        do {
            try process.run()
        } catch {
            pumpTask.cancel()
            throw CarDetectionError.launchFailed(error.localizedDescription)
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }
        _ = await pumpTask.value

        guard process.terminationStatus == 0 else {
            throw CarDetectionError.processFailed(status: process.terminationStatus,
                                                   tail: stderrTail.joined(separator: "\n"))
        }

        return try Self.readSummary(in: screenshotDir)
    }

    /// Matches v13's own progress print (`main()` in pipeline_v13.py):
    /// `  processed 50/154 frames`. Anything else on stderr (model-loading
    /// chatter, the final per-track table) is silently not a progress line.
    private static func parseProgress(_ line: String) -> CarDetectionProgress? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("processed "), trimmed.hasSuffix(" frames") else { return nil }
        let middle = trimmed.dropFirst("processed ".count).dropLast(" frames".count)
        let parts = middle.split(separator: "/")
        guard parts.count == 2, let done = Int(parts[0]), let total = Int(parts[1]) else { return nil }
        return CarDetectionProgress(framesDone: done, framesTotal: total)
    }

    private static func readSummary(in dir: URL) throws -> CarDetectionSummary {
        let path = dir.appendingPathComponent("_summary.json")
        guard FileManager.default.fileExists(atPath: path.path) else {
            // No PARKED-family car this run -- a normal, empty result.
            return CarDetectionSummary(sourceVideo: "", outputVideo: "", carsDetectedParked: [])
        }
        do {
            let data = try Data(contentsOf: path)
            return try JSONDecoder().decode(CarDetectionSummary.self, from: data)
        } catch {
            throw CarDetectionError.summaryUnreadable(error.localizedDescription)
        }
    }
}
