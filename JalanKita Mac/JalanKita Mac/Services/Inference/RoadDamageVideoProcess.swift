//
//  RoadDamageVideoProcess.swift
//  JalanKita Mac
//
//  Samples a clip into frames so Peninjauan can review a video. One-shot
//  subprocess: launch, read one JSON manifest off stdout, exit. Frames land on
//  disk and the caller then sends one `analyze` per frame to the warm worker.
//
//  ⚠️ This deliberately does NOT reuse the warm RoadDamageWorkerProcess, and the
//  reason is measured rather than stylistic. Extracting the same clip inside a
//  process that has initialised MPS and loaded two models produced JPEGs
//  differing from a clean run on 1,267 % of channel values (991.882 vs 999.961
//  bytes), which moved the detector's own reading of one frame — `conf` 0,7424 ->
//  0,7411, `deduct_effective` 11,987 -> 11,989. Four suspects were tested and
//  cleared first: cv2 thread count, `import torch`, `import ultralytics`, and
//  video decode itself. See `RoadDamage/video_frames.py`'s docstring.
//
//  So this is Protocol B — one-shot subprocess — for the same family of reason
//  CarDetection is: some work does not belong inside a long-lived worker. The
//  difference from CarDetection is that the result comes back on **stdout** as
//  one JSON line rather than being scraped off disk, because there is exactly one
//  result and the child knows it.
//

import Foundation

/// What `worker_main.py --extract-video` writes to stdout on success.
struct RoadDamageVideoManifest: Decodable {
    let video: String
    let outDir: String
    let provenance: String
    let intervalSec: Double
    let fps: Double
    let durationSec: Double

    /// Absolute paths, in presentation order. The caller analyses them in this
    /// order so the review queue reads front-to-back through the clip.
    let frames: [String]

    /// `sampled` is how many the stride selected; `kept` is how many survived the
    /// optional blur / near-duplicate filters. They are equal unless those were
    /// enabled — reported separately so a short queue is explainable rather than
    /// mysterious.
    let sampled: Int
    let kept: Int
    let rejectedBlur: Int
    let rejectedDup: Int

    /// Recording time from the container's own `mvhd` atom, UTC. nil when the atom
    /// could not be read — in which case `wall_clock_iso` in the provenance CSV is
    /// left empty rather than filled with the file's modification time. That
    /// column is the join key a GPS log will later be interpolated onto, and a
    /// plausible wrong timestamp would place a frame on the wrong stretch of road.
    let createdUtc: String?

    let warnings: String?

    enum CodingKeys: String, CodingKey {
        case video, provenance, fps, frames, sampled, kept, warnings
        case outDir = "out_dir"
        case intervalSec = "interval_sec"
        case durationSec = "duration_sec"
        case rejectedBlur = "rejected_blur"
        case rejectedDup = "rejected_dup"
        case createdUtc = "created_utc"
    }
}

enum RoadDamageVideoError: LocalizedError {
    case launchFailed(String)
    case processFailed(status: Int32, tail: String)
    case noManifest(tail: String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let detail):
            return "Tidak bisa menjalankan pengambil frame: \(detail)"
        case .processFailed(let status, let tail):
            return "Pengambilan frame gagal (kode \(status)).\n\(tail)"
        case .noManifest(let tail):
            return "Pengambil frame tidak mengembalikan hasil.\n\(tail)"
        }
    }
}

/// Progress while sampling, straight from the child's stderr — no scraping.
struct RoadDamageVideoProgress: Sendable {
    let framesDone: Int
    let framesTotal: Int

    var fraction: Double {
        framesTotal > 0 ? Double(framesDone) / Double(framesTotal) : 0
    }
}

enum RoadDamageVideoProcess {
    /// `2026-08-14T01:44:23Z` — whole seconds, `Z` suffix, matching
    /// `read_creation_time`'s own `dt.isoformat().replace("+00:00", "Z")`
    /// exactly, since `_shift` parses this same format back on the Python side.
    private static let isoFormatter = ISO8601DateFormatter()

    /// Samples `video` every `intervalSec` seconds into `outputDir`.
    ///
    /// `onProgress` fires on the main actor per kept frame. Extraction is fast
    /// relative to analysis — seconds against minutes — so this exists to keep the
    /// UI honest during a long clip rather than because the wait is painful.
    ///
    /// `hashThreshold` is the dHash Hamming distance under which a frame counts as
    /// a near-duplicate of one already kept and is dropped before it ever costs an
    /// analysis. 0 disables it, which is the default on both sides.
    ///
    /// ⚠️ Off by default deliberately, and 5 is deliberately conservative. It is the
    /// cheapest real lever on this stage's cost — a vehicle stopped at a light pays
    /// full price for the same asphalt several times over — but it must never drop
    /// road the reviewer has not seen.
    ///
    /// Measured on `IMG_0056.MOV` (moving camera, 5,1 s, 18 frames at a 0,3 s
    /// interval — deliberately far denser than any real run, to make duplicates as
    /// likely as possible):
    ///
    ///     --hash-thresh  0 -> kept 18, dropped  0
    ///     --hash-thresh  5 -> kept 18, dropped  0     <- the UI toggle's value
    ///     --hash-thresh 12 -> kept 12, dropped  6
    ///     --hash-thresh 25 -> kept  4, dropped 14
    ///
    /// So 5 costs nothing on moving footage, which is the point: it should bite only
    /// where the vehicle is genuinely stationary. 12 and above start discarding real
    /// road and must not be adopted without re-measuring on stationary footage —
    /// which this repo does not yet have a clip of. `rejected_dup` in the manifest
    /// reports what it actually dropped on every run, so this stays tunable on
    /// evidence rather than on a second guess.
    @MainActor
    static func extract(video: URL,
                        outputDir: URL,
                        intervalSec: Double,
                        maxFrames: Int = 0,
                        hashThreshold: Int = 0,
                        gpsCSV: URL? = nil,
                        createdUTCOverride: Date? = nil,
                        onProgress: ((RoadDamageVideoProgress) -> Void)? = nil)
        async throws -> RoadDamageVideoManifest {

        var mode = ["--extract-video", video.path,
                    "--out", outputDir.path,
                    "--interval", String(intervalSec)]
        if maxFrames > 0 {
            mode += ["--max-frames", String(maxFrames)]
        }
        if hashThreshold > 0 {
            mode += ["--hash-thresh", String(hashThreshold)]
        }
        if let gpsCSV {
            mode += ["--gps-csv", gpsCSV.path]
        }
        if let createdUTCOverride {
            // See `video_frames.extract`'s doc comment on `created_utc_override`:
            // needed whenever this file went through "Putar kiri/kanan" before
            // processing, which re-stamps the container's own mvhd to the moment
            // of export rather than carrying the original recording time forward.
            mode += ["--created-utc-override", Self.isoFormatter.string(from: createdUTCOverride)]
        }
        let (executable, arguments, workingDirectory) =
            try RoadDamageService.resolveLaunch(mode: mode)

        try FileManager.default.createDirectory(at: outputDir,
                                                withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }

        // 🚫 No JALANKITA_ROAD_DAMAGE_FORCE_CPU here, and no other model-related
        // variable: this invocation never imports torch. Passing them would be
        // harmless but misleading about what this process does.
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw RoadDamageVideoError.launchFailed(error.localizedDescription)
        }

        // Both pipes are drained concurrently. Reading one to completion first
        // deadlocks as soon as the other fills its 64 KB buffer — and a long clip
        // emits one progress line per frame, so stderr fills reliably.
        let stderrReader = AsyncLineReader(fileHandle: stderrPipe.fileHandleForReading)
        let stderrTask = Task { () -> [String] in
            var tail: [String] = []
            // A read error on the pipe is not worth failing the extraction over — the
            // exit status and the empty manifest already cover a real failure, and
            // losing the last few progress lines is not one.
            if let lines = try? await Self.drain(stderrReader.lines, onProgress: onProgress) {
                tail = lines
            }
            return tail
        }

        let stdoutData = try stdoutPipe.fileHandleForReading.readToEnd() ?? Data()
        let tail = await stderrTask.value
        process.waitUntilExit()

        let tailText = tail.joined(separator: "\n")
        guard process.terminationStatus == 0 else {
            throw RoadDamageVideoError.processFailed(status: process.terminationStatus,
                                                     tail: tailText)
        }

        // The manifest is the LAST line: `video_frames` may print nothing else, but
        // a future warning on stdout should not break decoding.
        guard let text = String(data: stdoutData, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).last,
              let data = line.data(using: .utf8),
              let manifest = try? JSONDecoder().decode(RoadDamageVideoManifest.self, from: data)
        else {
            throw RoadDamageVideoError.noManifest(tail: tailText)
        }
        return manifest
    }

    /// Consumes the child's stderr, forwarding progress and keeping a 40-line tail
    /// for the error message. Split out so the `try` lives somewhere it can be seen.
    private static func drain(_ lines: AsyncThrowingStream<String, Error>,
                              onProgress: ((RoadDamageVideoProgress) -> Void)?)
        async throws -> [String] {
        var tail: [String] = []
        for try await line in lines {
            if let progress = parseProgress(line) {
                await MainActor.run { onProgress?(progress) }
            }
            tail.append(line)
            if tail.count > 40 { tail.removeFirst() }
        }
        return tail
    }

    /// `{"type":"progress","stage":"extract","done":3,"total":12}` -> progress.
    ///
    /// Structured NDJSON, unlike CarDetection's `processed N/M frames` prefix
    /// scrape — the road-damage worker already speaks JSON on stderr, so the
    /// extractor does too.
    private static func parseProgress(_ line: String) -> RoadDamageVideoProgress? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["stage"] as? String == "extract",
              let done = object["done"] as? Int,
              let total = object["total"] as? Int
        else { return nil }
        return RoadDamageVideoProgress(framesDone: done, framesTotal: total)
    }
}
